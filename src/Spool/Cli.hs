-- | The command line: the words a caller may give and the command they name.
-- Parsing is pure; nothing here touches a spool.
module Spool.Cli
  ( Command (..)
  , StoreCommand (..)
  , parseCommand
  , parseWorkShow
  , usageText
  ) where

import qualified Data.Text as T
import Spool.Types
  ( Retry (..)
  , StatusFormat (..)
  , WorkerName
  , workerNameFromArgument
  )

-- | What a command line names.  The two kinds are run differently, and the
-- types say which is which: a store command is one transition under the
-- spool's lock, and the worker takes that lock once for each transition it
-- makes, so that no executable runs while it is held.
data Command
  = Store StoreCommand
  | Work WorkerName FilePath (Maybe Int)
  | WorkShow FilePath
  deriving (Eq, Show)

-- | A command that is one transition under the spool's lock.
data StoreCommand
  = Init
  | Put (Maybe FilePath)
  | LeaseCommand WorkerName Int
  | Ack
  | Reclaim Integer
  | Status StatusFormat
  | Renew
  | Fail Retry
  | Failures
  | Results
  | Fetch
  | GrantCommand T.Text WorkerName FilePath (Maybe T.Text)
  | RevokeCommand T.Text
  deriving (Eq, Show)

parseCommand :: [String] -> Either String (FilePath, Command)
parseCommand ("--dir" : directory : rest)
  | null directory = Left "spool: --dir requires a non-empty directory"
  | otherwise = do
      command <- parseSubcommand rest
      pure (directory, command)
parseCommand _ = Left usageText

parseSubcommand :: [String] -> Either String Command
parseSubcommand ["init"] = store Init
parseSubcommand ["put"] = store (Put Nothing)
parseSubcommand ["put", "--attachments", directory]
  | not (null directory) = store (Put (Just directory))
  | otherwise = Left "spool: --attachments requires a non-empty directory"
parseSubcommand ["ack"] = store Ack
parseSubcommand ["renew"] = store Renew
parseSubcommand ["fail"] = store (Fail Retry)
parseSubcommand ["fail", "--no-retry"] = store (Fail NoRetry)
parseSubcommand ["failures"] = store Failures
parseSubcommand ["results"] = store Results
parseSubcommand ["fetch"] = store Fetch
parseSubcommand ["grant", "--peer", peer, "--worker", worker, "--key", key] =
  grantCommand peer worker key Nothing
parseSubcommand
    ["grant", "--peer", peer, "--worker", worker, "--key", key,
     "--expires-at", expires] =
  grantCommand peer worker key (Just (T.pack expires))
parseSubcommand ["revoke", "--grant", identifier] =
  store (RevokeCommand (T.pack identifier))
parseSubcommand ["status"] = store (Status StatusText)
parseSubcommand ["status", "--json"] = store (Status StatusJson)
parseSubcommand ["lease", "--worker", worker] = do
  name <- workerArgument worker
  store (LeaseCommand name 1)
parseSubcommand ["lease", "--worker", worker, "--count", count] =
  leaseCommand worker count
parseSubcommand ["lease", "--count", count, "--worker", worker] =
  leaseCommand worker count
parseSubcommand ["reclaim", "--older-than", age] =
  case reads age of
    [(seconds, "")] | seconds >= 0 -> store (Reclaim seconds)
    _ -> Left "spool: --older-than requires a non-negative integer"
parseSubcommand ("work" : "--config" : configPath : "--show" : []) =
  Right (WorkShow configPath)
parseSubcommand ("work" : "--show" : "--config" : configPath : []) =
  Right (WorkShow configPath)
parseSubcommand ("work" : rest) = do
  (worker, configPath, maxTasks) <- parseWorkArgs rest
  Right (Work worker configPath maxTasks)
parseSubcommand _ = Left usageText

store :: StoreCommand -> Either String Command
store = Right . Store

workerArgument :: String -> Either String WorkerName
workerArgument = either (Left . ("spool: " <>)) Right . workerNameFromArgument

grantCommand :: String -> String -> FilePath -> Maybe T.Text -> Either String Command
grantCommand peer worker key expiry = case workerNameFromArgument worker of
  Right name | not (null peer) -> store (GrantCommand (T.pack peer) name key expiry)
  _ -> Left "spool: grant requires non-empty peer and worker values"

leaseCommand :: String -> String -> Either String Command
leaseCommand worker count = do
  name <- workerArgument worker
  case reads count of
    [(number, "")] | number > 0 -> store (LeaseCommand name number)
    _ -> Left "spool: --count requires a positive integer"

parseWorkShow :: [String] -> Either String FilePath
parseWorkShow args = case filter (/= "--show") args of
  ["--config", configPath] -> Right configPath
  _ -> Left "spool: work --show requires --config FILE"

parseWorkArgs :: [String] -> Either String (WorkerName, FilePath, Maybe Int)
parseWorkArgs = go Nothing Nothing Nothing
  where
    go (Just w) (Just c) mt [] = Right (w, c, mt)
    go _ _ _ [] = Left "spool: work requires --worker and --config"
    go _ c mt ("--worker" : value : rest) = do
      name <- workerArgument value
      go (Just name) c mt rest
    go w _ mt ("--config" : value : rest) = go w (Just value) mt rest
    go w c _ ("--max-tasks" : value : rest) = case reads value of
      [(number, "")] | number > 0 -> go w c (Just number) rest
      _ -> Left "spool: --max-tasks requires a positive integer"
    go _ _ _ _ = Left usageText

usageText :: String
usageText = "usage: spool --dir DIR init|put [--attachments DIR]|lease --worker WORKER [--count N]|ack|renew|fail [--no-retry]|failures|results|fetch|reclaim --older-than SECONDS|status [--json]|work --worker WORKER --config FILE [--max-tasks N]|grant --peer PEER --worker WORKER --key FILE [--expires-at RFC3339]|revoke --grant GRANT_ID\n       spool remote --grant GRANT_ID\n       spool work --config FILE --show"
