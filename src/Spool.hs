{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | A small, independent JSONL task spool: the entry point, which turns the
-- command line into one command and runs it.
module Spool
  ( main
  ) where

import Control.Exception (IOException, catch, displayException)
import Control.Monad (when)
import qualified Data.Text as T
import System.Environment (getArgs)
import System.Exit (exitSuccess)
import Spool.Cli (Command (..), parseCommand, parseWorkShow)
import Spool.Failure (failWith)
import Spool.Files (Paths (..), withLock, makePaths, initialise)
import Spool.Grants (grantAccess, revokeAccess, runRemote)
import Spool.Store
  ( withStore
  , recoverAttachmentState
  , putTasks
  , leaseTasks
  , ackTasks
  , renewTasks
  , failTasks
  , failuresCommand
  , resultsCommand
  , fetchAttachment
  , reclaimTasks
  , statusTasks
  )
import Spool.Worker.Config (runWorkShow)
import Spool.Worker.Run (runWork)

main :: IO ()
main = mainCommand `catch` handleFilesystemFailure

handleFilesystemFailure :: IOException -> IO a
handleFilesystemFailure exception =
  failWith 75 ("spool: filesystem failure: " <> displayException exception)

mainCommand :: IO ()
mainCommand = do
  args <- getArgs
  when (args == ["--version"]) $ putStrLn "spool 0.0.1" >> exitSuccess
  case args of
    ["remote", "--grant", identifier] -> runRemote (T.pack identifier)
    ("work" : rest) | "--show" `elem` rest && "--dir" `notElem` args ->
      case parseWorkShow rest of
        Left message -> failWith 2 message
        Right configPath -> runWorkShow configPath
    _ -> case parseCommand args of
      Left message -> failWith 2 message
      Right (directory, Work worker configPath maxTasks) -> do
        let paths = makePaths directory
        initialise paths
        withLock paths (recoverAttachmentState paths)
        runWork paths worker configPath maxTasks
      Right (directory, WorkShow configPath) -> do
        _ <- pure directory
        runWorkShow configPath
      Right (directory, command) -> withStore directory (runCommand command)

runCommand :: Command -> Paths -> IO ()
runCommand command paths = case command of
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
  Status json -> statusTasks paths json
  Work {} -> error "unreachable: Work is dispatched before runCommand"
  WorkShow {} -> error "unreachable: WorkShow is dispatched before runCommand"
  GrantCommand peer worker key expiry ->
    grantAccess paths peer worker key expiry
  RevokeCommand identifier -> revokeAccess paths identifier
