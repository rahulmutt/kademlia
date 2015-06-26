{-|
Module      : Network.Kademlia.Implementation
Description : The details of the lookup algorithm

"Network.Kademlia.Implementation" contains the actual implementations of the
different Kademlia Network Algorithms.
-}

module Network.Kademlia.Implementation
    ( lookup
    , store
    , joinNetwork
    ) where

import Network.Kademlia.Networking
import Network.Kademlia.Instance
import qualified Network.Kademlia.Tree as T
import Network.Kademlia.Types
import Network.Kademlia.ReplyQueue
import Prelude hiding (lookup)
import Control.Monad (forM_, unless, when)
import Control.Monad.Trans.State hiding (state)
import Control.Concurrent.Chan
import Control.Concurrent.STM
import Control.Monad.IO.Class (liftIO)
import Data.List (delete, find)
import Data.Maybe (isJust, fromJust)


-- Lookup the value corresponding to a key in the DHT
lookup :: (Serialize i, Serialize a, Eq i, Ord i) => KademliaInstance i a -> i
       -> IO (Maybe a)
lookup inst id = runLookup go inst id
    where go = startLookup sendS cancel checkCommand

          -- Return Nothing on lookup failure
          cancel = return Nothing

          -- When receiving a RETURN_VALUE command, return the value and stop
          -- don't continue the lookup
          checkCommand (RETURN_VALUE _ value) = return . Just $ value

          -- When receiving a RETURN_NODES command, throw the nodes into the
          -- lookup loop and continue the lookup
          checkCommand (RETURN_NODES _ nodes) =
                continueLookup nodes sendS continue cancel

          -- Continuing always means waiting for the next signal
          continue = waitForReply cancel checkCommand sendS

          -- Send a FIND_VALUE command, looking for the supplied id
          sendS = sendSignal (FIND_VALUE id)

-- Store assign a value to a key and store it in the DHT
store :: (Serialize i, Serialize a, Eq i, Ord i) =>
         KademliaInstance i a -> i -> a -> IO ()
store inst key val = runLookup go inst key
    where go = startLookup sendS end checkCommand

          -- Always add the nodes into the loop and continue the lookup
          checkCommand (RETURN_NODES _ nodes) =
                continueLookup nodes sendS continue end

          -- Continuing always means waiting for the next signal
          continue = waitForReply end checkCommand sendS

          -- Send a FIND_NODE command, looking for the node corresponding to the
          -- key
          sendS = sendSignal (FIND_NODE key)

          -- Run the lookup as long as possible, to make sure the nodes closest
          -- to the key were polled.
          end = do
            polled <- gets polled
            unless (null polled) $ do
                let h = handle inst
                    -- Select the peer closest to the key
                    storePeer = peer . head . sortByDistanceTo polled $ key
                -- Send it a STORE command
                liftIO . send h storePeer . STORE key $ val

-- Make a KademliaInstance join the network a supplied Node is in
joinNetwork :: (Serialize i, Serialize a, Eq i, Ord i) => KademliaInstance i a
            -> Node i -> IO ()
joinNetwork inst node = ownId >>= runLookup go inst
    where go = do
            -- Poll the supplied node
            sendS node
            -- Run a normal lookup from thereon out
            waitForReply cancel checkCommand sendS

          -- Do nothing upon failure or when the join operation has terminated
          cancel = return ()

          -- Retrieve your own id
          ownId =
            fmap T.extractId . atomically . readTVar .  sTree . state $ inst

          -- Always add the nodes into the loop and continue the lookup
          checkCommand (RETURN_NODES _ nodes) =
            continueLookup nodes sendS continue cancel

          -- Continuing always means waiting for the next signal
          continue = waitForReply cancel checkCommand sendS

          -- Send a FIND_NODE command, looking up your own id
          sendS node = liftIO ownId >>= flip sendSignal node . FIND_NODE

-- | The state of a lookup
data LookupState i a = LookupState {
      inst :: KademliaInstance i a
    , targetId :: i
    , replyChan :: Chan (Reply i a)
    , known :: [Node i]
    , pending :: [Node i]
    , polled :: [Node i]
    , timedOut :: [Node i]
    }

-- | MonadTransformer context of a lookup
type LookupM i a = StateT (LookupState i a) IO

-- Run a LookupM, returning its result
runLookup :: LookupM i a b -> KademliaInstance i a -> i ->IO b
runLookup lookup inst id = do
    chan <- newChan
    let state = LookupState inst id chan [] [] [] []

    evalStateT lookup state

-- The initial phase of the normal kademlia lookup operation
startLookup :: (Serialize i, Serialize a, Eq i, Ord i) => (Node i -> LookupM i a ())
            -> LookupM i a b -> (Command i a -> LookupM i a b) -> LookupM i a b
