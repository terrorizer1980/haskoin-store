{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TupleSections     #-}
module Network.Haskoin.Store.Block
      ( blockStore
      ) where

import           Conduit                             (MonadResource, runConduit,
                                                      runResourceT, sinkList,
                                                      transPipe, (.|))
import           Control.Monad                       (forM, forever, guard,
                                                      mzero, unless, void, when)
import           Control.Monad.Except                (ExceptT, runExceptT)
import           Control.Monad.Logger                (MonadLoggerIO, logDebugS,
                                                      logErrorS, logInfoS,
                                                      logWarnS)
import           Control.Monad.Reader                (MonadReader, ReaderT (..),
                                                      asks)
import           Control.Monad.Trans                 (lift)
import           Control.Monad.Trans.Maybe           (runMaybeT)
import           Data.Maybe                          (catMaybes, isNothing)
import           Data.String                         (fromString)
import           Data.String.Conversions             (cs)
import           Data.Time.Clock.System              (getSystemTime,
                                                      systemSeconds)
import           Haskoin                             (Block (..),
                                                      BlockHash (..),
                                                      BlockHeight,
                                                      BlockNode (..),
                                                      GetData (..),
                                                      InvType (..),
                                                      InvVector (..),
                                                      Message (..),
                                                      Network (..), Tx,
                                                      TxHash (..),
                                                      blockHashToHex,
                                                      headerHash, txHash,
                                                      txHashToHex)
import           Haskoin.Node                        (OnlinePeer (..), Peer,
                                                      PeerException (..),
                                                      chainBlockMain,
                                                      chainGetAncestor,
                                                      chainGetBest,
                                                      chainGetBlock,
                                                      chainGetParents, killPeer,
                                                      managerGetPeers,
                                                      sendMessage)
import           Network.Haskoin.Store.Data.ImportDB (ImportDB, runImportDB)
import           Network.Haskoin.Store.Data.Types    (BlockConfig (..), BlockDB,
                                                      BlockMessage (..),
                                                      BlockStore,
                                                      StoreEvent (..),
                                                      StoreRead (..),
                                                      StoreStream (..),
                                                      StoreWrite (..), UnixTime)
import           Network.Haskoin.Store.Logic         (ImportException,
                                                      getOldOrphans,
                                                      importBlock, importOrphan,
                                                      initBest, newMempoolTx,
                                                      revertBlock)
import           NQE                                 (Inbox, Mailbox,
                                                      inboxToMailbox, query,
                                                      receive)
import           System.Random                       (randomRIO)
import           UnliftIO                            (Exception, MonadIO,
                                                      MonadUnliftIO, TVar,
                                                      atomically, liftIO,
                                                      newTVarIO, readTVarIO,
                                                      throwIO, withAsync,
                                                      writeTVar)
import           UnliftIO.Concurrent                 (threadDelay)

data BlockException
    = BlockNotInChain !BlockHash
    | Uninitialized
    | UnexpectedGenesisNode
    | SyncingPeerExpected
    | AncestorNotInChain !BlockHeight
                         !BlockHash
    deriving (Show, Eq, Ord, Exception)

data Syncing = Syncing
    { syncingPeer :: !Peer
    , syncingTime :: !UnixTime
    , syncingHead :: !BlockNode
    }

-- | Block store process state.
data BlockRead = BlockRead
    { mySelf   :: !BlockStore
    , myConfig :: !BlockConfig
    , myPeer   :: !(TVar (Maybe Syncing))
    }

type BlockT m = ReaderT BlockRead m

runImport ::
       MonadLoggerIO m
    => ReaderT ImportDB (ExceptT ImportException m) a
    -> ReaderT BlockRead m (Either ImportException a)
runImport f =
    ReaderT $ \r -> runExceptT (runImportDB (blockConfDB (myConfig r)) f)

runRocksDB :: ReaderT BlockDB m a -> ReaderT BlockRead m a
runRocksDB f =
    ReaderT $ \BlockRead {myConfig = BlockConfig {blockConfDB = db}} ->
        runReaderT f db

instance MonadIO m => StoreRead (ReaderT BlockRead m) where
    getBestBlock = runRocksDB getBestBlock
    getBlocksAtHeight = runRocksDB . getBlocksAtHeight
    getBlock = runRocksDB . getBlock
    getTxData = runRocksDB . getTxData
    getSpender = runRocksDB . getSpender
    getSpenders = runRocksDB . getSpenders
    getOrphanTx = runRocksDB . getOrphanTx
    getUnspent = runRocksDB . getUnspent
    getBalance = runRocksDB . getBalance
    getMempool = runRocksDB getMempool
    getAddressesTxs addrs start limit =
        runRocksDB (getAddressesTxs addrs start limit)
    getAddressesUnspents addrs start limit =
        runRocksDB (getAddressesUnspents addrs start limit)

instance (MonadResource m, MonadUnliftIO m) =>
         StoreStream (ReaderT BlockRead m) where
    getOrphans = transPipe runRocksDB getOrphans
    getAddressUnspents a x = transPipe runRocksDB $ getAddressUnspents a x
    getAddressTxs a x = transPipe runRocksDB $ getAddressTxs a x
    getAddressBalances = transPipe runRocksDB getAddressBalances
    getUnspents = transPipe runRocksDB getUnspents

-- | Run block store process.
blockStore ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => BlockConfig
    -> Inbox BlockMessage
    -> m ()
blockStore cfg inbox = do
    $(logInfoS) "Block" "Initializing block store..."
    pb <- newTVarIO Nothing
    runReaderT
        (ini >> run)
        BlockRead {mySelf = inboxToMailbox inbox, myConfig = cfg, myPeer = pb}
  where
    ini = do
        net <- asks (blockConfNet . myConfig)
        runImport (initBest net) >>= \case
            Left e -> do
                $(logErrorS) "Block" $
                    "Could not initialize block store: " <> fromString (show e)
                throwIO e
            Right () -> $(logInfoS) "Block" "Initialization complete"
    run =
        withAsync (pingMe (inboxToMailbox inbox)) . const . forever $ do
            $(logDebugS) "Block" "Awaiting message..."
            receive inbox >>= \x ->
                ReaderT $ \r ->
                    runResourceT (runReaderT (processBlockMessage x) r)

isSynced :: (MonadLoggerIO m, MonadUnliftIO m) => ReaderT BlockRead m Bool
isSynced = do
    ch <- asks (blockConfChain . myConfig)
    $(logDebugS) "Block" "Testing if synced with header chain..."
    getBestBlock >>= \case
        Nothing -> do
            $(logErrorS) "Block" "Block database uninitialized"
            throwIO Uninitialized
        Just bb -> do
            $(logDebugS) "Block" $ "Best block: " <> blockHashToHex bb
            chainGetBest ch >>= \cb -> do
                $(logDebugS) "Block" $
                    "Best chain block " <>
                    blockHashToHex (headerHash (nodeHeader cb)) <>
                    " at height " <>
                    cs (show (nodeHeight cb))
                let s = headerHash (nodeHeader cb) == bb
                $(logDebugS) "Block" $ "Synced: " <> cs (show s)
                return s

mempool ::
       (MonadUnliftIO m, MonadLoggerIO m) => Peer -> ReaderT BlockRead m ()
mempool p = MMempool `sendMessage` p

processBlock ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Peer
    -> Block
    -> ReaderT BlockRead m ()
processBlock p b = do
    $(logDebugS) "Block" ("Processing incoming block: " <> hex)
    void . runMaybeT $ do
        iss >>= \x ->
            unless x $ do
                $(logErrorS) "Block" $
                    "Cannot accept block " <> hex <> " from non-syncing peer"
                mzero
        n <- cbn
        upr
        net <- blockConfNet <$> asks myConfig
        lift (runImport (importBlock net b n)) >>= \case
            Right ths -> do
                l <- blockConfListener <$> asks myConfig
                $(logInfoS) "Block" $
                    "Best block indexed: " <>
                    blockHashToHex (headerHash (blockHeader b)) <>
                    " at height " <>
                    cs (show (nodeHeight n))
                atomically $ do
                    mapM_ (l . StoreTxDeleted) ths
                    l (StoreBestBlock (headerHash (blockHeader b)))
                lift $ isSynced >>= \x -> when x (mempool p)
            Left e -> do
                $(logErrorS) "Block" $
                    "Error importing block " <>
                    fromString (show $ headerHash (blockHeader b)) <>
                    ": " <>
                    fromString (show e)
                killPeer (PeerMisbehaving (show e)) p
    syncMe
  where
    hex = blockHashToHex (headerHash (blockHeader b))
    upr =
        asks myPeer >>= readTVarIO >>= \case
            Nothing -> throwIO SyncingPeerExpected
            Just s@Syncing {syncingHead = h} ->
                if nodeHeader h == blockHeader b
                    then resetPeer
                    else do
                        now <-
                            fromIntegral . systemSeconds <$>
                            liftIO getSystemTime
                        asks myPeer >>=
                            atomically .
                            (`writeTVar` Just s {syncingTime = now})
    iss =
        asks myPeer >>= readTVarIO >>= \case
            Just Syncing {syncingPeer = p'} -> return $ p == p'
            Nothing -> return False
    cbn =
        blockConfChain <$> asks myConfig >>=
        chainGetBlock (headerHash (blockHeader b)) >>= \case
            Nothing -> do
                killPeer (PeerMisbehaving "Sent unknown block") p
                $(logErrorS)
                    "Block"
                    ("Block " <> hex <> " rejected as header not found")
                mzero
            Just n -> return n

processNoBlocks ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Peer
    -> [BlockHash]
    -> ReaderT BlockRead m ()
processNoBlocks p _bs = do
    $(logErrorS) "Block" (cs m)
    killPeer (PeerMisbehaving m) p
  where
    m = "We do not like peers that cannot find them blocks"

processTx :: (MonadUnliftIO m, MonadLoggerIO m) => Peer -> Tx -> BlockT m ()
processTx _p tx =
    isSynced >>= \case
        False ->
            $(logDebugS) "Block" $
            "Ignoring incoming tx (not synced yet): " <> txHashToHex (txHash tx)
        True -> do
            $(logInfoS) "Block" $ "Incoming tx: " <> txHashToHex (txHash tx)
            now <- fromIntegral . systemSeconds <$> liftIO getSystemTime
            net <- asks (blockConfNet . myConfig)
            runImport (newMempoolTx net tx now) >>= \case
                Left e ->
                    $(logWarnS) "Block" $
                    "Error importing tx: " <> txHashToHex (txHash tx) <> ": " <>
                    fromString (show e)
                Right (Just ths) -> do
                    l <- blockConfListener <$> asks myConfig
                    $(logDebugS) "Block" $
                        "Received mempool tx: " <> txHashToHex (txHash tx)
                    atomically $ do
                        mapM_ (l . StoreTxDeleted) ths
                        l (StoreMempoolNew (txHash tx))
                Right Nothing ->
                    $(logDebugS) "Block" $
                    "Not importing mempool tx: " <> txHashToHex (txHash tx)

processOrphans ::
       (MonadResource m, MonadUnliftIO m, MonadLoggerIO m) => BlockT m ()
processOrphans =
    isSynced >>= \case
        False -> $(logDebugS) "Block" "Not importing orphans as not yet in sync"
        True -> do
            now <- fromIntegral . systemSeconds <$> liftIO getSystemTime
            net <- asks (blockConfNet . myConfig)
            $(logDebugS) "Block" "Getting expired orphan transactions..."
            old <- runConduit $ getOldOrphans now .| sinkList
            case old of
                [] ->
                    $(logDebugS) "Block" "No old orphan transactions to remove"
                _ -> do
                    $(logDebugS) "Block" $
                        "Removing " <> cs (show (length old)) <>
                        "expired orphan transactions..."
                    void . runImport $ mapM_ deleteOrphanTx old
            $(logDebugS) "Block" "Selecting orphan transactions to import..."
            orphans <- runConduit $ getOrphans .| sinkList
            case orphans of
                [] -> $(logDebugS) "Block" "No orphan tranasctions to import"
                _ ->
                    $(logDebugS) "Block" $
                    "Importing " <> cs (show (length orphans)) <>
                    " orphan transactions"
            ops <-
                zip (map snd orphans) <$>
                forM orphans (runImport . uncurry (importOrphan net))
            let tths =
                    [ (txHash tx, hs)
                    | (tx, emths) <- ops
                    , let Right (Just hs) = emths
                    ]
                ihs = map fst tths
                dhs = concatMap snd tths
            l <- blockConfListener <$> asks myConfig
            atomically $ do
                mapM_ (l . StoreTxDeleted) dhs
                mapM_ (l . StoreMempoolNew) ihs
            $(logDebugS) "Block" "Finished importing orphans"


processTxs ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Peer
    -> [TxHash]
    -> ReaderT BlockRead m ()
processTxs p hs =
    isSynced >>= \case
        False ->
            $(logDebugS) "Block" "Ignoring incoming tx inv (not synced yet)"
        True -> do
            $(logDebugS) "Block" $
                "Received " <> fromString (show (length hs)) <>
                " transaction inventory"
            xs <-
                fmap catMaybes . forM hs $ \h ->
                    runMaybeT $ do
                        t <- lift $ getTxData h
                        guard (isNothing t)
                        return (getTxHash h)
            unless (null xs) $ do
                $(logDebugS) "Block" $
                    "Requesting " <> fromString (show (length xs)) <>
                    " new transactions"
                net <- blockConfNet <$> asks myConfig
                let inv =
                        if getSegWit net
                            then InvWitnessTx
                            else InvTx
                MGetData (GetData (map (InvVector inv) xs)) `sendMessage` p

checkTime :: (MonadUnliftIO m, MonadLoggerIO m) => ReaderT BlockRead m ()
checkTime =
    asks myPeer >>= readTVarIO >>= \case
        Nothing -> $(logDebugS) "Block" "Peer timeout check: no syncing peer"
        Just Syncing {syncingTime = t, syncingPeer = p} -> do
            n <- fromIntegral . systemSeconds <$> liftIO getSystemTime
            if n > t + 60
                then do
                    $(logErrorS) "Block" "Peer timeout"
                    resetPeer
                    killPeer PeerTimeout p
                    syncMe
                else $(logDebugS) "Block" "Peer timeout not reached"

processDisconnect ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Peer
    -> ReaderT BlockRead m ()
processDisconnect p =
    asks myPeer >>= readTVarIO >>= \case
        Nothing ->
            $(logDebugS) "Block" "Ignoring peer disconnection notification"
        Just Syncing {syncingPeer = p'}
            | p == p' -> do
                $(logErrorS) "Block" "Syncing peer disconnected"
                resetPeer
                syncMe
            | otherwise -> $(logDebugS) "Block" "Non-syncing peer disconnected"

purgeMempool ::
       (MonadUnliftIO m, MonadLoggerIO m) => ReaderT BlockRead m ()
purgeMempool = $(logErrorS) "Block" "Mempool purging not implemented"

syncMe :: (MonadUnliftIO m, MonadLoggerIO m) => ReaderT BlockRead m ()
syncMe =
    void . runMaybeT $ do
        bths <- rev
        l <- blockConfListener <$> asks myConfig
        let dbs = map fst bths
            ths = concatMap snd bths
        atomically $ do
            mapM_ (l . StoreTxDeleted) ths
            mapM_ (l . StoreBlockReverted) dbs
        p <-
            gpr >>= \case
                Nothing -> do
                    $(logWarnS)
                        "Block"
                        "Not syncing blocks as no peers available"
                    mzero
                Just p -> return p
        $(logDebugS) "Block" "Syncing blocks against network peer"
        b <- mbn
        d <- dbn
        c <- cbn
        when (end b d c) $ do
            $(logDebugS) "Block" $
                "Already requested up to block height: " <>
                cs (show (nodeHeight b))
            mzero
        ns <- bls c b
        setPeer p (last ns)
        net <- blockConfNet <$> asks myConfig
        let inv =
                if getSegWit net
                    then InvWitnessBlock
                    else InvBlock
        vs <- mapM (f inv) ns
        $(logInfoS) "Block" $
            "Requesting " <> fromString (show (length vs)) <> " blocks"
        MGetData (GetData vs) `sendMessage` p
  where
    gpr =
        asks myPeer >>= readTVarIO >>= \case
            Just Syncing {syncingPeer = p} -> return (Just p)
            Nothing ->
                blockConfManager <$> asks myConfig >>= managerGetPeers >>= \case
                    [] -> return Nothing
                    OnlinePeer {onlinePeerMailbox = p}:_ -> return (Just p)
    cbn = chainGetBest =<< blockConfChain <$> asks myConfig
    dbn = do
        bb <-
            lift getBestBlock >>= \case
                Nothing -> do
                    $(logErrorS) "Block" "Best block not in database"
                    throwIO Uninitialized
                Just b -> return b
        ch <- blockConfChain <$> asks myConfig
        chainGetBlock bb ch >>= \case
            Nothing -> do
                $(logErrorS) "Block" $
                    "Block header not found for best block " <>
                    blockHashToHex bb
                throwIO (BlockNotInChain bb)
            Just x -> return x
    mbn =
        asks myPeer >>= readTVarIO >>= \case
            Just Syncing {syncingHead = b} -> return b
            Nothing -> dbn
    end b d c
        | nodeHeader b == nodeHeader c = True
        | otherwise = nodeHeight b > nodeHeight d + 500
    f _ GenesisNode {} = throwIO UnexpectedGenesisNode
    f inv BlockNode {nodeHeader = bh} =
        return $ InvVector inv (getBlockHash (headerHash bh))
    bls c b = do
        t <- top c (tts (nodeHeight c) (nodeHeight b))
        ch <- blockConfChain <$> asks myConfig
        ps <- chainGetParents (nodeHeight b + 1) t ch
        return $
            if length ps < 500
                then ps <> [c]
                else ps
    tts c b
        | c <= b + 501 = c
        | otherwise = b + 501
    top c t = do
        ch <- blockConfChain <$> asks myConfig
        if t == nodeHeight c
            then return c
            else chainGetAncestor t c ch >>= \case
                     Just x -> return x
                     Nothing -> do
                         $(logErrorS) "Block" $
                             "Unknown header for ancestor of block " <>
                             blockHashToHex (headerHash (nodeHeader c)) <>
                             " at height " <>
                             fromString (show t)
                         throwIO $
                             AncestorNotInChain t (headerHash (nodeHeader c))
    rev = do
        d <- headerHash . nodeHeader <$> dbn
        ch <- blockConfChain <$> asks myConfig
        chainBlockMain d ch >>= \case
            True -> return []
            False -> do
                $(logErrorS) "Block" $
                    "Reverting best block " <> blockHashToHex d <>
                    " as it is not in main chain..."
                resetPeer
                net <- asks (blockConfNet . myConfig)
                lift (runImport (revertBlock net d)) >>= \case
                    Left e -> do
                        $(logErrorS) "Block" $
                            "Could not revert best block: " <>
                            fromString (show e)
                        throwIO e
                    Right ths -> ((d, ths) :) <$> rev

resetPeer :: (MonadLoggerIO m, MonadReader BlockRead m) => m ()
resetPeer = do
    $(logDebugS) "Block" "Resetting syncing peer..."
    box <- asks myPeer
    atomically $ writeTVar box Nothing

setPeer :: (MonadIO m, MonadReader BlockRead m) => Peer -> BlockNode -> m ()
setPeer p b = do
    box <- asks myPeer
    now <- fromIntegral . systemSeconds <$> liftIO getSystemTime
    atomically . writeTVar box $
        Just Syncing {syncingPeer = p, syncingHead = b, syncingTime = now}

processBlockMessage ::
       (MonadResource m, MonadUnliftIO m, MonadLoggerIO m)
    => BlockMessage
    -> BlockT m ()
processBlockMessage (BlockNewBest bn) = do
    $(logDebugS) "Block" $
        "New best block header " <> fromString (show (nodeHeight bn)) <> ": " <>
        blockHashToHex (headerHash (nodeHeader bn))
    syncMe
processBlockMessage (BlockPeerConnect _p sa) = do
    $(logDebugS) "Block" $ "New peer connected: " <> fromString (show sa)
    syncMe
processBlockMessage (BlockPeerDisconnect p _sa) = processDisconnect p
processBlockMessage (BlockReceived p b) = processBlock p b
processBlockMessage (BlockNotFound p bs) = processNoBlocks p bs
processBlockMessage (BlockTxReceived p tx) = processTx p tx
processBlockMessage (BlockTxAvailable p ts) = processTxs p ts
processBlockMessage (BlockPing r) =
    processOrphans >> checkTime >> atomically (r ())
processBlockMessage PurgeMempool = purgeMempool

pingMe :: MonadLoggerIO m => Mailbox BlockMessage -> m ()
pingMe mbox = forever $ do
    threadDelay =<< liftIO (randomRIO (5 * 1000 * 1000, 10 * 1000 * 1000))
    $(logDebugS) "BlockTimer" "Pinging block"
    BlockPing `query` mbox
