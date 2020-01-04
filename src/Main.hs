{-
███╗   ██╗███████╗████████╗ ██████╗██╗  ██╗ █████╗ ███╗   ██╗ ██████╗ ███████╗
████╗  ██║██╔════╝╚══██╔══╝██╔════╝██║  ██║██╔══██╗████╗  ██║██╔════╝ ██╔════╝
██╔██╗ ██║█████╗     ██║   ██║     ███████║███████║██╔██╗ ██║██║  ███╗█████╗  
██║╚██╗██║██╔══╝     ██║   ██║     ██╔══██║██╔══██║██║╚██╗██║██║   ██║██╔══╝  
██║ ╚████║███████╗   ██║   ╚██████╗██║  ██║██║  ██║██║ ╚████║╚██████╔╝███████╗
╚═╝  ╚═══╝╚══════╝   ╚═╝    ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝ ╚═════╝ ╚══════╝
-}
{-
Utrecht University Concurrency Assignment 2
Made by:
Lars Teunissen, 6600662
Max van Gogh, 5822904 
-}


module Main where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import System.Environment
import System.IO
import Network.Socket
import Data.Char
import qualified Data.HashMap.Strict as HM
import Data.Maybe

type Destination = Int
type Distance = Int
type Neighbour = Int
type RoutingTable = HM.HashMap Int (TVar RoutingTableEntry)
data RoutingTableEntry = Local { localPort :: Destination}
                       | Node  { nodeDistance :: Distance
                               , nodeNeighbour :: Neighbour}
                               deriving (Eq, Show)

type NeighbourMap = HM.HashMap Neighbour (MVar Handle)

type WriteLock = MVar Int

main :: IO ()
main = do
  hSetBuffering stdout NoBuffering
  -- me :: Int is the port number of this process
  -- neighbours :: [Int] is a list of the port numbers of the initial neighbours
  -- During the execution, connections may be broken or constructed
  (me, neighbours) <- readCommandLineArguments

  putStrLn $ "I should be listening on port " ++ show me
  putStrLn $ "My initial neighbours are " ++ show neighbours

  -- Listen to the specified port.
  serverSocket <- socket AF_INET Stream 0
  setSocketOption serverSocket ReuseAddr 1
  bind serverSocket $ portToAddress me
  listen serverSocket 1024
  
  -- initiate write lock, routing table and neighbourmap
  writeLock <- newMVar 1
  ownrtEntry <- newTVarIO $ Local me
  rtTVar <- newTVarIO $ HM.singleton me ownrtEntry
  nmTVar <- newTVarIO $ HM.empty

  -- Fork a thread to listen for connections
  _ <- forkIO $ listenForConnections writeLock rtTVar nmTVar me serverSocket 

  -- Connect to all neighbours with a lower portnumber
  connectToLowerNeighbours writeLock rtTVar nmTVar me neighbours
 
  -- Start listening for console commands.
  -- By making the main thread listen for console commands the program will never stop during runtime
  listenForCommands writeLock rtTVar nmTVar me

{-
██╗███╗   ██╗██╗████████╗██╗ █████╗ ██╗     ██╗███████╗ █████╗ ████████╗██╗ ██████╗ ███╗   ██╗
██║████╗  ██║██║╚══██╔══╝██║██╔══██╗██║     ██║╚══███╔╝██╔══██╗╚══██╔══╝██║██╔═══██╗████╗  ██║
██║██╔██╗ ██║██║   ██║   ██║███████║██║     ██║  ███╔╝ ███████║   ██║   ██║██║   ██║██╔██╗ ██║
██║██║╚██╗██║██║   ██║   ██║██╔══██║██║     ██║ ███╔╝  ██╔══██║   ██║   ██║██║   ██║██║╚██╗██║
██║██║ ╚████║██║   ██║   ██║██║  ██║███████╗██║███████╗██║  ██║   ██║   ██║╚██████╔╝██║ ╚████║
╚═╝╚═╝  ╚═══╝╚═╝   ╚═╝   ╚═╝╚═╝  ╚═╝╚══════╝╚═╝╚══════╝╚═╝  ╚═╝   ╚═╝   ╚═╝ ╚═════╝ ╚═╝  ╚═══╝                                                 
-}
-- Connect to all neighbours whose port number is lower then yours
connectToLowerNeighbours :: WriteLock -> TVar RoutingTable -> TVar NeighbourMap -> Int -> [Neighbour] -> IO ()
connectToLowerNeighbours _ _ _ _ [] = return ()
connectToLowerNeighbours writeLock rtTVar nmTVar me (nb:nbs) | nb > me   = connectToLowerNeighbours writeLock rtTVar nmTVar me nbs
                                                             | otherwise = do
  connectToNeighbour writeLock rtTVar nmTVar me nb
  connectToLowerNeighbours writeLock rtTVar nmTVar me nbs

