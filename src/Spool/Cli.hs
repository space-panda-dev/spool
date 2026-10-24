-- | The command line: the words a caller may give and the command they name.
-- Parsing is pure; nothing here touches a spool.
module Spool.Cli
  ( Command (..)
  , StoreCommand (..)
  , Transfer (..)
  , GrantOptions (..)
  , parseCommand
  , parseMetrics
  , parseWorkShow
  , parseWorkVia
  , usageText
  ) where

import Data.Int (Int64)
import qualified Data.Text as T
import Data.Maybe (fromMaybe)
import Spool.Worker.Config (maxDelaySeconds)
import Spool.Worker.Follow (defaultIdleSeconds)
import Spool.Types
  ( Retry (..)
  , StatusFormat (..)
  , WorkerName
  , mkWorkerName
  )

-- | What a command line names.  The two kinds are run differently, and the
-- types say which is which: a store command is one transition under the
-- spool's lock, and the worker takes that lock once for each transition it
-- makes, so that no executable runs while it is held.
data Command
  = Store StoreCommand
  | Moving Transfer
    -- ^ A command that moves an attachment's bytes. It takes the lock only
    -- for the transitions on either side of them, never while they move.
  | Work WorkerName FilePath (Maybe Int) (Maybe Int)
    -- ^ The last field is the longest a worker that follows its spool
    -- waits between two leases; a worker that does not follow stops once
    -- nothing is pending.
  | WorkVia [String] FilePath (Maybe Int) (Maybe Int)
    -- ^ A worker on another machine: the transport command's words, to
    -- which one remote word is appended for each request.
  | WorkShow FilePath
  deriving (Eq, Show)

-- | A command that is one transition under the spool's lock.
data StoreCommand
  = Init
  | Put (Maybe FilePath)
  | LeaseCommand WorkerName Int
  | Ack
  | Reclaim Integer
  | Collect
  | Withdraw
  | Gc Integer
  | Status StatusFormat
  | Renew
  | Fail Retry
  | Failures
  | Results
  | GrantCommand T.Text WorkerName FilePath GrantOptions
  | RevokeCommand T.Text
  deriving (Eq, Show)

-- | The commands that move an attachment's bytes (ADR 0020).
data Transfer
  = Send  -- ^ a worker sends one of a result under its lease
  | Take  -- ^ a reader takes one of a done task
  | Fetch  -- ^ a worker fetches one of its task under its lease
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
parseSubcommand ["fetch"] = Right (Moving Fetch)
parseSubcommand ["send"] = Right (Moving Send)
parseSubcommand ["take"] = Right (Moving Take)
parseSubcommand ("grant" : "--peer" : peer : "--worker" : worker : "--key" : key : options) =
  grantCommand peer worker key options
parseSubcommand ["revoke", "--grant", identifier] =
  store (RevokeCommand (T.pack identifier))
parseSubcommand ["status"] = store (Status StatusText)
parseSubcommand ["status", "--json"] = store (Status StatusJson)
parseSubcommand ["status", "--json", "--tasks"] = store (Status StatusTasks)
parseSubcommand ["status", "--tasks", "--json"] = store (Status StatusTasks)
parseSubcommand ["lease", "--worker", worker] = do
  name <- workerArgument worker
  store (LeaseCommand name 1)
parseSubcommand ["lease", "--worker", worker, "--count", count] =
  leaseCommand worker count
parseSubcommand ["lease", "--count", count, "--worker", worker] =
  leaseCommand worker count
parseSubcommand ["reclaim", "--older-than", age] = Store . Reclaim <$> olderThan age
parseSubcommand ["collect"] = store Collect
parseSubcommand ["withdraw"] = store Withdraw
parseSubcommand ["gc", "--older-than", age] = Store . Gc <$> olderThan age
parseSubcommand ("work" : "--config" : configPath : "--show" : []) =
  Right (WorkShow configPath)
parseSubcommand ("work" : "--show" : "--config" : configPath : []) =
  Right (WorkShow configPath)
parseSubcommand ("work" : rest) = do
  (follow, others) <- followArgs rest
  (worker, configPath, maxTasks) <- parseWorkArgs others
  Right (Work worker configPath maxTasks follow)
parseSubcommand _ = Left usageText

-- | The form that needs no spool directory: a worker reaching its spool
-- through a transport command.  The command is one word, split on single
-- spaces into a program and its arguments.
parseWorkVia :: [String] -> Either String Command
parseWorkVia args = do
  (follow, others) <- followArgs args
  go follow Nothing Nothing Nothing others
  where
    go f (Just via) (Just c) mt [] = Right (WorkVia via c mt f)
    go _ _ _ _ [] = Left "spool: work --via requires --via COMMAND and --config FILE"
    go f _ c mt ("--via" : value : rest) = case words value of
      [] -> Left "spool: --via requires a non-empty command"
      transport -> go f (Just transport) c mt rest
    go f v _ mt ("--config" : value : rest) = go f v (Just value) mt rest
    go f v c _ ("--max-tasks" : value : rest) = case reads value of
      [(number, "")] | number > 0 -> go f v c (Just number) rest
      _ -> Left "spool: --max-tasks requires a positive integer"
    go _ _ _ _ _ = Left usageText

