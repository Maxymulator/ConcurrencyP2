
module Main where

import Control.Monad
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Data.IORef
import System.Environment
import System.IO
import Network.Socket

type RoutingTable = TVar [(Int, Int, Int)]

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

  
  
  connectToNeighbours me neighbours
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

connectToNeighbours :: RoutingTable -> Int -> [Int] -> IO ()
connectToNeighbours _ _ [] = putStrLn "//No more neighbours"
connectToNeighbours nbu m (x:xs) = do
  putStrLn $ "//Establishing connection with port: " ++ show x
  xSocket <- connectSocket x
  xHandle <- socketToHandle xSocket ReadWriteMode
  --TODO: add x to Nbu, Nbu possibly a [(Int, Int, Int)] with [(Destination, Distance, Closest neighbour)]
  atomically $ do
    let newEntry = [(x, 1, x)]
    modifyTVar' nbu (newEntry :)

  --TODO: fork thread to handle this connection
  _ <- forkIO $ handleNeighbour' xHandle m x
  connectToNeighbours m xs

handleNeighbour :: Handle -> Int -> Int -> IO ()
handleNeighbour xHandle m x = do
  hPutStrLn xHandle $ "//Hi process " ++ show x ++ ", i'm process " ++ show m ++ ". Are we connected?"
  putStrLn $ "//Sent ACK-request to port: " ++ show x
  message <- hGetLine xHandle
  putStrLn $ "Connected " ++ show x
  handleNeighbour' xHandle
  where
    handleNeighbour' :: Handle -> IO ()
    handleNeighbour' xHandle = do
      message <- hGetLine xHandle
      _ <- handleMessage message
      handleNeighbour' xHandle
    
handleMessage :: String -> IO ()
handleMessage s = return ()

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