-- Create the connection to a neighbour
connectToNeighbour :: WriteLock -> TVar RoutingTable -> TVar NeighbourMap -> Int -> Neighbour -> IO ()
connectToNeighbour writeLock rtTVar nmTVar me nb = do
  -- get the socket and the handle
  nbSocket <- connectSocket nb
  nbHandle <- socketToHandle nbSocket ReadWriteMode
  -- create the MVar of the neighbours handle
  value <- newMVar nbHandle 
  -- atomically add this neighbour entry to the global neighbour map
  atomically $ modifyTVar' nmTVar (HM.insert nb value) -- modify the global neighbourmap to add this entry
  -- atomically add this neighbour to the global routing table
  atomically $ do
    rtEntry <- newTVar (Node 1 nb) -- create the routing table entry
    modifyTVar' rtTVar (HM.insert nb rtEntry)
  -- fork a thread to handle this neighbour
  _ <- forkIO $ handleNeighbourInit writeLock rtTVar nmTVar me nb
  return ()

-- Handle the connection to a neighbour
-- Initiation step
handleNeighbourInit :: WriteLock -> TVar RoutingTable -> TVar NeighbourMap -> Int -> Neighbour -> IO ()
handleNeighbourInit writeLock rtTVar nmTVar me nb = do
  hNICheck <- atomically $ do
    nm <- readTVar nmTVar
    return $ HM.lookup nb nm
  case hNICheck of
    Nothing -> return ()
    Just hMVar -> do
      h <- takeMVar hMVar
      _ <- hGetLine h
      hPutStrLn h $ "c" ++ show me
      putMVar hMVar h
      putStrLnConc writeLock $ "Connected " ++ show nb
      -- send current routingtable to this neighbour
      broadcastRoutingTableToNeighbour rtTVar hMVar
      -- send this new connections to all neighbours
      broadcastNewConnection nmTVar nb 1
      handleNeighbourLoop writeLock rtTVar nmTVar me nb
      
-- Read the command line to provide arguments for the program
readCommandLineArguments :: IO (Int, [Int])
readCommandLineArguments = do
  args <- getArgs
  case args of
    [] -> error "Not enough arguments. You should pass the port number of the current process and a list of neighbours"
    (me:neighbours) -> return (read me, map read neighbours)

-- Convert a given int to a port adress
portToAddress :: Int -> SockAddr
portToAddress portNumber = SockAddrInet (fromIntegral portNumber) (tupleToHostAddress (127, 0, 0, 1)) -- localhost

-- Connect to a given port and return the socket
connectSocket :: Int -> IO Socket
connectSocket portNumber = connect'
  where
    connect' = do
      client <- socket AF_INET Stream 0
      result <- try $ connect client $ portToAddress portNumber
      case result :: Either IOException () of
        Left _ -> do
          threadDelay 1000000
          connect'
        Right _ -> return client

{-
██╗      ██████╗  ██████╗ ██████╗ ███████╗
██║     ██╔═══██╗██╔═══██╗██╔══██╗██╔════╝
██║     ██║   ██║██║   ██║██████╔╝███████╗
██║     ██║   ██║██║   ██║██╔═══╝ ╚════██║
███████╗╚██████╔╝╚██████╔╝██║     ███████║
╚══════╝ ╚═════╝  ╚═════╝ ╚═╝     ╚══════╝
-}
-- Looping step of the neighbour handling
handleNeighbourLoop :: WriteLock -> TVar RoutingTable -> TVar NeighbourMap -> Int -> Neighbour -> IO ()
handleNeighbourLoop writeLock rtTVar nmTVar me nb = do
  hNLCheck <- atomically $ do
    nm <- readTVar nmTVar
    return $ HM.lookup nb nm
  case hNLCheck of
    Nothing -> return ()
    Just hMVar -> do
      h <- takeMVar hMVar
      messageWaiting <- hReady h -- Check if a message is ready for me
      case messageWaiting of
        True -> do
          message <- hGetLine h
          _ <- forkIO $ handleMessage writeLock rtTVar nmTVar nb message -- Handle the message if one was waiting for me
          putMVar hMVar h
        False -> do
          putMVar hMVar h -- Release the MVar if no message was ready for me
  threadDelay 10000
  handleNeighbourLoop writeLock rtTVar nmTVar me nb

-- Listen for incomming connections, these connections are new neighbours
listenForConnections :: WriteLock -> TVar RoutingTable -> TVar NeighbourMap -> Int -> Socket -> IO ()
listenForConnections writeLock rtTVar nmTVar me serverSocket = do
  (connection, _) <- accept serverSocket
  _ <- forkIO $ handleConnection writeLock rtTVar nmTVar me connection -- Fork a thread for this neighbour
  listenForConnections writeLock rtTVar nmTVar me serverSocket

-- Function that listens to the console of this application and handles the given commands
listenForCommands :: WriteLock -> TVar RoutingTable -> TVar NeighbourMap -> Int -> IO ()
listenForCommands writeLock rtTVar nmTVar me = do
  command <- getLine
  handleCommand writeLock rtTVar nmTVar me command 
  listenForCommands writeLock rtTVar nmTVar me