startLookup sendSignal cancel onCommand = do
    inst <- gets inst
    tree <- liftIO . atomically . readTVar . sTree . state $ inst
    chan <- gets replyChan
    id <- gets targetId

    -- Find the three nodes closest to the supplied id
    case T.findClosest tree id 3 of
            [] -> cancel
            closest -> do
                -- Send a signal to each of the Nodes
                forM_ closest sendSignal

                -- Add them to the list of known nodes. At this point, it will
                -- be empty, therfore just overwrite it.
                modify $ \s -> s { known = closest }

                -- Start the recursive lookup
                waitForReply cancel onCommand sendSignal

-- Wait for the next reply and handle it appropriately
waitForReply :: (Serialize i, Serialize a, Ord i) => LookupM i a b
             -> (Command i a -> LookupM i a b) -> (Node i -> LookupM i a ())
             -> LookupM i a b
waitForReply cancel onCommand sendSignal = do
    chan <- gets replyChan
    sPending <- gets pending
    known <- gets known
    inst <- gets inst
    polled <- gets polled

    result <- liftIO . readChan $ chan
    case result of
        -- If there was a reply
        Answer sig@(Signal node _) -> do
            -- Insert the node into the tree, as it might be a new one or it
            -- would have to be refreshed
            liftIO . insertNode inst $ node

            -- Remove the node from the list of nodes with pending replies
            modify $ \s -> s { pending = delete node sPending }

            -- Call the command handler
            onCommand . command $ sig

        -- On timeout
        Timeout id -> do
            timedOut <- gets timedOut

            -- Find the node corresponding to the id
            --
            -- ReplyQueue guarantees us, that it will be in polled, therefore
            -- we can use fromJust
            let node = fromJust . find (\n -> nodeId n == id) $ polled

            -- Node hasn't already timed out once during the lookup
            if node `notElem` timedOut
                -- Resend the signal for a node that timed out the for first
                -- time.
                --
                -- This is appropriate, as UDP doesn't guarantee for all the
                -- packages to arrive, so, because a lookup operation means
                -- sending a lot of packets at the same time, the fault
                -- might very well be on out side, therefore a timeout
                -- doesn't neccessarily mean a disconnect.
                then do
                    modify $ \s -> s {
                          -- Remove the node from the list of pending
                          -- nodes, as it will be added again when
                          -- sendSignal is called
                          pending = delete node sPending

                          -- Add the node to the list of timedOut nodes
                        , timedOut = node:timedOut
                        }

                    -- Repoll the node
                    sendSignal node

                -- Delete a node that timed out twice
                else do
                    liftIO . deleteNode inst $ id

                    -- Remove every trace of the node's existance
                    modify $ \s -> s {
                          pending = delete node sPending
                        , known = delete node known
                        , polled = delete node polled
                        }

            -- Continue, if there still are pending responses
            updatedPending <- gets pending
            if not . null $ updatedPending
                then waitForReply cancel onCommand sendSignal
                else cancel

        Closed -> cancel

-- Decide wether, and which node to poll and react appropriately.
--
-- This is the meat of kademlia lookups
continueLookup :: (Serialize i, Serialize a, Eq i) => [Node i]
               -> (Node i -> LookupM i a ()) -> LookupM i a b -> LookupM i a b
               -> LookupM i a b
continueLookup nodes sendSignal continue end = do
    known <- gets known
    id <- gets targetId
    pending <- gets pending
    polled <- gets polled

    -- Pick the k closest known nodes, that haven't been polled yet
    let newKnown = take 7 . filter (`notElem` polled) $ nodes ++ known

    -- If there the k closest nodes haven't been polled yet
    closestPolled <- closestPolled newKnown
    if (not . null $ newKnown) && not closestPolled
        then do
            -- Send signal to the closest node, that hasn't
            -- been polled yet
            let next = head . sortByDistanceTo newKnown $ id
            sendSignal next

            -- Update known
            modify $ \s -> s { known = newKnown }

            -- Continue the lookup
            continue

        -- If there are still pending replies
        else if not . null $ pending
            -- Wait for the pending replies to finish
            then continue
            -- Stop recursive lookup
            else end

    where closestPolled known = do
            polled <- gets polled
            closest <- closest known

            return . all (`elem` polled) $ closest

          closest known = do
            id <- gets targetId
            polled <- gets polled

            -- Return the 7 closest nodes, the lookup had contact with
            return . take 7 . sortByDistanceTo (known ++ polled) $ id

-- Send a signal to a node
sendSignal :: (Serialize i, Serialize a, Eq i) => Command i a
          -> Node i -> LookupM i a ()
sendSignal cmd node = do
    h <- fmap handle . gets $ inst
    chan <- gets replyChan
    polled <- gets polled
    pending <- gets pending

    -- Send the signal
    liftIO . send h (peer node) $ cmd

    -- Expect an appropriate reply to the command
    liftIO . expect h regs $ chan

    -- Mark the node as polled and pending
    modify $ \s -> s {
          polled = node:polled
        , pending = node:pending
        }

    -- Determine the appropriate ReplyRegistrations to the command
    where regs = case cmd of
                    (FIND_NODE id)  -> RR [R_RETURN_NODES id] (nodeId node)
                    (FIND_VALUE id) ->
                        RR [R_RETURN_NODES id, R_RETURN_VALUE id] (nodeId node)