-- | The form that reads a host's spools as metrics (ADR 0028): a window in
-- whole seconds, given once, and one or more spool directories, in any
-- order.
parseMetrics :: [String] -> Either String (Integer, [FilePath])
parseMetrics = go Nothing []
  where
    go (Just window) directories@(_ : _) [] = Right (window, reverse directories)
    go _ _ [] = Left "spool: metrics requires --window SECONDS and at least one --dir DIR"
    go Nothing directories ("--window" : value : rest) = case reads value of
      [(seconds, "")] | seconds > 0 -> go (Just seconds) directories rest
      _ -> Left "spool: --window requires a positive integer"
    go window directories ("--dir" : directory : rest)
      | null directory = Left "spool: --dir requires a non-empty directory"
      | otherwise = go window (directory : directories) rest
    go _ _ _ = Left usageText

-- | Take the words that make a worker follow its spool out of a work
-- command line, and leave the rest: the longest wait between two leases, or
-- nothing for a worker that stops once nothing is pending. A word that is
-- the value of another option is that option's, whatever it says.
followArgs :: [String] -> Either String (Maybe Int, [String])
followArgs = go False Nothing []
  where
    go follow idle kept words' = case words' of
      [] -> case (follow, idle) of
        (True, _) -> Right (Just (fromMaybe defaultIdleSeconds idle), reverse kept)
        (False, Nothing) -> Right (Nothing, reverse kept)
        (False, Just _) -> Left "spool: --idle-seconds requires --follow"
      "--follow" : rest | not follow -> go True idle kept rest
      "--idle-seconds" : value : rest | idle == Nothing -> do
        seconds <- idleSeconds value
        go follow (Just seconds) kept rest
      option : value : rest | option `elem` valued ->
        go follow idle (value : option : kept) rest
      word : rest -> go follow idle (word : kept) rest
    valued = ["--worker", "--config", "--via", "--max-tasks"]
    -- Read as an Integer and bounded before it is an Int, so a huge number
    -- is refused rather than wrapped.
    idleSeconds value = case reads value :: [(Integer, String)] of
      [(number, "")] | number > 0 && number <= toInteger maxDelaySeconds ->
        Right (fromInteger number)
      _ -> Left ("spool: --idle-seconds requires a positive integer no greater than "
        <> show maxDelaySeconds)

store :: StoreCommand -> Either String Command
store = Right . Store

-- | A threshold in whole seconds, as reclaim and gc are given it.
olderThan :: String -> Either String Integer
olderThan age = case reads age of
  [(seconds, "")] | seconds >= 0 -> Right seconds
  _ -> Left "spool: --older-than requires a non-negative integer"

workerArgument :: String -> Either String WorkerName
workerArgument = either (Left . ("spool: " <>)) Right . mkWorkerName . T.pack

grantCommand :: String -> String -> FilePath -> [String] -> Either String Command
grantCommand peer worker key options = case mkWorkerName (T.pack worker) of
  Right name | not (null peer) -> do
    chosen <- grantOptions (GrantOptions False Nothing Nothing 0) options
    store (GrantCommand (T.pack peer) name key chosen)
  _ -> Left "spool: grant requires non-empty peer and worker values"

-- | What a grant may be given beyond its peer, worker, and key.
data GrantOptions = GrantOptions
  { grantOptionPut :: Bool
  , grantOptionExpiry :: Maybe T.Text
  , grantOptionExecutable :: Maybe FilePath
    -- ^ The program the forced command runs, in place of this binary's own
    -- canonical path. A stable path, such as a symlink kept pointing at the
    -- installed binary, outlives the binary it points at.
  , grantOptionMaxResultBytes :: Int64
    -- ^ How many bytes of result attachments the spool holds from the
    -- grant at once. 0, when it is not given, is none (ADR 0020).
  } deriving (Eq, Show)

-- | The optional words of grant, in any order, each at most once.
grantOptions :: GrantOptions -> [String] -> Either String GrantOptions
grantOptions options words' = case words' of
  [] -> Right options
  "--put" : rest | not (grantOptionPut options) ->
    grantOptions options { grantOptionPut = True } rest
  "--expires-at" : value : rest | grantOptionExpiry options == Nothing ->
    grantOptions options { grantOptionExpiry = Just (T.pack value) } rest
  "--executable" : value : rest | grantOptionExecutable options == Nothing && not (null value) ->
    grantOptions options { grantOptionExecutable = Just value } rest
  "--max-result-bytes" : value : rest | grantOptionMaxResultBytes options == 0 ->
    case reads value :: [(Integer, String)] of
      [(number, "")] | number > 0 && number <= toInteger (maxBound :: Int64) ->
        grantOptions options { grantOptionMaxResultBytes = fromInteger number } rest
      _ -> Left ("spool: --max-result-bytes requires a positive integer no greater than "
        <> show (maxBound :: Int64))
  _ -> Left usageText

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
usageText = "usage: spool --dir DIR init|put [--attachments DIR]|lease --worker WORKER [--count N]|ack|renew|fail [--no-retry]|failures|results|fetch|send|take|reclaim --older-than SECONDS|collect|withdraw|gc --older-than SECONDS|status [--json [--tasks]]|work --worker WORKER --config FILE [--max-tasks N] [FOLLOW]|grant --peer PEER --worker WORKER --key FILE [--put] [--expires-at RFC3339] [--executable PATH] [--max-result-bytes N]|revoke --grant GRANT_ID\n       spool remote --grant GRANT_ID\n       spool work --via COMMAND --config FILE [--max-tasks N] [FOLLOW]\n       spool work --config FILE --show\n       spool metrics --window SECONDS --dir DIR [--dir DIR]...\nFOLLOW: --follow [--idle-seconds N]"