{-
██╗███╗   ██╗ ██████╗ ██████╗ ███╗   ███╗███╗   ███╗██╗███╗   ██╗ ██████╗      ██████╗ ██████╗ ███╗   ██╗███╗   ██╗███████╗ ██████╗████████╗██╗ ██████╗ ███╗   ██╗███████╗
██║████╗  ██║██╔════╝██╔═══██╗████╗ ████║████╗ ████║██║████╗  ██║██╔════╝     ██╔════╝██╔═══██╗████╗  ██║████╗  ██║██╔════╝██╔════╝╚══██╔══╝██║██╔═══██╗████╗  ██║██╔════╝
██║██╔██╗ ██║██║     ██║   ██║██╔████╔██║██╔████╔██║██║██╔██╗ ██║██║  ███╗    ██║     ██║   ██║██╔██╗ ██║██╔██╗ ██║█████╗  ██║        ██║   ██║██║   ██║██╔██╗ ██║███████╗
██║██║╚██╗██║██║     ██║   ██║██║╚██╔╝██║██║╚██╔╝██║██║██║╚██╗██║██║   ██║    ██║     ██║   ██║██║╚██╗██║██║╚██╗██║██╔══╝  ██║        ██║   ██║██║   ██║██║╚██╗██║╚════██║
██║██║ ╚████║╚██████╗╚██████╔╝██║ ╚═╝ ██║██║ ╚═╝ ██║██║██║ ╚████║╚██████╔╝    ╚██████╗╚██████╔╝██║ ╚████║██║ ╚████║███████╗╚██████╗   ██║   ██║╚██████╔╝██║ ╚████║███████║
╚═╝╚═╝  ╚═══╝ ╚═════╝ ╚═════╝ ╚═╝     ╚═╝╚═╝     ╚═╝╚═╝╚═╝  ╚═══╝ ╚═════╝      ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝╚═╝  ╚═══╝╚══════╝ ╚═════╝   ╚═╝   ╚═╝ ╚═════╝ ╚═╝  ╚═══╝╚══════╝                                                                                                                                                                          
-}
-- Handle the new neighbour by adding him to your tables
handleConnection :: WriteLock -> TVar RoutingTable -> TVar NeighbourMap -> Int -> Socket -> IO ()
handleConnection writeLock rtTVar nmTVar me connection = do
  chandle <- socketToHandle connection ReadWriteMode
  hPutStrLn chandle "ACK"
  (x:xs) <- hGetLine chandle
  case x of
    'c' -> handleConnect writeLock rtTVar nmTVar chandle me (read xs)
    _   -> error $ "handleConnection got a message not starting with c, instead it was: " ++ (x:xs)

-- Handle a new connection, aka a new neighbour
handleConnect :: WriteLock -> TVar RoutingTable -> TVar NeighbourMap -> Handle -> Int -> Neighbour -> IO ()
handleConnect writeLock rtTVar nmTVar h me nb = do
  value <- newMVar h
  atomically $ do -- Add this connection as a neighbour
    modifyTVar' nmTVar (HM.insert nb value)
    rtEntry <- newTVar (Node 1 nb)
    modifyTVar' rtTVar (HM.insert nb rtEntry)
  putStrLnConc writeLock $ "Connected: " ++ show nb
  broadcastNewConnection nmTVar nb 1 -- Broadcast this new connection to neighbours
  broadcastRoutingTableToNeighbour rtTVar value -- Send current routingtable to this neighbour
  handleNeighbourLoop writeLock rtTVar nmTVar me nb -- Initiate the neighbour handling loop

{-
██████╗ ██████╗  ██████╗  █████╗ ██████╗  ██████╗ █████╗ ███████╗████████╗██╗███╗   ██╗ ██████╗ 
██╔══██╗██╔══██╗██╔═══██╗██╔══██╗██╔══██╗██╔════╝██╔══██╗██╔════╝╚══██╔══╝██║████╗  ██║██╔════╝ 
██████╔╝██████╔╝██║   ██║███████║██║  ██║██║     ███████║███████╗   ██║   ██║██╔██╗ ██║██║  ███╗
██╔══██╗██╔══██╗██║   ██║██╔══██║██║  ██║██║     ██╔══██║╚════██║   ██║   ██║██║╚██╗██║██║   ██║
██████╔╝██║  ██║╚██████╔╝██║  ██║██████╔╝╚██████╗██║  ██║███████║   ██║   ██║██║ ╚████║╚██████╔╝
╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═════╝  ╚═════╝╚═╝  ╚═╝╚══════╝   ╚═╝   ╚═╝╚═╝  ╚═══╝ ╚═════╝ 
-}
-- Broadcast a new connection to all neighbours
broadcastNewConnection :: TVar NeighbourMap -> Int -> Int -> IO ()
broadcastNewConnection nmTVar dest dist = do
  let message = "u " ++ show dest ++ " " ++ show dist
  nm <- atomically $ readTVar nmTVar
  _ <- sequence $ map ((flip sendMessage) message) (HM.elems nm)
  putStr "" -- non threadkilling return

