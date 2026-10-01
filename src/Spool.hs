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
  , parseCommand
  , parseWorkShow
  , parseWorkVia
  )
import Spool.Error (SpoolError (..), exitStatus, report, retryable)
import Spool.Files (Paths, initialise, openSpool, withLock)
import Spool.Grants (grantAccess, revokeAccess, runRemote)
import Spool.Store
  ( ackTasks
  , failTasks
  , failuresCommand
  , fetchAttachment
  , leaseTasks
  , putTasks
  , reclaimTasks
  , recover
  , renewTasks
  , resultsCommand
  , statusTasks
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
      WorkVia (program : arguments) configPath maxTasks ->
        runWork (remoteConnection program arguments) configPath maxTasks
      _ -> throwIO (Usage "spool: --via requires a non-empty command")
  _ -> do
    (directory, command) <- either (throwIO . Usage) pure (parseCommand args)
    case command of
      Work worker configPath maxTasks -> do
        paths <- openSpool directory
        initialise paths
        withLock paths (recover paths)
        runWork (localConnection paths worker) configPath maxTasks
      WorkVia {} -> throwIO (Usage "spool: work --via takes no --dir")
      WorkShow configPath -> runWorkShow configPath
      Store transition -> withStore directory (runStoreCommand transition)

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
  Fetch -> fetchAttachment paths
  Reclaim age -> reclaimTasks paths age
  Status format -> statusTasks paths format
  GrantCommand peer worker key put expiry ->
    grantAccess paths peer worker key put expiry
  RevokeCommand identifier -> revokeAccess paths identifier
