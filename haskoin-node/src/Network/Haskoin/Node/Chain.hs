{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# LANGUAGE UndecidableInstances      #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Network.Haskoin.Node.Chain
( chain
) where

import           Control.Concurrent.NQE
import           Control.Monad
import           Control.Monad.Base
import           Control.Monad.Catch
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Control.Monad.Trans.Control
import qualified Data.ByteString             as BS
import           Data.Default
import           Data.List
import           Data.Maybe
import           Data.String.Conversions
import           Data.Text                   (Text)
import           Database.LevelDB            (DB, MonadResource, runResourceT)
import qualified Database.LevelDB            as LevelDB
import           Network.Haskoin.Block
import           Network.Haskoin.Network
import           Network.Haskoin.Node.Common
import           Network.Haskoin.Util

type MonadChain m
     = ( BlockHeaders m
       , MonadLoggerIO m
       , MonadReader ChainReader m
       , MonadResource m)

data ChainState = ChainState
    { syncingPeer :: !(Maybe Peer)
    , newPeers    :: ![Peer]
    , mySynced    :: !Bool
    }

data ChainReader = ChainReader
    { headerDB   :: !DB
    , myConfig   :: !ChainConfig
    , chainState :: !(TVar ChainState)
    }

instance (Monad m, MonadLoggerIO m, MonadReader ChainReader m, MonadResource m) =>
         BlockHeaders m where
    addBlockHeader bn = do
        db <- asks headerDB
        let bs = encodeStrict bn
            sh = encodeStrict $ headerHash $ nodeHeader bn
        LevelDB.put db def sh bs
    getBlockHeader bh = do
        db <- asks headerDB
        let sh = encodeStrict bh
        bsM <- LevelDB.get db def sh
        return $ decodeStrict <$> bsM
    getBestBlockHeader = do
        db <- asks headerDB
        $(logDebug) $ logMe <> "Get best block header from database"
        bsM <- LevelDB.get db def "best"
        $(logDebug) $ logMe <> "Database query complete"
        case bsM of
            Nothing -> do
                $(logDebug) $ logMe <> "Did not find best block"
                let gs = encodeStrict genesisNode
                addBlockHeader genesisNode
                LevelDB.put db def "best" gs
                $(logDebug) $ logMe <> "Added genesis block node"
                return genesisNode
            Just bs -> do
                $(logDebug) $ logMe <> "Got best block, decoding"
                return $ decodeStrict bs
    setBestBlockHeader bn = do
        db <- asks headerDB
        let bs = encodeStrict bn
        LevelDB.put db def "best" bs
    addBlockHeaders bns = do
        db <- asks headerDB
        LevelDB.write db def $
            map
                (\bn ->
                     LevelDB.Put
                         (encodeStrict $ headerHash $ nodeHeader bn)
                         (encodeStrict bn))
                bns

chain ::
       ( MonadBase IO m
       , MonadBaseControl IO m
       , MonadLoggerIO m
       , MonadThrow m
       , MonadMask m
       , MonadCatch m
       , Forall (Pure m)
       )
    => ChainConfig
    -> m ()
chain cfg =
    runResourceT $ do
        let opts = def {LevelDB.createIfMissing = True}
        hdb <- LevelDB.open (chainConfDbFile cfg) opts
        st <-
            liftIO $
            newTVarIO
                ChainState
                {syncingPeer = Nothing, mySynced = False, newPeers = []}
        let rd = ChainReader {myConfig = cfg, headerDB = hdb, chainState = st}
        run `runReaderT` rd
  where
    run =
        forever $ do
            $(logDebug) $ logMe <> "Awaiting message"
            msg <- receive $ chainConfChain cfg
            processChainMessage msg

processChainMessage :: MonadChain m => ChainMessage -> m ()
processChainMessage (ChainNewHeaders p hcs) = do
    $(logDebug) $ logMe <> "Got headers"
    stb <- asks chainState
    st <- liftIO $ readTVarIO stb
    let spM = syncingPeer st
    t <- computeTime
    bb <- getBestBlockHeader
    bhsE <- connectBlocks t (map fst hcs)
    case bhsE of
        Right bhs -> conn bb bhs spM
        Left e -> do
            $(logInfo) $ logMe <> "Could not connect headers: " <> cs e
            case spM of
                Nothing -> do
                    $(logInfo) $ logMe <> "Attempting to connect headers"
                    bb' <- getBestBlockHeader
                    liftIO . atomically . modifyTVar stb $ \s ->
                        s {newPeers = nub $ p : newPeers s}
                    syncHeaders bb' p
                Just sp
                    | sp == p -> do
                        $(logError) $ logMe <> "Syncing peer sent bad headers"
                        mgr <- chainConfManager <$> asks myConfig
                        managerKill PeerSentBadHeaders p mgr
                        liftIO . atomically . modifyTVar stb $ \s ->
                            s {syncingPeer = Nothing}
                        processSyncQueue
                    | otherwise -> do
                        $(logDebug) $ logMe <> "Sync from this peer later"
                        liftIO . atomically . modifyTVar stb $ \s ->
                            s {newPeers = nub $ p : newPeers s}
  where
    synced bb = do
        $(logDebug) $
            logMe <> "Headers synced to height " <> cs (show $ nodeHeight bb)
        st <- asks chainState
        liftIO . atomically . modifyTVar st $ \s -> s {syncingPeer = Nothing}
        MSendHeaders `sendMessage` p
        mgr <- chainConfManager <$> asks myConfig
        managerFreePeer p mgr
        processSyncQueue
    upeer bb = do
        $(logDebug) $
            logMe <> "Updating peer to height " <> cs (show $ nodeHeight bb)
        mgr <- chainConfManager <$> asks myConfig
        managerSetPeerBest p bb mgr
    conn bb bhs spM = do
        bb' <- getBestBlockHeader
        when (bb /= bb') $ do
            $(logDebug) $ logMe <> "Sending best block notification"
            mgr <- chainConfManager <$> asks myConfig
            managerSetBest bb' mgr
            l <- chainConfListener <$> asks myConfig
            liftIO . atomically . l $ ChainNewBest bb'
        case length hcs of
            0 -> synced bb'
            2000 ->
                case spM of
                    Just sp
                        | sp == p -> do
                            upeer $ head bhs
                            $(logDebug) $ logMe <> "Syncing more headers"
                            syncHeaders (head bhs) p
                    _ -> do
                        $(logDebug) $ logMe <> "Sync from this peer later"
                        st <- asks chainState
                        liftIO . atomically . modifyTVar st $ \s ->
                            s {newPeers = nub $ p : newPeers s}
            _ -> do
                upeer $ head bhs
                synced bb'

processChainMessage (ChainNewPeer p) = do
    $(logDebug) $ logMe <> "Got connected peer"
    st <- asks chainState
    sp <- liftIO . atomically $ do
        modifyTVar st $ \s -> s {newPeers = p : newPeers s}
        syncingPeer <$> readTVar st
    case sp of
        Nothing -> processSyncQueue
        Just _  -> return ()

processChainMessage (ChainFreePeer p) = do
    $(logDebug) $ logMe <> "Got free peer"
    st <- asks chainState
    s <- liftIO $ readTVarIO st
    when (p `elem` newPeers s) $
        case syncingPeer s of
            Nothing -> do
                bb <- getBestBlockHeader
                syncHeaders bb p
            Just _ -> return ()

processChainMessage (ChainRemovePeer p) = do
    $(logWarn) $ logMe <> "Got peer disconnection"
    st <- asks chainState
    sp <-
        liftIO . atomically $ do
            modifyTVar st $ \s -> s {newPeers = filter (/= p) (newPeers s)}
            syncingPeer <$> readTVar st
    case sp of
        Just p' ->
            when (p == p') $ do
                liftIO . atomically . modifyTVar st $ \s ->
                    s {syncingPeer = Nothing}
                processSyncQueue
        Nothing -> return ()

processChainMessage (ChainGetBest reply) = do
    $(logDebug) $ logMe <> "Got request for best block"
    b <- getBestBlockHeader
    $(logDebug) $ logMe <> "Best block at height " <> logShow (nodeHeight b)
    liftIO . atomically $ reply b

processChainMessage (ChainGetAncestor h n reply) = do
    $(logDebug) $
        logMe <> "Got request for ancestor of " <> logShow (nodeHeight n) <>
        " at height " <>
        logShow h
    a <- getAncestor h n
    liftIO . atomically $ reply a

processChainMessage (ChainGetSplit r l reply) = do
    $(logDebug) $
        logMe <> "Got request for split point between " <>
        logShow (nodeHeight r) <>
        " and " <>
        logShow (nodeHeight l)
    s <- splitPoint r l
    liftIO . atomically $ reply s

processChainMessage (ChainGetBlock h reply) = do
    $(logDebug) $ logMe <> "Got request for block " <> logShow h
    b <- getBlockHeader h
    liftIO . atomically $ reply b

processChainMessage (ChainSendHeaders _) =
    -- TODO: implement header syncing for peers
    $(logDebug) $ logMe <> "Ignoring sendheaders from peer"

processChainMessage (ChainIsSynced reply) = do
    st <- asks chainState
    s <- liftIO $ mySynced <$> readTVarIO st
    $(logDebug) $ logMe <> "Synced? " <> logShow s
    liftIO . atomically $ reply s

processSyncQueue :: MonadChain m => m ()
processSyncQueue = do
    s <- asks chainState >>= liftIO . readTVarIO
    when (isNothing (syncingPeer s)) $ getBestBlockHeader >>= go s
  where
    go s bb =
        case newPeers s of
            [] -> do
                $(logDebug) $ logMe <> "No more peers to sync"
                t <- computeTime
                let h2 = t - 2 * 60 * 60
                    tg = blockTimestamp (nodeHeader bb) > h2
                if tg
                    then unless (mySynced s) $ do
                             $(logDebug) $ logMe <> "Headers are now synced"
                             l <- chainConfListener <$> asks myConfig
                             st <- asks chainState
                             liftIO . atomically $ do
                                 l $ ChainSynced bb
                                 writeTVar st s {mySynced = True}
                    else do
                        $(logDebug) $ logMe <> "Headers are not synced"
                        l <- chainConfListener <$> asks myConfig
                        st <- asks chainState
                        liftIO . atomically $ do
                            l $ ChainNotSynced bb
                            writeTVar st s {mySynced = False}
            p:_ -> do
                $(logDebug) $ logMe <> "Syncing against new peer"
                syncHeaders bb p

syncHeaders :: MonadChain m => BlockNode -> Peer -> m ()
syncHeaders bb p = do
    $(logDebug) $ logMe <> "Attempting to sync headers with a peer"
    mgr <- chainConfManager <$> asks myConfig
    st <- asks chainState
    s <- liftIO $ readTVarIO st
    t <-
        if syncingPeer s == Just p
            then return True
            else managerTakePeer p mgr
    when t $ do
        $(logDebug) $ logMe <> "Successfully took peer to sync"
        liftIO . atomically . writeTVar st $
            s {syncingPeer = Just p, newPeers = filter (/= p) (newPeers s)}
        $(logDebug) $ logMe <> "Constructing block locator"
        loc <- blockLocator bb
        $(logDebug) $ logMe <> "Preparing getheaders message"
        let m =
                MGetHeaders
                    GetHeaders
                    { getHeadersVersion = myVersion
                    , getHeadersBL = loc
                    , getHeadersHashStop = decodeStrict $ BS.replicate 32 0
                    }
        $(logDebug) $ logMe <> "Sending getheaders message to syncing peer"
        PeerOutgoing m `send` p

logMe :: Text
logMe = "[Chain] "