-- Broadcast your routingtable to a new neighbour
broadcastRoutingTableToNeighbour :: TVar RoutingTable -> MVar Handle -> IO ()
broadcastRoutingTableToNeighbour rtTVar nbHandle = do
  rt <- atomically $ readTVar rtTVar
  _ <- sequence $ map broadcastEntry (HM.toList rt)
  putStr "" -- non threadkilling return
  where
    broadcastEntry :: (Int, TVar RoutingTableEntry) -> IO ()
    broadcastEntry (dest, rteTVar) = do
      rte <- atomically $ readTVar rteTVar
      case rte of
        (Local _) -> putStr "" -- non threadkilling return
        (Node dist _) -> do
          let message = "u " ++ show dest ++ " " ++ show (dist)
          sendMessage nbHandle message

-- Broadcast a lost connection to all neighbours
broadcastLostConnection :: TVar NeighbourMap -> Int -> Int -> IO ()
broadcastLostConnection nmTVar nb port = do
  let message = "l " ++ show port
  nm <- atomically $ readTVar nmTVar
  _ <- sequence $ map ((flip sendMessage) message) (HM.elems (HM.delete nb nm))
  putStr "" -- non threadkilling return

{-
███╗   ███╗███████╗███████╗███████╗ █████╗  ██████╗ ███████╗    ██╗  ██╗ █████╗ ███╗   ██╗██████╗ ██╗     ██╗███╗   ██╗ ██████╗ 
████╗ ████║██╔════╝██╔════╝██╔════╝██╔══██╗██╔════╝ ██╔════╝    ██║  ██║██╔══██╗████╗  ██║██╔══██╗██║     ██║████╗  ██║██╔════╝ 
██╔████╔██║█████╗  ███████╗███████╗███████║██║  ███╗█████╗      ███████║███████║██╔██╗ ██║██║  ██║██║     ██║██╔██╗ ██║██║  ███╗
██║╚██╔╝██║██╔══╝  ╚════██║╚════██║██╔══██║██║   ██║██╔══╝      ██╔══██║██╔══██║██║╚██╗██║██║  ██║██║     ██║██║╚██╗██║██║   ██║
██║ ╚═╝ ██║███████╗███████║███████║██║  ██║╚██████╔╝███████╗    ██║  ██║██║  ██║██║ ╚████║██████╔╝███████╗██║██║ ╚████║╚██████╔╝
╚═╝     ╚═╝╚══════╝╚══════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝    ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═════╝ ╚══════╝╚═╝╚═╝  ╚═══╝ ╚═════╝ 
-}
{-
Meaning of message identifiers: 
m  -> neighbour send a message to or through me -> i need to send it forward or handle it if its for me
d  -> neighbour has disconnect -> i need to update my routingtable and neighbourmap and broadcast this to the other neighbours
u  -> neighbour has updated routingtable -> i need to update my routingtable and broadcast this to my other neighbours
l  -> neighbour has lost connection to a certain port -> i need to check if i can connect otherwise
-}
-- Handle a message from a neighbour
handleMessage :: WriteLock -> TVar RoutingTable -> TVar NeighbourMap -> Neighbour -> String -> IO ()
handleMessage writeLock rtTVar nmTVar nb msg | fst1Char == "m"  = messageM writeLock rtTVar nmTVar contents    
                                             | fst1Char == "d"  = messageD writeLock rtTVar nmTVar nb
                                             | fst1Char == "u"  = messageU writeLock rtTVar nmTVar nb contents
                                             | fst1Char == "l"  = messageL writeLock rtTVar nmTVar nb contents
                                             | otherwise        = error $ "handleMessage got an unknown identifier or empty message, namely: " ++ msg
  where
    fst1Char :: String
    fst1Char = take 1 msg
    contents :: String
    contents = drop 2 msg

data MessageMCheck = MMNothing | MMLocal | MMNodeNothing Int | MMNodeJust Int (MVar Handle)
-- Handle an incomming message and forward it if neccesary
messageM :: WriteLock -> TVar RoutingTable -> TVar NeighbourMap -> String -> IO ()
messageM writeLock rtTVar nmTVar msg = do
  messageMCheck <- atomically $ do
    rt <- readTVar rtTVar
    nbCheck <- case HM.lookup dest rt of -- Check if the destination is currently in routing table
      Nothing -> return Nothing
      Just rteTVar -> do
        rte <- readTVar rteTVar
        return $ Just rte
    case nbCheck of
      Nothing -> return MMNothing
      Just (Local _) -> return MMLocal
      Just (Node _ nb) -> do
        maybeHMVar <- do -- Check if the stored neighbour is still in my neighbour map
          nm <- readTVar nmTVar
          return $ HM.lookup nb nm 
        case maybeHMVar of
          Nothing -> return $ MMNodeNothing nb
          Just hMVar -> return $ MMNodeJust nb hMVar
  case messageMCheck of
    MMNothing -> putStrLnConc writeLock $ "Port " ++ show dest ++ " is not known"
    MMLocal -> putStrLnConc writeLock $ message
    MMNodeNothing nb -> putStrLnConc writeLock $ "//Error, no neighbour found while it should be there! " ++ show nb
    MMNodeJust nb hMVar -> do
      putStrLnConc writeLock $ "Message for " ++ show dest ++ " is relayed to " ++ show nb
      sendMessage hMVar $ "m " ++ msg
  return ()
  where
    dest :: Int -- destination
    dest = read (takeWhile (isDigit) msg)
    message :: String -- message
    message = drop 1 $ dropWhile (isDigit) msg

