{-|
Module      : Network.Kademlia.Instance
Description : Implementation of the KademliaInstance type

"Network.Kademlia.Instance" implements the KademliaInstance type, as well
as all the things that need to happen in the background to get a working
Kademlia instance.
-}

module Network.Kademlia.Instance
    ( KademliaInstance(..)
    , KademliaState(..)
    , start
    , newInstance
    , insertNode
    , deleteNode
    , lookupNode
    ) where

import Control.Concurrent
import Control.Concurrent.Chan
import Control.Concurrent.STM
import Control.Monad (void, forever, when)
import Control.Monad.Trans
import Control.Monad.Trans.State
import Control.Monad.Trans.Reader
import Control.Monad.IO.Class (liftIO)
import System.IO.Error (catchIOError)
import qualified Data.Map as M

import Network.Kademlia.Networking
import qualified Network.Kademlia.Tree as T
import Network.Kademlia.Types
import Network.Kademlia.ReplyQueue

-- | The handle of a running Kademlia Node
data KademliaInstance i a = KI {
      handle :: KademliaHandle i a
    , state :: KademliaState i a
    }

-- | Representation of the data the KademliaProcess carries
data KademliaState i a = KS {
      sTree   :: TVar (T.NodeTree i)
    , values :: TVar (M.Map i a)
    }

-- | Create a new KademliaInstance from an Id and a KademliaHandle
newInstance :: (Serialize i) =>
               i -> KademliaHandle i a -> IO (KademliaInstance i a)
newInstance id handle = do
    tree <- atomically . newTVar . T.create $ id
    values <- atomically . newTVar $ M.empty
    return . KI handle . KS tree $ values

insertNode :: (Serialize i, Ord i) => KademliaInstance i a -> Node i -> IO ()
insertNode (KI _ (KS sTree _)) node = atomically $ do
    tree <- readTVar sTree
    writeTVar sTree . T.insert tree $ node

deleteNode :: (Serialize i, Ord i) => KademliaInstance i a -> i -> IO ()
deleteNode (KI _ (KS sTree _)) id = atomically $ do
    tree <- readTVar sTree
    writeTVar sTree . T.delete tree $ id

lookupNode :: (Serialize i, Ord i) => KademliaInstance i a -> i -> IO (Maybe (Node i))
lookupNode (KI _ (KS sTree _)) id = atomically $ do
    tree <- readTVar sTree
    return . T.lookup tree $ id

insertValue :: (Ord i) => i -> a -> KademliaInstance i a -> IO ()
insertValue key value (KI _ (KS _ values)) = atomically $ do
    vals <- readTVar values
    writeTVar values $ M.insert key value vals

lookupValue :: (Ord i) => i -> KademliaInstance i a -> IO (Maybe a)
lookupValue key (KI _ (KS _ values)) = atomically $ do
    vals <- readTVar values
    return . M.lookup key $ vals

-- | Start the background process for a KademliaInstance
start :: (Serialize i, Ord i, Serialize a, Eq i, Eq a) =>
    KademliaInstance i a -> IO ()
start inst = do
        chan <- newChan
        startRecvProcess (handle inst) chan
        void . forkIO $ backgroundProcess inst chan

-- | The actual process running in the background
backgroundProcess :: (Serialize i, Ord i, Serialize a, Eq i, Eq a) =>
    KademliaInstance i a -> Chan (Reply i a) -> IO ()
backgroundProcess inst chan = do
    reply <- liftIO . readChan $ chan

    case reply of
        Answer sig -> do
            let node = source sig

            -- Handle the signal
            handleCommand (command sig) (peer node) inst

            -- Insert the node into the tree, if it's allready known, it will
            -- be refreshed
            insertNode inst node

            backgroundProcess inst chan

        -- Delete timed out nodes
        Timeout id -> deleteNode inst id

        -- Stop on Closed
        Closed -> return ()


-- | Handles the differendt Kademlia Commands appropriately
handleCommand :: (Serialize i, Eq i, Ord i, Serialize a) =>
    Command i a -> Peer -> KademliaInstance i a -> IO ()
-- Simply answer a PING with a PONG
handleCommand PING peer inst = send (handle inst) peer PONG
-- Return a KBucket with the closest Nodes
handleCommand (FIND_NODE id) peer inst = returnNodes peer id inst
-- Insert the value into the values Map
handleCommand (STORE key value) _ inst = insertValue key value inst
-- Return the value, if known, or the closest other known Nodes
handleCommand (FIND_VALUE key) peer inst = do
    result <- lookupValue key inst
    case result of
        Just value -> liftIO $ send (handle inst) peer $ RETURN_VALUE key value
        Nothing    -> returnNodes peer key inst
handleCommand _ _ _ = return ()

-- | Return a KBucket with the closest Nodes to a supplied Id
returnNodes :: (Serialize i, Eq i, Ord i, Serialize a) =>
    Peer -> i -> KademliaInstance i a -> IO ()
returnNodes peer id (KI h (KS sTree _)) = do
    tree <- atomically . readTVar $ sTree
    let nodes = T.findClosest tree id 7
    liftIO $ send h peer (RETURN_NODES id nodes)
