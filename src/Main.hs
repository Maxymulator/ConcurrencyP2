
module Main where

import Control.Monad
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Data.IORef
import System.Environment
import System.IO
import Network.Socket

data RoutingTable = RT [RoutingTableEntry]
data RoutingTableEntry = RTE (Int,Int,Int)

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
  -- Let a seperate thread listen for incomming connections
  _ <- forkIO $ listenForConnections serverSocket

  -- Create the local routing table
  nbu <- newTVarIO $ RT []
  writeLock <- newMVar ()

  connectToNeighbours writeLock nbu me neighbours
  putStrLn " "
  filledNbu <- readTVarIO nbu
  printRoutingtable writeLock me filledNbu
  {- As an example, connect to the first neighbour. This just
  -- serves as an example on using the network functions in Haskell
  case neighbours of
    [] -> putStrLn "I have no neighbours :("
    neighbour : _ -> do
      putStrLn $ "Connecting to neighbour " ++ show neighbour ++ "..."
      client <- connectSocket neighbour
      chandle <- socketToHandle client ReadWriteMode
      -- Send a message over the socket
      -- You can send and receive messages with a similar API as reading and writing to the console.
      -- Use `hPutStrLn chandle` instead of `putStrLn`,
      -- and `hGetLine  chandle` instead of `getLine`.
      -- You can close a connection with `hClose chandle`.
      hPutStrLn chandle $ "Hi process " ++ show neighbour ++ "! I'm process " ++ show me ++ " and you are my first neighbour."
      putStrLn "I sent a message to the neighbour"
      message <- hGetLine chandle
      putStrLn $ "Neighbour send a message back: " ++ show message
      hClose chandle
  -}
  threadDelay 1000000000

{-
Mogelijk printen in een eigen thread, welke een string van een MVar leest en deze daarna concurrently print naar de console.
Mogelijk printen met een MVar als lock (huidig)
Mogelijk printen in STM, zou dit concurrent zijn? <- vraag aan TA
-}

connectToNeighbours :: MVar a -> TVar RoutingTable -> Int -> [Int] -> IO ()
connectToNeighbours writeLock _ _ [] = withMVar writeLock (\_ -> putStrLn "//No more neighbours")
connectToNeighbours writeLock nbu m (x:xs) = do
  withMVar writeLock (\_ -> putStrLn $ "//Establishing connection with port: " ++ show x)
  xSocket <- connectSocket x
  xHandle <- socketToHandle xSocket ReadWriteMode
  --TODO: add x to Nbu, Nbu possibly a [(Int, Int, Int)] with [(Destination, Distance, Closest neighbour)]
  atomically $ do
    let newEntry = RTE (x, 1, x)
    modifyTVar' nbu (addEntryToRoutingTable newEntry)

  --TODO: fork thread to handle this connection
  _ <- forkIO $ handleNeighbour writeLock xHandle m x
  connectToNeighbours writeLock nbu m xs

addEntryToRoutingTable :: RoutingTableEntry -> RoutingTable -> RoutingTable
addEntryToRoutingTable x (RT xs) = RT (x:xs)

handleNeighbour :: MVar a -> Handle -> Int -> Int -> IO ()
handleNeighbour writeLock xHandle m x = do
  hPutStrLn xHandle $ "//Hi process " ++ show x ++ ", i'm process " ++ show m ++ ". Are we connected?"
  withMVar writeLock (\_ -> putStrLn $ "//Sent ACK-request to port: " ++ show x)
  message <- hGetLine xHandle
  withMVar writeLock (\_ -> putStrLn $ "Connected " ++ show x)
  handleNeighbour' xHandle
  where
    handleNeighbour' :: Handle -> IO ()
    handleNeighbour' xHandle = do
      message <- hGetLine xHandle
      _ <- handleMessage message
      handleNeighbour' xHandle
    
{-
m message
c connect
d disconnect
-}
handleMessage :: String -> IO ()
handleMessage (x:_:xs) | x == 'm' = return ()--handle xs -> incomming message
                       | x == 'c' = return ()--handle xs -> new connection
                       | x == 'd' = return ()--handle xs -> disconnection
                       | otherwise = error "handleMessage got an unknown identifier"

printRoutingtable :: MVar a -> Int -> RoutingTable -> IO ()
printRoutingtable writeLock m nbu = do
  withMVar writeLock (\_ -> do
    putStrLn $ (show m) ++ " 0 local"
    printRoutingtable' nbu)
  where
     printRoutingtable' :: RoutingTable -> IO ()
     printRoutingtable' (RT []) = return ()
     printRoutingtable' (RT (x:xs)) = do
      putStrLn $ ppRTEntry x
      printRoutingtable' (RT xs)

ppRTEntry :: RoutingTableEntry -> String
ppRTEntry (RTE (dest, dist, neighb)) = (show dest) ++ " " ++ (show dist) ++ " " ++ (show neighb)

{- Template -}
readCommandLineArguments :: IO (Int, [Int])
readCommandLineArguments = do
  args <- getArgs
  case args of
    [] -> error "Not enough arguments. You should pass the port number of the current process and a list of neighbours"
    (me:neighbours) -> return (read me, map read neighbours)

portToAddress :: Int -> SockAddr
portToAddress portNumber = SockAddrInet (fromIntegral portNumber) (tupleToHostAddress (127, 0, 0, 1)) -- localhost

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

listenForConnections :: Socket -> IO ()
listenForConnections serverSocket = do
  (connection, _) <- accept serverSocket
  _ <- forkIO $ handleConnection connection
  listenForConnections serverSocket

handleConnection :: Socket -> IO ()
handleConnection connection = do
  putStrLn "Got new incomming connection"
  chandle <- socketToHandle connection ReadWriteMode
  hPutStrLn chandle "ACK"
  message <- hGetLine chandle
  putStrLn $ "Incomming connection send a message: " ++ message
  hClose chandle