-- Handle a neighbour disconnecting with me
messageD :: WriteLock -> TVar RoutingTable -> TVar NeighbourMap -> Int -> IO ()
messageD writeLock rtTVar nmTVar nb = do
  lostPortList <- atomically $ do
    lostPortList' <- listOfLostConnections rtTVar nb -- Check which ports have become unreachable
    disconnectFromNeighbour rtTVar nmTVar lostPortList' nb -- Remove those ports from my routing table and neighbour map
    return lostPortList'
  putStrLnConc writeLock $ "Disconnected: " ++ show nb
  _ <- sequence $ map (broadcastLostConnection nmTVar nb) lostPortList -- Broadcast the lost ports to my other neighbours
  writeUnreachable lostPortList
  return ()
  where
    writeUnreachable :: [Int] -> IO ()
    writeUnreachable []                 = return ()
    writeUnreachable (x:xs) | x == nb   = writeUnreachable xs
                            | otherwise = do
                                putStrLnConc writeLock $ "Unreachable: " ++ show x
                                writeUnreachable xs

data MessageUCheck = MUNothing | MULocal | MUJustTrue | MUJustFalse | MUExit
-- Handle a neighbour's updated routing table message
messageU :: WriteLock -> TVar RoutingTable -> TVar NeighbourMap -> Int -> String -> IO ()
messageU writeLock rtTVar nmTVar nb msg = do
  threadDelay 10000
  updatedCheck <- atomically $ do
    rt <- readTVar rtTVar
    nm <- readTVar nmTVar
    nbCheck <- case HM.lookup dest rt of -- Check if the destination is currently in routing table
      Nothing -> return Nothing
      Just rteTVar -> do
        rte <- readTVar rteTVar
        return $ Just rte
    case nbCheck of
      Nothing -> do
        if HM.member nb nm then do -- Check if my neighbour is indeed still my neighbour
          addEntryToRoutingTable rtTVar dest dist nb
          validateRT rtTVar 
          return MUNothing
        else do
          return MUExit
      Just (Local _) -> return MULocal
      Just (Node d _) -> do
        case d > dist of -- Check if the distance my neighbour tells me is smaller than the one currently stored
          True -> do
            if HM.member nb nm then do
              addEntryToRoutingTable rtTVar dest dist nb
              validateRT rtTVar
              return MUJustTrue
            else do
              return MUExit
          False -> return MUJustFalse
  case updatedCheck of
    MUNothing -> do -- Unknown port, stored it in the routing table and broadcasted
      putStrLnConc writeLock $ "Distance to " ++ show dest ++ " is now " ++ show dist ++ " via " ++ show nb
      broadcastNewConnection nmTVar dest dist
      return ()
    MULocal -> return () -- My own port got send to me, ignore
    MUJustTrue -> do -- Known port, but shorter path so updated the routing table and broadcasted
      putStrLnConc writeLock $ "Distance to " ++ show dest ++ " is now " ++ show dist ++ " via " ++ show nb
      broadcastNewConnection nmTVar dest dist
      return ()
    MUJustFalse -> return ()
    MUExit -> return ()
  where
    dest :: Int --destination
    dest = read (takeWhile (isDigit) msg)
    dist :: Int --distance
    dist = 1 + (read $ drop 1 $ dropWhile (isDigit) msg)

data MessageLCheck = MLNothing | MLOwnPort | MLNodeTrue [Int] | MLNodeFalse String | MLExit
-- Handle a neighbour losing connection to a given port
messageL :: WriteLock -> TVar RoutingTable -> TVar NeighbourMap -> Int -> String -> IO ()
messageL writeLock rtTVar nmTVar nb msg = do
  threadDelay 10000
  messageLCheck <- atomically $ do
    rt <- readTVar rtTVar
    nm <- readTVar nmTVar
    nbCheck <- case HM.lookup port rt of  -- Check if the destination is currently in routing table
      Nothing -> return Nothing
      Just rteTVar -> do
        rte <- readTVar rteTVar
        return $ Just rte
    case nbCheck of
      Nothing -> return MLNothing
      Just (Local _) -> return MLOwnPort
      Just (Node curDist curNb) -> do
        case curNb == nb of
          True -> do
            {-
            I can reach the given port through the neighbour that sent me this message so i lost this connection as well,
            delete it and all the nodes i can reach through it
            -}
            lostPortList <- listOfLostConnections rtTVar port
            modifyTVar' rtTVar (HM.filterWithKey (\k _ -> not (k `elem` (port : lostPortList))))
            validateRT rtTVar
            return $ MLNodeTrue (port : lostPortList)
          False -> do
            {-
            I can reach the given port through a different neighbour,
            send the neighbour that lost the connection that i can still reach this port
            -}
            if HM.member port nm then do
              validateRT rtTVar
              let message = "u " ++ show port ++ " " ++ show curDist
              return $ MLNodeFalse message
            else do
              return MLExit
  case messageLCheck of
    MLNothing -> return ()
    MLOwnPort -> do
      putStrLnConc writeLock $ "//Error: messageL got a message that a port has lost connection to me"
      return ()
    MLNodeTrue portList -> do
      _ <- sequence $ map (broadcastLostConnection nmTVar nb) portList
      writeUnreachable portList
      return ()
    MLNodeFalse message -> do
      sendMessageToNeighbour nmTVar nb message
      return ()
    MLExit -> return ()
  return ()
  where
    port :: Int --the lost port
    port = read (takeWhile (isDigit) msg)
    writeUnreachable :: [Int] -> IO ()
    writeUnreachable []                 = return ()
    writeUnreachable (x:xs) | x == nb   = writeUnreachable xs
                            | otherwise = do
                                putStrLnConc writeLock $ "Unreachable: " ++ show x
                                writeUnreachable xs

