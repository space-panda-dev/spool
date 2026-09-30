{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The command line: the words a caller may give and the command they name.
-- Parsing is pure; nothing here touches a spool.
module Spool.Cli
  ( Command (..)
  , parseCommand
  , parseWorkShow
  , usageText
  ) where

import qualified Data.Text as T

data Command
  = Init
  | Put (Maybe FilePath)
  | LeaseCommand T.Text Int
  | Ack
  | Reclaim Integer
  | Status Bool
  | Renew
  | Fail Bool
  | Failures
  | Results
  | Fetch
  | Work T.Text FilePath (Maybe Int)
  | WorkShow FilePath
  | GrantCommand T.Text T.Text FilePath (Maybe T.Text)
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
parseSubcommand ["init"] = Right Init
parseSubcommand ["put"] = Right (Put Nothing)
parseSubcommand ["put", "--attachments", directory]
  | not (null directory) = Right (Put (Just directory))
  | otherwise = Left "spool: --attachments requires a non-empty directory"
parseSubcommand ["ack"] = Right Ack
parseSubcommand ["renew"] = Right Renew
parseSubcommand ["fail"] = Right (Fail True)
parseSubcommand ["fail", "--no-retry"] = Right (Fail False)
parseSubcommand ["failures"] = Right Failures
parseSubcommand ["results"] = Right Results
parseSubcommand ["fetch"] = Right Fetch
parseSubcommand ["grant", "--peer", peer, "--worker", worker, "--key", key]
  | validWorker worker && not (null peer) =
      Right (GrantCommand (T.pack peer) (T.pack worker) key Nothing)
  | otherwise = Left "spool: grant requires non-empty peer and worker values"
parseSubcommand
    ["grant", "--peer", peer, "--worker", worker, "--key", key,
     "--expires-at", expires]
  | validWorker worker && not (null peer) =
      Right (GrantCommand (T.pack peer) (T.pack worker) key (Just (T.pack expires)))
  | otherwise = Left "spool: grant requires non-empty peer and worker values"
parseSubcommand ["revoke", "--grant", identifier] =
  Right (RevokeCommand (T.pack identifier))
parseSubcommand ["status"] = Right (Status False)
parseSubcommand ["status", "--json"] = Right (Status True)
parseSubcommand ["lease", "--worker", worker]
  | validWorker worker = Right (LeaseCommand (T.pack worker) 1)
  | otherwise = Left "spool: worker must be a non-empty token"
parseSubcommand ["lease", "--worker", worker, "--count", count] =
  leaseCommand worker count
parseSubcommand ["lease", "--count", count, "--worker", worker] =
  leaseCommand worker count
parseSubcommand ["reclaim", "--older-than", age] =
  case reads age of
    [(seconds, "")] | seconds >= 0 -> Right (Reclaim seconds)
    _ -> Left "spool: --older-than requires a non-negative integer"
parseSubcommand ("work" : "--config" : configPath : "--show" : []) =
  Right (WorkShow configPath)
parseSubcommand ("work" : "--show" : "--config" : configPath : []) =
  Right (WorkShow configPath)
parseSubcommand ("work" : rest) = do
  (worker, configPath, maxTasks) <- parseWorkArgs rest
  Right (Work worker configPath maxTasks)
parseSubcommand _ = Left usageText

leaseCommand :: String -> String -> Either String Command
leaseCommand worker count
  | not (validWorker worker) = Left "spool: worker must be a non-empty token"
  | otherwise = case reads count of
      [(number, "")] | number > 0 -> Right (LeaseCommand (T.pack worker) number)
      _ -> Left "spool: --count requires a positive integer"

parseWorkShow :: [String] -> Either String FilePath
parseWorkShow args = case filter (/= "--show") args of
  ["--config", configPath] -> Right configPath
  _ -> Left "spool: work --show requires --config FILE"

parseWorkArgs :: [String] -> Either String (T.Text, FilePath, Maybe Int)
parseWorkArgs = go Nothing Nothing Nothing
  where
    go (Just w) (Just c) mt [] = Right (T.pack w, c, mt)
    go _ _ _ [] = Left "spool: work requires --worker and --config"
    go _ c mt ("--worker" : value : rest)
      | validWorker value = go (Just value) c mt rest
      | otherwise = Left "spool: worker must be a non-empty token"
    go w _ mt ("--config" : value : rest) = go w (Just value) mt rest
    go w c _ ("--max-tasks" : value : rest) = case reads value of
      [(number, "")] | number > 0 -> go w c (Just number) rest
      _ -> Left "spool: --max-tasks requires a positive integer"
    go _ _ _ _ = Left usageText

validWorker :: String -> Bool
validWorker value = not (null value) && all (not . (`elem` ['\n', '\r', '\t', ' '])) value

usageText :: String
usageText = "usage: spool --dir DIR init|put [--attachments DIR]|lease --worker WORKER [--count N]|ack|renew|fail [--no-retry]|failures|results|fetch|reclaim --older-than SECONDS|status [--json]|work --worker WORKER --config FILE [--max-tasks N]|grant --peer PEER --worker WORKER --key FILE [--expires-at RFC3339]|revoke --grant GRANT_ID\n       spool remote --grant GRANT_ID\n       spool work --config FILE --show"
