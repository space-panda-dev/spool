-- | A small, independent JSONL task spool: the entry point, which turns the
-- command line into one command, runs it, and is the only place a failure
-- becomes a message and an exit status.
module Spool
  ( main
  ) where

import Control.Exception (Handler (..), IOException, catches, displayException,
                          throwIO)
import qualified Data.Text as T
import Data.Version (showVersion)
import Paths_spool (version)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import Spool.Cli
  ( Command (..)
  , StoreCommand (..)
  , Transfer (..)
  , parseCommand
  , parseWorkShow
  , parseWorkVia
  )
import Spool.Error (SpoolError (..), exitStatus, report, retryable)
import Spool.Files (Paths, initialise, openSpool, withLock)
import Spool.Grants (grantAccess, revokeAccess, runRemote)
import Spool.Store
  ( ackTasks
  , collectTasks
  , withdrawTasks
  , failTasks
  , failuresCommand
  , fetchAttachment
  , gcTasks
  , leaseTasks
  , putTasks
  , reclaimTasks
  , recover
  , renewTasks
  , resultsCommand
  , Sender (..)
  , sendCommand
  , statusTasks
  , takeCommand
  , withStore
  )
import Spool.Worker.Config (runWorkShow)
import Spool.Worker.Connection (localConnection, remoteConnection)
import Spool.Worker.Run (runWork)

main :: IO ()
main = do
  args <- getArgs
  run args `catches`
    [ Handler exitWithFailure
    , Handler (exitWithFailure . filesystemFailure)
    ]

exitWithFailure :: SpoolError -> IO a
exitWithFailure failure = do
  report failure
  exitWith (ExitFailure (exitStatus failure))

filesystemFailure :: IOException -> SpoolError
filesystemFailure exception =
  retryable ("filesystem failure: " <> displayException exception)

run :: [String] -> IO ()
run args = case args of
  ["--version"] -> putStrLn ("spool " <> showVersion version)
  ["remote", "--grant", identifier] -> runRemote (T.pack identifier)
  ("work" : rest) | "--show" `elem` rest && "--dir" `notElem` args ->
    either (throwIO . Usage) runWorkShow (parseWorkShow rest)
  ("work" : rest) | "--via" `elem` rest && "--dir" `notElem` args -> do
    command <- either (throwIO . Usage) pure (parseWorkVia rest)
    case command of
      WorkVia (program : arguments) configPath maxTasks follow ->
        runWork (remoteConnection program arguments) configPath maxTasks follow
      _ -> throwIO (Usage "spool: --via requires a non-empty command")
  _ -> do
    (directory, command) <- either (throwIO . Usage) pure (parseCommand args)
    case command of
      Work worker configPath maxTasks follow -> do
        paths <- openSpool directory
        initialise paths
        withLock paths (recover paths)
        runWork (localConnection paths worker) configPath maxTasks follow
      WorkVia {} -> throwIO (Usage "spool: work --via takes no --dir")
      WorkShow configPath -> runWorkShow configPath
      Store transition -> withStore directory (runStoreCommand transition)
      Moving transfer -> do
        paths <- openSpool directory
        initialise paths
        case transfer of
          Send -> sendCommand paths (recover paths) HostWorker
          Take -> takeCommand paths (recover paths)
          Fetch -> fetchAttachment paths (recover paths) Nothing

runStoreCommand :: StoreCommand -> Paths -> IO ()
runStoreCommand command paths = case command of
  Init -> pure ()
  Put source -> putTasks paths source
  LeaseCommand worker count -> leaseTasks paths worker count
  Ack -> ackTasks paths
  Renew -> renewTasks paths
  Fail retry -> failTasks retry paths
  Failures -> failuresCommand paths
  Results -> resultsCommand paths
  Reclaim age -> reclaimTasks paths age
  Collect -> collectTasks paths
  Withdraw -> withdrawTasks paths
  Gc age -> gcTasks paths age
  Status format -> statusTasks paths format
  GrantCommand peer worker key options ->
    grantAccess paths peer worker key options
  RevokeCommand identifier -> revokeAccess paths identifier