{-
 ██████╗ ██████╗ ███╗   ███╗███╗   ███╗ █████╗ ███╗   ██╗██████╗     ██╗  ██╗ █████╗ ███╗   ██╗██████╗ ██╗     ██╗███╗   ██╗ ██████╗ 
██╔════╝██╔═══██╗████╗ ████║████╗ ████║██╔══██╗████╗  ██║██╔══██╗    ██║  ██║██╔══██╗████╗  ██║██╔══██╗██║     ██║████╗  ██║██╔════╝ 
██║     ██║   ██║██╔████╔██║██╔████╔██║███████║██╔██╗ ██║██║  ██║    ███████║███████║██╔██╗ ██║██║  ██║██║     ██║██╔██╗ ██║██║  ███╗
██║     ██║   ██║██║╚██╔╝██║██║╚██╔╝██║██╔══██║██║╚██╗██║██║  ██║    ██╔══██║██╔══██║██║╚██╗██║██║  ██║██║     ██║██║╚██╗██║██║   ██║
╚██████╗╚██████╔╝██║ ╚═╝ ██║██║ ╚═╝ ██║██║  ██║██║ ╚████║██████╔╝    ██║  ██║██║  ██║██║ ╚████║██████╔╝███████╗██║██║ ╚████║╚██████╔╝
 ╚═════╝ ╚═════╝ ╚═╝     ╚═╝╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═════╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═════╝ ╚══════╝╚═╝╚═╝  ╚═══╝ ╚═════╝ 
-}
{-
Command meaning:
R -> Print the routing table
N -> Print the neighbour map
B -> Send a message to a given port
C -> Connect to a given port
D -> Disconnect from a given neighbour
-}
-- Handle the given command appropriately
handleCommand :: WriteLock -> TVar RoutingTable -> TVar NeighbourMap -> Int -> String -> IO ()
handleCommand writeLock rtTVar nmTVar me input | fst1Char == "R" = ppRoutingTable writeLock rtTVar
                                               | fst1Char == "N" = printNeighbourTable writeLock nmTVar
                                               | fst1Char == "B" = commandSendMessage writeLock rtTVar nmTVar contents
                                               | fst1Char == "C" = commandConnect writeLock rtTVar nmTVar me contents
                                               | fst1Char == "D" = commandDisconnect writeLock rtTVar nmTVar contents
                                               | otherwise = putStrLnConc writeLock $ "//Not a valid command"
  where
    fst1Char :: String
    fst1Char = take 1 input
    contents :: String
    contents = drop 2 input

-- Pretty print the routing table
ppRoutingTable :: WriteLock -> TVar RoutingTable -> IO ()
ppRoutingTable writeLock rtTVar = do
  rt <- atomically $ readTVar rtTVar
  let rtList = HM.toList rt
  stringList <- sequence $ map getEntry rtList
  putStrLnConc writeLock $ unlines stringList
  where
    getEntry :: (Int, TVar RoutingTableEntry) -> IO String
    getEntry (k, v) = do
      rte <- atomically $ readTVar v
      return $ ppRTEntry k rte
    ppRTEntry :: Int -> RoutingTableEntry -> String
    ppRTEntry k (Local _)   = show k ++ " 0 local"
    ppRTEntry k (Node d nb) = show k ++ " " ++ show d ++ " " ++ show nb

data CommandSendMessageCheck = CSMNothing | CSMLocal | CSMNodeNothing Int |CSMNodeJust (MVar Handle)
-- Send a given message to the given port
commandSendMessage :: WriteLock -> TVar RoutingTable -> TVar NeighbourMap -> String -> IO ()
commandSendMessage writeLock rtTVar nmTVar input = do
  csmCheck <- atomically $ do
    rt <- readTVar rtTVar
    nb' <- case HM.lookup dest rt of -- Check if the destination is known
      Nothing -> return Nothing
      Just rteTVar -> do
        rte <- readTVar rteTVar
        return $ Just rte
    case nb' of 
      Nothing -> return CSMNothing -- Unkown destination
      Just (Local _) -> return CSMLocal -- Destination is own port, print the message
      Just (Node _ nb) -> do -- Known destination, send it to the closest connecting neighbour
        maybeHMVar <- do
          nm <- readTVar nmTVar
          return $ HM.lookup nb nm
        case maybeHMVar of
          Nothing -> return $ CSMNodeNothing nb
          Just hMVar -> return $ CSMNodeJust hMVar
  case csmCheck of
    CSMNothing -> putStrLnConc writeLock $ "Port " ++ show dest ++ " is not known"
    CSMLocal -> putStrLnConc writeLock $ message
    CSMNodeNothing nb -> putStrLnConc writeLock $ "//Error, no neighbour found while it should be there! " ++ show nb
    CSMNodeJust hMVar -> sendMessage hMVar ("m " ++ input)
  where
    dest :: Int -- destination
    dest = read (takeWhile (isDigit) input)
    message :: String -- message
    message = drop 1 $ dropWhile (isDigit) input

-- Connect to a given port
commandConnect :: WriteLock -> TVar RoutingTable -> TVar NeighbourMap -> Int -> String -> IO ()
commandConnect writeLock rtTVar nmTVar me input = do
  connectToNeighbour writeLock rtTVar nmTVar me nb
  where
    nb :: Int
    nb = read input

data CommandDisconnectCheck = CDNothing | CDLocal | CDNodeNothing | CDNodeJust (MVar Handle) [Int]
-- Disconnect from a given port
commandDisconnect :: WriteLock -> TVar RoutingTable -> TVar NeighbourMap -> String -> IO ()
commandDisconnect writeLock rtTVar nmTVar input = do
  cdCheck <- atomically $ do
    rt <- readTVar rtTVar
    nbCheck <- case HM.lookup nb rt of -- Check if the port is known
      Nothing -> return Nothing
      Just rteTVar -> do
        rte <- readTVar rteTVar
        return $ Just rte
    case nbCheck of
      Nothing -> return CDNothing -- Unkown port
      Just (Local _) -> return CDLocal -- Port is own port, cant disconnect from own port
      Just (Node _ n) -> do -- Port is known
        maybeHMVar <- do -- Check if the port is a neighbour
          nm <- readTVar nmTVar
          return $ HM.lookup n nm
        case maybeHMVar of
          Nothing -> return CDNodeNothing -- The given port is known, but not a neighbour
          Just hMVar -> do -- Port is a neighbour, disconnect from it
            lostPortList <- listOfLostConnections rtTVar nb -- Get all the ports i have now lost connection to
            disconnectFromNeighbour rtTVar nmTVar lostPortList nb
            return $ CDNodeJust hMVar lostPortList   
  case cdCheck of
    CDNothing -> putStrLnConc writeLock $ "Port " ++ show nb ++ " is not known"
    CDLocal -> putStrLnConc writeLock "//Can't disconnect from own port"
    CDNodeNothing -> putStrLnConc writeLock $ "//Port " ++ show nb ++ " is not a direct neighbour"
    CDNodeJust hMVar lostPortList -> do
      sendMessage hMVar "d" -- Communicate to this neighbour we have disconnected
      h <- takeMVar hMVar
      hClose h -- Close the handle
      putMVar hMVar h
      putStrLnConc writeLock $ "Disconnected: " ++ show nb 
      _ <- sequence $ map (broadcastLostConnection nmTVar nb) lostPortList -- Broadcast the lost connections to other neighbours
      writeUnreachable lostPortList
  where
    nb :: Int
    nb = read input
    writeUnreachable :: [Int] -> IO ()
    writeUnreachable []                 = return ()
    writeUnreachable (x:xs) | x == nb   = writeUnreachable xs
                            | otherwise = do
                                putStrLnConc writeLock $ "Unreachable: " ++ show x
                                writeUnreachable xs

{-
██╗  ██╗███████╗██╗     ██████╗ ███████╗██████╗     ███████╗██╗   ██╗███╗   ██╗ ██████╗████████╗██╗ ██████╗ ███╗   ██╗███████╗
██║  ██║██╔════╝██║     ██╔══██╗██╔════╝██╔══██╗    ██╔════╝██║   ██║████╗  ██║██╔════╝╚══██╔══╝██║██╔═══██╗████╗  ██║██╔════╝
███████║█████╗  ██║     ██████╔╝█████╗  ██████╔╝    █████╗  ██║   ██║██╔██╗ ██║██║        ██║   ██║██║   ██║██╔██╗ ██║███████╗
██╔══██║██╔══╝  ██║     ██╔═══╝ ██╔══╝  ██╔══██╗    ██╔══╝  ██║   ██║██║╚██╗██║██║        ██║   ██║██║   ██║██║╚██╗██║╚════██║
██║  ██║███████╗███████╗██║     ███████╗██║  ██║    ██║     ╚██████╔╝██║ ╚████║╚██████╗   ██║   ██║╚██████╔╝██║ ╚████║███████║
╚═╝  ╚═╝╚══════╝╚══════╝╚═╝     ╚══════╝╚═╝  ╚═╝    ╚═╝      ╚═════╝ ╚═╝  ╚═══╝ ╚═════╝   ╚═╝   ╚═╝ ╚═════╝ ╚═╝  ╚═══╝╚══════╝
-}
-- Concurrent version of putStrLn
putStrLnConc :: WriteLock -> String -> IO ()
putStrLnConc l s = withMVar l (\_ -> putStrLn s)

-- Send a message to the given neighbour
sendMessageToNeighbour :: TVar NeighbourMap -> Int -> String -> IO ()
sendMessageToNeighbour nmTVar nb message = do
  nm <- atomically $ readTVar nmTVar
  let nbHandle = nm HM.! nb
  sendMessage nbHandle message

-- Send a message to the given MVar handle
sendMessage :: MVar Handle -> String -> IO ()
sendMessage handleMVar message = do
  h <- takeMVar handleMVar
  hPutStrLn h $ message
  putMVar handleMVar h

-- Add an entry to the routingtable
addEntryToRoutingTable :: TVar RoutingTable -> Int -> Int -> Neighbour -> STM ()
addEntryToRoutingTable rtTVar dest dist nb = do
  rtEntry <- newTVar (Node dist nb)
  modifyTVar' rtTVar (HM.insert dest rtEntry) 

-- returns true if entry contains the given neigbor as a refference
portThroughNeighbour :: Int -> RoutingTableEntry -> Bool
portThroughNeighbour _ (Local _)   = False
portThroughNeighbour nb (Node _ n) = n == nb

-- Disconnects you form a neighbour
disconnectFromNeighbour :: TVar RoutingTable -> TVar NeighbourMap -> [Int] -> Int -> STM ()
disconnectFromNeighbour rtTVar nmTVar portList nb = do
  modifyTVar' nmTVar (HM.delete nb) -- remove the entry from the neighbor map
  modifyTVar' rtTVar (HM.filterWithKey (\k _ -> not (k `elem` portList)))

-- Returns a list of all connections lost
listOfLostConnections :: TVar RoutingTable -> Int -> STM ([Int])
listOfLostConnections rtTVar nb = do
  rt <- readTVar rtTVar
  let rtList = HM.toList rt
  let filteredrtListSTMMaybe = map rteFilter rtList
  filteredrtListMaybe <- sequence filteredrtListSTMMaybe
  return $ catMaybes filteredrtListMaybe
  where
    rteFilter :: (Int, TVar RoutingTableEntry) -> STM (Maybe (Int))
    rteFilter (k, vTvar) = do
      v <- readTVar vTvar
      case portThroughNeighbour nb v of
        True -> return $ Just k 
        False -> return Nothing

-- Removes all instances where the path is too long
validateRT :: TVar RoutingTable -> STM ()
validateRT rtTVar = do
  rt <- readTVar rtTVar
  let size = HM.size rt
  let rtList = HM.toList rt
  let filteredrtListSTMMaybe = map (rteFilter size) rtList
  filteredrtListMaybe <- sequence filteredrtListSTMMaybe
  writeTVar rtTVar $ HM.fromList $ catMaybes filteredrtListMaybe
  where
    rteFilter :: Int -> (Int, TVar RoutingTableEntry) -> STM (Maybe (Int, TVar RoutingTableEntry))
    rteFilter size rte@(_, vTvar) = do
      v <- readTVar vTvar
      case tooLongPath v size of
        True -> return Nothing
        False -> return $ Just rte
    tooLongPath :: RoutingTableEntry -> Int -> Bool
    tooLongPath (Local _) _ = False
    tooLongPath (Node s _) size = s > size + 1 || s > 20

{-
████████╗███████╗███████╗████████╗    ███████╗██╗   ██╗███╗   ██╗ ██████╗████████╗██╗ ██████╗ ███╗   ██╗███████╗
╚══██╔══╝██╔════╝██╔════╝╚══██╔══╝    ██╔════╝██║   ██║████╗  ██║██╔════╝╚══██╔══╝██║██╔═══██╗████╗  ██║██╔════╝
   ██║   █████╗  ███████╗   ██║       █████╗  ██║   ██║██╔██╗ ██║██║        ██║   ██║██║   ██║██╔██╗ ██║███████╗
   ██║   ██╔══╝  ╚════██║   ██║       ██╔══╝  ██║   ██║██║╚██╗██║██║        ██║   ██║██║   ██║██║╚██╗██║╚════██║
   ██║   ███████╗███████║   ██║       ██║     ╚██████╔╝██║ ╚████║╚██████╗   ██║   ██║╚██████╔╝██║ ╚████║███████║
   ╚═╝   ╚══════╝╚══════╝   ╚═╝       ╚═╝      ╚═════╝ ╚═╝  ╚═══╝ ╚═════╝   ╚═╝   ╚═╝ ╚═════╝ ╚═╝  ╚═══╝╚══════╝
-}
-- Print the neighbourtable in a readable format 
printNeighbourTable :: WriteLock -> TVar NeighbourMap -> IO ()
printNeighbourTable writeLock nmTVar = do
  nm <- atomically $ readTVar nmTVar
  stringList <- sequence $ map pnt (HM.toList nm)
  putStrLnConc writeLock $ unlines stringList
  where
    pnt :: (Int, MVar Handle) -> IO String
    pnt (i, hm) = do
      h <- takeMVar hm
      let s = "(" ++ show i ++ ", " ++ show h ++ ")"
      putMVar hm h
      return s