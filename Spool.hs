{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wall -Werror #-}

-- | A small, independent JSONL task spool.
--
-- The spool owns task identity, capability-tagged jobs, and the
-- pending -> leased -> done|failed lifecycle. Payloads are opaque JSON.
-- A lease is a filename transition; the lease id remains in the filename
-- so an old worker cannot acknowledge a newer lease after reclaim. Two
-- non-.json sidecars ride next to a leased task file: "<lease>.worker"
-- (the leasing worker, written once) and "<lease>.renewed" (the last
-- renewal's epoch microseconds, rewritten on every renew). Neither is a
-- task file, so the pending/leased/done scan (which only looks at
-- ".json" names) never sees them.
module Main (main) where

import Control.Concurrent (forkFinally, forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, newMVar, putMVar,
                                readMVar, modifyMVar_, takeMVar, tryPutMVar,
                                tryReadMVar, withMVar)
import Control.Concurrent.QSem (newQSem, signalQSem, waitQSem)
import Control.Exception (IOException, SomeException, bracket, catch,
                          displayException, finally, onException, throwIO, try)
import Control.Monad (foldM, forM, forM_, unless, void, when)
import Data.Aeson ((.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.List (isPrefixOf, sort, sortOn)
import Data.Maybe (listToMaybe)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Unique (hashUnique, newUnique)
import Numeric (showHex)
import System.Directory (createDirectoryIfMissing,
                         canonicalizePath, executable, getHomeDirectory,
                         getPermissions, getTemporaryDirectory,
                         listDirectory, removeDirectoryRecursive, removeFile,
                         removePathForcibly, renameDirectory, renameFile)
import System.Environment (getArgs, getExecutablePath)
import System.Exit (ExitCode (..), exitSuccess, exitWith)
import System.FilePath (isAbsolute, takeBaseName, takeDirectory,
                        takeExtension, (</>))
import System.IO (Handle, IOMode (AppendMode, ReadMode), hClose,
                  openBinaryFile, openBinaryTempFile, openFile, stderr)
import GHC.IO.Handle.Lock (LockMode (ExclusiveLock), hLock)
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import System.Posix.Files (FileStatus, createLink, getFileStatus, setFileMode)
import qualified System.Posix.Env.ByteString as PosixEnv
import System.Posix.Signals (Signal, sigKILL, sigTERM, signalProcess)
import System.IO.Unsafe (unsafePerformIO)
import System.Process (CreateProcess (..), ProcessHandle, StdStream (CreatePipe),
                       createProcess, getPid, proc, waitForProcess)
import qualified SpoolAttachments as SA
import qualified SpoolAccess as Access

type Object = KM.KeyMap A.Value

data Paths = Paths
  { rootDir :: FilePath
  , pendingDir :: FilePath
  , leasedDir :: FilePath
  , doneDir :: FilePath
  , failedDir :: FilePath
  , resultsDir :: FilePath
  , attachmentsDir :: FilePath
  , attachmentCleanupDir :: FilePath
  , lockPath :: FilePath
  }

data Task = Task
  { taskId :: T.Text
  , taskCapability :: T.Text
  , taskPayload :: A.Value
  , taskAttachments :: [SA.Attachment]
  } deriving (Eq, Show)

data Lease = Lease
  { leaseTask :: Task
  , leaseId :: T.Text
  , leaseWorker :: T.Text
  , leaseTime :: T.Text
  } deriving (Eq, Show)

data PutStatus = PutInserted | PutExisting deriving (Eq, Show)

data AckStatus = Acked | AlreadyDone deriving (Eq, Show)

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

data SpoolFailure = SpoolFailure Int String

-- | The outcome of running a capability's executable to completion.
data RunOutcome = RunSuccess BL.ByteString | RunFailure T.Text

data CapabilityConfig = CapabilityConfig
  { capExec :: FilePath
  , capArgs :: [String]
  , capTimeoutSeconds :: Int
  , capMaxPayloadBytes :: Int64
  , capMaxOutputBytes :: Int64
  } deriving (Eq, Show)

data WorkConfig = WorkConfig
  { wcMaxConcurrent :: Int
  , wcRenewSeconds :: Int
  , wcEnv :: [(String, String)]
  , wcCapabilities :: KM.KeyMap CapabilityConfig
  } deriving (Eq, Show)

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

withStore :: FilePath -> (Paths -> IO ()) -> IO ()
withStore directory action = do
  let paths = makePaths directory
  initialise paths
  withLock paths (recoverAttachmentState paths >> action paths)

-- | The "work" command's concurrent tasks each take the store lock for
-- their own transition, from separate green threads in this one process.
-- GHC's file lock (flock(2) under the hood) is scoped to the OS process, so
-- two threads in the same process racing to open and lock the same path is
-- not the cross-process case it was designed for, and observably (macOS,
-- GHC 9.14) a losing "openFile" can raise "resource busy" instead of
-- blocking. An in-process mutex serialises those threads before any of
-- them touches the file, leaving the file lock doing only what it always
-- did: keeping a second "spool" process out.
{-# NOINLINE inProcessLock #-}
inProcessLock :: MVar ()
inProcessLock = unsafePerformIO (newMVar ())

-- | Acquire the store's exclusive lock for exactly one transition. The
-- "work" command takes this per lease/renew/ack/fail rather than once for
-- the whole command, so an executable never runs while the lock is held.
withLock :: Paths -> IO a -> IO a
withLock paths action = withMVar inProcessLock $ \() ->
  bracket (openFile (lockPath paths) AppendMode) hClose $ \handle -> do
    hLock handle ExclusiveLock
    action

makePaths :: FilePath -> Paths
makePaths directory = Paths
  { rootDir = directory
  , pendingDir = directory </> "pending"
  , leasedDir = directory </> "leased"
  , doneDir = directory </> "done"
  , failedDir = directory </> "failed"
  , resultsDir = directory </> "results"
  , attachmentsDir = directory </> "attachments"
  , attachmentCleanupDir = directory </> ".attachment-cleanup"
  , lockPath = directory </> ".spool.lock"
  }

initialise :: Paths -> IO ()
initialise paths = mapM_ (createDirectoryIfMissing True)
  [rootDir paths, pendingDir paths, leasedDir paths, doneDir paths,
   failedDir paths, resultsDir paths, attachmentsDir paths,
   attachmentCleanupDir paths]

-- | Finish interrupted attachment deletion and remove spool-owned copies for
-- tasks which no longer have a pending or leased state. Recovery runs under
-- the transition lock, so it cannot race a compliant put or resolution.
recoverAttachmentState :: Paths -> IO ()
recoverAttachmentState paths = do
  cleanupNames <- listDirectory (attachmentCleanupDir paths)
  mapM_ (removePathForcibly . (attachmentCleanupDir paths </>)) cleanupNames
  pending <- jsonFiles (pendingDir paths) >>= mapM (fmap taskId . readTaskFile)
  leased <- jsonFiles (leasedDir paths) >>= mapM (fmap taskId . readTaskFile)
  let active = pending <> leased
  names <- listDirectory (attachmentsDir paths)
  forM_ names $ \name ->
    if ".spool-attachment-stage" `isPrefixOf` name
      then removePathForcibly (attachmentsDir paths </> name)
      else case T.stripPrefix "task-" (T.pack name) of
        Just ident | ident `notElem` active ->
          tombstoneAndDelete paths ident
        Just _ -> pure ()
        Nothing -> throwFailure (SpoolFailure 70
          ("unexpected entry in attachment store: " <> name))

tombstoneAndDelete :: Paths -> T.Text -> IO ()
tombstoneAndDelete paths ident = do
  source <- either (throwFailure . SpoolFailure 70) pure
    (SA.attachmentDirectory (attachmentsDir paths) ident)
  present <- fileExists source
  when present $ do
    target <- either (throwFailure . SpoolFailure 70) pure
      (SA.attachmentDirectory (attachmentCleanupDir paths) ident)
    renameDirectory source target
    removeDirectoryRecursive target

failWith :: Int -> String -> IO a
failWith code message = do
  BLC.hPutStrLn stderr (BLC.pack message)
  exitWith (ExitFailure code)

throwFailure :: SpoolFailure -> IO a
throwFailure (SpoolFailure code message) = failWith code ("spool: " <> message)

jsonFiles :: FilePath -> IO [FilePath]
jsonFiles directory = do
  names <- sort <$> listDirectory directory
  pure [directory </> name | name <- names, takeExtension name == ".json"]

-- `doesFileExist` intentionally turns every stat failure into False. That is
-- useful for optional files but unsafe for durable state: permissions and I/O
-- failures must not masquerade as a missing record.
fileExists :: FilePath -> IO Bool
fileExists path = do
  result <- try (getFileStatus path) :: IO (Either IOException FileStatus)
  case result of
    Right _ -> pure True
    Left exception
      | isDoesNotExistError exception -> pure False
      | otherwise -> ioError exception

objectKeys :: Object -> [T.Text]
objectKeys = map K.toText . KM.keys

validateCapability :: T.Text -> Either String ()
validateCapability value = case T.breakOn "@" value of
  (name, rest)
    | T.null rest -> Left "capability must be of the form name@version"
    | T.null name -> Left "capability name must be non-empty"
    | T.null version -> Left "capability version must be non-empty"
    | not (T.all validNameChar name) ->
        Left "capability name must match [A-Za-z0-9._-]+"
    | not (T.all validVersionChar version) ->
        Left "capability version must match [A-Za-z0-9.]+"
    | otherwise -> Right ()
    where
      version = T.drop 1 rest
      validNameChar character = asciiAlphaNum character || character `elem` ("._-" :: String)
      validVersionChar character = asciiAlphaNum character || character == '.'

asciiAlphaNum :: Char -> Bool
asciiAlphaNum character =
  ('a' <= character && character <= 'z') ||
  ('A' <= character && character <= 'Z') ||
  ('0' <= character && character <= '9')

parseTask :: BL.ByteString -> Either String Task
parseTask bytes = do
  value <- A.eitherDecode bytes
  case value of
    A.Object object -> do
      rejectUnknown ["task_id", "capability", "payload", "attachments"] object
      ident <- requiredText "task_id" object
      validateTaskId ident
      capability <- requiredText "capability" object
      validateCapability capability
      payload <- case KM.lookup "payload" object of
        Nothing -> Left "task is missing payload"
        Just value' -> Right value'
      attachments <- case KM.lookup "attachments" object of
        Nothing -> Right []
        Just value' -> case A.fromJSON value' of
          A.Error message -> Left message
          A.Success declarations -> SA.validateAttachments declarations
      pure (Task ident capability payload attachments)
    _ -> Left "task must be a JSON object"

parseAck :: BL.ByteString -> Either String (T.Text, T.Text, A.Value)
parseAck bytes = do
  value <- A.eitherDecode bytes
  case value of
    A.Object object -> do
      rejectUnknown ["task_id", "lease_id", "result"] object
      ident <- requiredText "task_id" object
      lease <- requiredText "lease_id" object
      result <- case KM.lookup "result" object of
        Nothing -> Left "ack is missing result"
        Just value' -> Right value'
      validateTaskId ident
      validateLeaseId lease
      pure (ident, lease, result)
    _ -> Left "ack must be a JSON object"

parseFail :: BL.ByteString -> Either String (T.Text, T.Text, T.Text)
parseFail bytes = do
  value <- A.eitherDecode bytes
  case value of
    A.Object object -> do
      rejectUnknown ["task_id", "lease_id", "reason"] object
      ident <- requiredText "task_id" object
      lease <- requiredText "lease_id" object
      reason <- requiredText "reason" object
      validateTaskId ident
      validateLeaseId lease
      pure (ident, lease, reason)
    _ -> Left "fail must be a JSON object"

parseFetchRequest :: BL.ByteString -> Either String (T.Text, T.Text, T.Text)
parseFetchRequest bytes = do
  value <- A.eitherDecode bytes
  case value of
    A.Object object -> do
      rejectUnknown ["task_id", "lease_id", "sha256"] object
      ident <- requiredText "task_id" object
      lease <- requiredText "lease_id" object
      digest <- requiredText "sha256" object
      validateTaskId ident
      validateLeaseId lease
      _ <- SA.validateAttachments [SA.Attachment digest 0]
      pure (ident, lease, digest)
    _ -> Left "fetch request must be a JSON object"

requiredText :: T.Text -> Object -> Either String T.Text
requiredText key object = case KM.lookup (K.fromText key) object of
  Nothing -> Left ("missing " <> T.unpack key)
  Just (A.String value)
    | T.null value -> Left (T.unpack key <> " must be non-empty")
    | otherwise -> Right value
  Just _ -> Left (T.unpack key <> " must be a string")

rejectUnknown :: [T.Text] -> Object -> Either String ()
rejectUnknown allowed object =
  case filter (`notElem` allowed) (objectKeys object) of
    [] -> Right ()
    extras -> Left ("unknown fields: " <> T.unpack (T.intercalate ", " extras))

validateTaskId :: T.Text -> Either String ()
validateTaskId value
  | T.null value = Left "task_id must be non-empty"
  | T.isInfixOf "--" value = Left "task_id cannot contain --"
  | T.all valid value = Right ()
  | otherwise = Left "task_id must contain only ASCII letters, digits, '.', '_' or '-'"
  where
    valid character = asciiAlphaNum character || character `elem` ("._-" :: String)

validateLeaseId :: T.Text -> Either String ()
validateLeaseId value
  | T.null value = Left "lease_id must be non-empty"
  | T.isInfixOf "--" value = Left "lease_id cannot contain --"
  | T.isPrefixOf "lease_" value && T.all valid (T.drop 6 value) = Right ()
  | otherwise = Left "lease_id is invalid"
  where
    valid character = asciiAlphaNum character || character `elem` ("._-" :: String)

encodeTask :: Task -> BL.ByteString
encodeTask task = canonical (A.object
  [ "task_id" .= taskId task
  , "capability" .= taskCapability task
  , "payload" .= taskPayload task
  , "attachments" .= taskAttachments task
  ])

encodePutResult :: Task -> PutStatus -> BL.ByteString
encodePutResult task result = canonical (A.object
  [ "task_id" .= taskId task
  , "status" .= case result of
      PutInserted -> ("inserted" :: T.Text)
      PutExisting -> "existing"
  ])

encodeLease :: Lease -> BL.ByteString
encodeLease lease = canonical (A.object
  [ "task_id" .= taskId (leaseTask lease)
  , "capability" .= taskCapability (leaseTask lease)
  , "lease_id" .= leaseId lease
  , "worker" .= leaseWorker lease
  , "leased_at" .= leaseTime lease
  , "payload" .= taskPayload (leaseTask lease)
  , "attachments" .= taskAttachments (leaseTask lease)
  ])

encodeAckResult :: T.Text -> AckStatus -> BL.ByteString
encodeAckResult ident result = canonical (A.object
  [ "task_id" .= ident
  , "status" .= case result of
      Acked -> ("acked" :: T.Text)
      AlreadyDone -> "already_done"
  ])

encodeRenewResult :: T.Text -> BL.ByteString
encodeRenewResult ident = canonical (A.object
  [ "task_id" .= ident
  , "status" .= ("renewed" :: T.Text)
  ])

encodeFailResult :: T.Text -> Bool -> BL.ByteString
encodeFailResult ident retried = canonical (A.object
  [ "task_id" .= ident
  , "status" .= (if retried then "failed_retry" else "failed" :: T.Text)
  ])

encodeReclaimResult :: T.Text -> BL.ByteString
encodeReclaimResult ident = canonical (A.object
  [ "task_id" .= ident
  , "status" .= ("reclaimed" :: T.Text)
  ])

encodeFailedRecord :: Task -> T.Text -> T.Text -> T.Text -> T.Text -> Bool -> BL.ByteString
encodeFailedRecord task leaseIdent worker failedAt reason retried = canonical (A.object
  [ "task_id" .= taskId task
  , "lease_id" .= leaseIdent
  , "capability" .= taskCapability task
  , "worker" .= worker
  , "failed_at" .= failedAt
  , "reason" .= reason
  , "retried" .= retried
  ])

encodeResultRecord :: Task -> T.Text -> T.Text -> T.Text -> A.Value -> BL.ByteString
encodeResultRecord task leaseIdent worker finishedAt output = canonical (A.object
  [ "task_id" .= taskId task
  , "lease_id" .= leaseIdent
  , "capability" .= taskCapability task
  , "worker" .= worker
  , "finished_at" .= finishedAt
  , "result" .= output
  ])

encodeStatus :: Int -> Int -> Int -> Int -> BL.ByteString
encodeStatus pending leased done failed = canonical (A.object
  [ "pending" .= pending
  , "leased" .= leased
  , "done" .= done
  , "failed" .= failed
  ])

canonical :: A.Value -> BL.ByteString
canonical value = case value of
  A.Null -> "null"
  A.Bool True -> "true"
  A.Bool False -> "false"
  A.Number number -> A.encode number
  A.String text -> A.encode text
  A.Array values -> "[" <> joinComma (map canonical (foldr (:) [] values)) <> "]"
  A.Object object -> "{" <> joinComma (map encodePair ordered) <> "}"
    where
      ordered = sortOn (K.toText . fst) (KM.toList object)
      encodePair (key, child) = A.encode (K.toText key) <> ":" <> canonical child

joinComma :: [BL.ByteString] -> BL.ByteString
joinComma [] = ""
joinComma (firstValue : rest) = firstValue <> foldMap ("," <>) rest

parseTaskLine :: BL.ByteString -> IO Task
parseTaskLine bytes = case parseTask bytes of
  Left message -> throwFailure (SpoolFailure 2 message)
  Right task -> pure task

parseAckLine :: BL.ByteString -> IO (T.Text, T.Text, A.Value)
parseAckLine bytes = case parseAck bytes of
  Left message -> throwFailure (SpoolFailure 2 message)
  Right ack -> pure ack

parseLeaseRef :: BL.ByteString -> Either String (T.Text, T.Text)
parseLeaseRef bytes = do
  value <- A.eitherDecode bytes
  case value of
    A.Object object -> do
      rejectUnknown ["task_id", "lease_id"] object
      ident <- requiredText "task_id" object
      lease <- requiredText "lease_id" object
      validateTaskId ident
      validateLeaseId lease
      pure (ident, lease)
    _ -> Left "lease reference must be a JSON object"

parseLeaseRefLine :: BL.ByteString -> IO (T.Text, T.Text)
parseLeaseRefLine bytes = case parseLeaseRef bytes of
  Left message -> throwFailure (SpoolFailure 2 message)
  Right reference -> pure reference

parseFailLine :: BL.ByteString -> IO (T.Text, T.Text, T.Text)
parseFailLine bytes = case parseFail bytes of
  Left message -> throwFailure (SpoolFailure 2 message)
  Right value -> pure value

isBlank :: BL.ByteString -> Bool
isBlank = all (`elem` [' ', '\t', '\r', '\n']) . BLC.unpack

inputLines :: IO [BL.ByteString]
inputLines = filter (not . isBlank) . BLC.lines <$> BL.getContents

putTasks :: Paths -> Maybe FilePath -> IO ()
putTasks paths sourceDirectory = do
  linesIn <- inputLines
  forM_ linesIn $ \line -> do
    task <- parseTaskLine line
    result <- putOne paths sourceDirectory task
    BLC.putStrLn (encodePutResult task result)

putOne :: Paths -> Maybe FilePath -> Task -> IO PutStatus
putOne paths sourceDirectory task = do
  existing <- findTask paths task
  case existing of
    Just True -> pure PutExisting
    Just False -> throwFailure (SpoolFailure 3
      ("task " <> T.unpack (taskId task) <> " already exists with different content"))
    Nothing -> do
      stageTaskAttachments paths sourceDirectory task
      let path = pendingDir paths </> T.unpack (taskId task) <> ".json"
      created <- atomicCreate path (encodeTask task)
      if created
        then pure PutInserted
        else do
          retry <- findTask paths task
          case retry of
            Just True -> pure PutExisting
            Just False -> throwFailure (SpoolFailure 3
              ("task " <> T.unpack (taskId task) <> " already exists with different content"))
            Nothing -> throwFailure (SpoolFailure 75 "could not create pending task")

stageTaskAttachments :: Paths -> Maybe FilePath -> Task -> IO ()
stageTaskAttachments _ _ task | null (taskAttachments task) = pure ()
stageTaskAttachments _ Nothing _ = throwFailure (SpoolFailure 2
  "tasks declaring attachments require put --attachments DIR")
stageTaskAttachments paths (Just sourceDirectory) task = do
  result <- SA.stageAttachments (attachmentsDir paths) sourceDirectory
    (taskId task) (taskAttachments task)
  case result of
    Left message -> throwFailure (SpoolFailure 2 message)
    Right () -> pure ()

-- True means an equal task was found; False means the id was found with
-- different content. The leased and done directories are intentionally
-- scanned because their filenames are coordination tokens, not task ids.
findTask :: Paths -> Task -> IO (Maybe Bool)
findTask paths wanted = do
  pending <- comparePath (pendingDir paths </> T.unpack (taskId wanted) <> ".json") wanted
  done <- compareFiles (doneDir paths) wanted
  leased <- compareFiles (leasedDir paths) wanted
  pure (firstFound [pending, done, leased])
  where
    firstFound [] = Nothing
    firstFound (Just value : _) = Just value
    firstFound (Nothing : rest) = firstFound rest

comparePath :: FilePath -> Task -> IO (Maybe Bool)
comparePath path wanted = do
  exists <- fileExists path
  if not exists then pure Nothing else Just <$> equalTaskFile path wanted

compareFiles :: FilePath -> Task -> IO (Maybe Bool)
compareFiles directory wanted = do
  files <- jsonFiles directory
  results <- forM files $ \path -> do
    task <- readTaskFile path
    pure $ if taskId task == taskId wanted then Just (task == wanted) else Nothing
  pure (listToMaybe [value | Just value <- results])

equalTaskFile :: FilePath -> Task -> IO Bool
equalTaskFile path wanted = (== wanted) <$> readTaskFile path

readTaskFile :: FilePath -> IO Task
readTaskFile path = do
  bytes <- BL.readFile path
  case parseTask bytes of
    Left message -> throwFailure (SpoolFailure 70
      ("corrupt task file " <> path <> ": " <> message))
    Right task -> pure task

readFailureRecordFile :: FilePath -> IO A.Value
readFailureRecordFile path = do
  bytes <- BL.readFile path
  case parseFailureRecord bytes of
    Left message -> throwFailure (SpoolFailure 70
      ("corrupt failure record " <> path <> ": " <> message))
    Right value -> pure value

readResultRecordFile :: FilePath -> IO (A.Value, A.Value)
readResultRecordFile path = do
  bytes <- BL.readFile path
  case parseResultRecord bytes of
    Left message -> throwFailure (SpoolFailure 70
      ("corrupt result record " <> path <> ": " <> message))
    Right value -> pure value

parseFailureRecord :: BL.ByteString -> Either String A.Value
parseFailureRecord bytes = do
  value <- A.eitherDecode bytes
  case value of
    A.Object object -> do
      rejectUnknown
        [ "task_id", "lease_id", "capability", "worker", "failed_at"
        , "reason", "retried"
        ] object
      validateRecordIdentity object
      _ <- requiredText "failed_at" object
      _ <- requiredText "reason" object
      case KM.lookup "retried" object of
        Just (A.Bool _) -> Right value
        Just _ -> Left "retried must be a boolean"
        Nothing -> Left "missing retried"
    _ -> Left "failure record must be a JSON object"

parseResultRecord :: BL.ByteString -> Either String (A.Value, A.Value)
parseResultRecord bytes = do
  value <- A.eitherDecode bytes
  case value of
    A.Object object -> do
      rejectUnknown
        [ "task_id", "lease_id", "capability", "worker", "finished_at"
        , "result"
        ] object
      validateRecordIdentity object
      _ <- requiredText "finished_at" object
      result <- case KM.lookup "result" object of
        Just resultValue -> Right resultValue
        Nothing -> Left "missing result"
      pure (value, result)
    _ -> Left "result record must be a JSON object"

validateRecordIdentity :: Object -> Either String ()
validateRecordIdentity object = do
  ident <- requiredText "task_id" object
  lease <- requiredText "lease_id" object
  capability <- requiredText "capability" object
  _ <- requiredText "worker" object
  validateTaskId ident
  validateLeaseId lease
  validateCapability capability

extractTextField :: T.Text -> A.Value -> T.Text
extractTextField key (A.Object object) = case KM.lookup (K.fromText key) object of
  Just (A.String value) -> value
  _ -> ""
extractTextField _ _ = ""

atomicCreate :: FilePath -> BL.ByteString -> IO Bool
atomicCreate path bytes = do
  let directory = takeDirectory path
  createDirectoryIfMissing True directory
  (temporary, handle) <- openBinaryTempFile directory ".spool-task"
  result <- (BL.hPut handle bytes >> hClose handle >> try (createLink temporary path))
    `finally` ignoreMissing (removeFile temporary)
  case result of
    Right () -> pure True
    Left exception
      | isAlreadyExistsError exception -> pure False
      | otherwise -> ioError exception

atomicReplace :: FilePath -> BL.ByteString -> IO ()
atomicReplace path bytes = do
  let directory = takeDirectory path
  (temporary, handle) <- openBinaryTempFile directory ".spool-sequence"
  (BL.hPut handle bytes >> hClose handle >> renameFile temporary path)
    `finally` ignoreMissing (removeFile temporary)

ignoreMissing :: IO () -> IO ()
ignoreMissing action = action `catch` ignore
  where
    ignore :: IOException -> IO ()
    ignore exception
      | isDoesNotExistError exception = pure ()
      | otherwise = ioError exception

ignoreProcessRace :: IO () -> IO ()
ignoreProcessRace action = action `catch` ignore
  where
    ignore :: IOException -> IO ()
    ignore _ = pure ()

-- Sidecars: a lease's worker (written once, as UTF-8) and its last renewal
-- (rewritten on every renew). Neither has a ".json" extension, so jsonFiles
-- never returns them.
workerSidecarPath :: Paths -> T.Text -> FilePath
workerSidecarPath paths leaseIdent = leasedDir paths </> T.unpack leaseIdent <> ".worker"

renewedSidecarPath :: Paths -> T.Text -> FilePath
renewedSidecarPath paths leaseIdent = leasedDir paths </> T.unpack leaseIdent <> ".renewed"

writeWorkerSidecar :: Paths -> T.Text -> T.Text -> IO ()
writeWorkerSidecar paths leaseIdent worker = do
  created <- atomicCreate
    (workerSidecarPath paths leaseIdent) (BL.fromStrict (TE.encodeUtf8 worker))
  unless created (throwFailure (SpoolFailure 70
    ("worker sidecar already exists for " <> T.unpack leaseIdent)))

readWorkerSidecar :: Paths -> T.Text -> IO T.Text
readWorkerSidecar paths leaseIdent = do
  let path = workerSidecarPath paths leaseIdent
  exists <- fileExists path
  if not exists
    then throwFailure (SpoolFailure 70
      ("leased task has no worker sidecar: " <> T.unpack leaseIdent))
    else do
      bytes <- BS.readFile path
      case TE.decodeUtf8' bytes of
        Left _ -> throwFailure (SpoolFailure 70
          ("corrupt worker sidecar for " <> T.unpack leaseIdent))
        Right worker -> pure (T.strip worker)

writeRenewedSidecar :: Paths -> T.Text -> Integer -> IO ()
writeRenewedSidecar paths leaseIdent micros =
  atomicReplace (renewedSidecarPath paths leaseIdent) (BLC.pack (show micros))

readRenewedSidecar :: Paths -> T.Text -> IO (Maybe Integer)
readRenewedSidecar paths leaseIdent = do
  let path = renewedSidecarPath paths leaseIdent
  exists <- fileExists path
  if not exists
    then pure Nothing
    else do
      value <- readInteger . T.strip . T.pack . BLC.unpack <$> BL.readFile path
      case value of
        Just micros -> pure (Just micros)
        Nothing -> throwFailure (SpoolFailure 70
          ("corrupt renewal sidecar for " <> T.unpack leaseIdent))

removeSidecars :: Paths -> T.Text -> IO ()
removeSidecars paths leaseIdent = do
  ignoreMissing (removeFile (workerSidecarPath paths leaseIdent))
  ignoreMissing (removeFile (renewedSidecarPath paths leaseIdent))

leaseTasks :: Paths -> T.Text -> Int -> IO ()
leaseTasks paths worker count = do
  leased <- leaseUpTo paths worker count
  when (null leased) (exitWith (ExitFailure 1))
  forM_ leased (BLC.putStrLn . encodeLease)

-- | Lease up to `count` pending tasks for `worker`. Used by both the CLI
-- `lease` command and the `work` loop (with count 1). Returns fewer than
-- `count` (possibly none) when pending is exhausted.
leaseUpTo :: Paths -> T.Text -> Int -> IO [Lease]
leaseUpTo paths worker count = do
  pending <- jsonFiles (pendingDir paths)
  active <- activeTaskIds paths
  leaseMany pending active count []
  where
    leaseMany _ _ 0 output = pure (reverse output)
    leaseMany [] _ _ output = pure (reverse output)
    leaseMany (path : rest) active remaining output = do
      task <- readTaskFile path
      if taskId task `elem` active
        then leaseMany rest active remaining output
        else do
          now <- getCurrentTime
          micros <- epochMicros
          leaseIdent <- uniqueLeaseId paths micros (taskId task)
          let target = leasedDir paths </> T.unpack leaseIdent <> ".json"
              lease = Lease task leaseIdent worker
                (T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now))
          moved <- try (renameFile path target) :: IO (Either IOException ())
          case moved of
            Left exception
              | isDoesNotExistError exception ->
                  leaseMany rest active remaining output
              | otherwise -> throwFailure (SpoolFailure 75
                  ("could not lease " <> path <> ": " <> displayException exception))
            Right () -> do
              writeWorkerSidecar paths leaseIdent worker
              leaseMany rest (taskId task : active) (remaining - 1) (lease : output)

activeTaskIds :: Paths -> IO [T.Text]
activeTaskIds paths = do
  files <- jsonFiles (leasedDir paths)
  mapM (fmap taskId . readTaskFile) files

uniqueLeaseId :: Paths -> Integer -> T.Text -> IO T.Text
uniqueLeaseId paths micros ident = do
  serial <- nextLeaseSerial paths
  pure ("lease_" <> T.pack (show micros) <> "_" <> T.pack (show serial)
    <> "_" <> ident)

nextLeaseSerial :: Paths -> IO Integer
nextLeaseSerial paths = do
  let path = rootDir paths </> ".lease-sequence"
  present <- fileExists path
  current <- if present then readInteger . T.strip . T.pack <$> readFile path else pure (Just 0)
  case current of
    Nothing -> throwFailure (SpoolFailure 70 "corrupt lease sequence")
    Just value -> do
      let next = value + 1
      atomicReplace path (BLC.pack (show next <> "\n"))
      pure next

epochMicros :: IO Integer
epochMicros = round . (* 1000000) <$> getPOSIXTime

ackTasks :: Paths -> IO ()
ackTasks paths = inputLines >>= ackLines paths

ackLines :: Paths -> [BL.ByteString] -> IO ()
ackLines paths linesIn = do
  failures <- foldM (ackOneAndReport paths) False linesIn
  when failures (throwFailure (SpoolFailure 4 "one or more leases were stale or unknown"))

ackOneAndReport :: Paths -> Bool -> BL.ByteString -> IO Bool
ackOneAndReport paths hadFailure line = do
  (ident, leaseIdent, output) <- parseAckLine line
  result <- ackOne paths ident leaseIdent output
  case result of
    Left message -> do
      BLC.hPutStrLn stderr (BLC.pack ("spool: " <> message))
      pure True
    Right status -> do
      BLC.putStrLn (encodeAckResult ident status)
      pure hadFailure

ackOne :: Paths -> T.Text -> T.Text -> A.Value -> IO (Either String AckStatus)
ackOne paths ident leaseIdent output = do
  let source = leasedDir paths </> T.unpack leaseIdent <> ".json"
      target = doneDir paths </> T.unpack leaseIdent <> ".json"
  sourceExists <- fileExists source
  if sourceExists
    then do
      task <- readTaskFile source
      if taskId task /= ident
        then pure (Left "lease does not belong to task_id")
        else do
          worker <- readWorkerSidecar paths leaseIdent
          stored <- writeResultRecord paths task leaseIdent worker output
          case stored of
            Left message -> pure (Left message)
            Right () -> do
              moved <- try (renameFile source target) :: IO (Either IOException ())
              case moved of
                Right () -> do
                  removeSidecars paths leaseIdent
                  tombstoneAndDelete paths (taskId task)
                  pure (Right Acked)
                Left exception
                  | isDoesNotExistError exception -> do
                      done <- findDoneLease paths ident leaseIdent
                      doneResult paths ident leaseIdent output done
                  | otherwise -> throwFailure (SpoolFailure 75
                      ("could not move leased task to done: "
                        <> displayException exception))
    else do
      done <- findDoneLease paths ident leaseIdent
      doneResult paths ident leaseIdent output done

doneResult :: Paths -> T.Text -> T.Text -> A.Value -> Maybe Bool
           -> IO (Either String AckStatus)
doneResult paths _ident leaseIdent output done = case done of
  Just True -> do
    same <- completedResultMatches paths leaseIdent output
    pure $ if same
      then Right AlreadyDone
      else Left "ack result differs from completed result"
  Just False -> pure (Left "lease is stale")
  Nothing -> pure (Left "lease is unknown or stale")

completedResultMatches :: Paths -> T.Text -> A.Value -> IO Bool
completedResultMatches paths leaseIdent output = do
  let path = resultsDir paths </> T.unpack leaseIdent <> ".json"
  present <- fileExists path
  unless present (throwFailure (SpoolFailure 75
    ("completed lease has no result: " <> T.unpack leaseIdent)))
  (_, stored) <- readResultRecordFile path
  pure (stored == output)

findDoneLease :: Paths -> T.Text -> T.Text -> IO (Maybe Bool)
findDoneLease paths ident leaseIdent = do
  files <- jsonFiles (doneDir paths)
  matches <- forM files $ \path -> do
    task <- readTaskFile path
    pure $ if taskId task /= ident then Nothing
      else Just (takeBaseName path == T.unpack leaseIdent)
  pure (listToMaybe [value | Just value <- matches])

renewTasks :: Paths -> IO ()
renewTasks paths = inputLines >>= renewLines paths

renewLines :: Paths -> [BL.ByteString] -> IO ()
renewLines paths linesIn = do
  failures <- foldM (renewOneAndReport paths) False linesIn
  when failures (throwFailure (SpoolFailure 4 "one or more leases were stale or unknown"))

renewOneAndReport :: Paths -> Bool -> BL.ByteString -> IO Bool
renewOneAndReport paths hadFailure line = do
  (ident, leaseIdent) <- parseLeaseRefLine line
  result <- renewOne paths ident leaseIdent
  case result of
    Left message -> do
      BLC.hPutStrLn stderr (BLC.pack ("spool: " <> message))
      pure True
    Right () -> do
      BLC.putStrLn (encodeRenewResult ident)
      pure hadFailure

renewOne :: Paths -> T.Text -> T.Text -> IO (Either String ())
renewOne paths ident leaseIdent = do
  let source = leasedDir paths </> T.unpack leaseIdent <> ".json"
  exists <- fileExists source
  if not exists
    then pure (Left "lease is unknown or stale")
    else do
      task <- readTaskFile source
      if taskId task /= ident
        then pure (Left "lease does not belong to task_id")
        else do
          micros <- epochMicros
          writeRenewedSidecar paths leaseIdent micros
          pure (Right ())

failTasks :: Bool -> Paths -> IO ()
failTasks retry paths = inputLines >>= failLines retry paths

failLines :: Bool -> Paths -> [BL.ByteString] -> IO ()
failLines retry paths linesIn = do
  failures <- foldM (failOneAndReport retry paths) False linesIn
  when failures (throwFailure (SpoolFailure 4 "one or more leases were stale or unknown"))

failOneAndReport :: Bool -> Paths -> Bool -> BL.ByteString -> IO Bool
failOneAndReport retry paths hadFailure line = do
  (ident, leaseIdent, reason) <- parseFailLine line
  result <- failLease paths ident leaseIdent reason retry
  case result of
    Left message -> do
      BLC.hPutStrLn stderr (BLC.pack ("spool: " <> message))
      pure True
    Right retried -> do
      BLC.putStrLn (encodeFailResult ident retried)
      pure hadFailure

-- | Move a leased task to failed/, recording why, and (with retry) put an
-- identical task back in pending/. Shared by the CLI `fail` command and the
-- `work` loop's failure paths.
failLease :: Paths -> T.Text -> T.Text -> T.Text -> Bool -> IO (Either String Bool)
failLease paths ident leaseIdent reason retry = do
  let source = leasedDir paths </> T.unpack leaseIdent <> ".json"
  exists <- fileExists source
  if not exists
    then pure (Left "lease is unknown or stale")
    else do
      task <- readTaskFile source
      if taskId task /= ident
        then pure (Left "lease does not belong to task_id")
        else do
          worker <- readWorkerSidecar paths leaseIdent
          now <- getCurrentTime
          let failedAt = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now)
              record = encodeFailedRecord task leaseIdent worker failedAt reason retry
          _ <- atomicCreate (failedDir paths </> T.unpack leaseIdent <> ".json") record
          when retry (returnToPending paths task)
          removeFile source
          removeSidecars paths leaseIdent
          unless retry (tombstoneAndDelete paths (taskId task))
          pure (Right retry)

-- | Recreate a task in pending/, exactly as reclaim does: idempotent if an
-- equal task is already there, a hard failure if a conflicting one is.
returnToPending :: Paths -> Task -> IO ()
returnToPending paths task = do
  let pendingPath = pendingDir paths </> T.unpack (taskId task) <> ".json"
  present <- fileExists pendingPath
  if present
    then do
      same <- equalTaskFile pendingPath task
      unless same (throwFailure (SpoolFailure 3
        ("pending task conflicts with returned lease for " <> T.unpack (taskId task))))
    else do
      created <- atomicCreate pendingPath (encodeTask task)
      unless created $ do
        same <- equalTaskFile pendingPath task
        unless same (throwFailure (SpoolFailure 3
          ("could not return task " <> T.unpack (taskId task))))

failuresCommand :: Paths -> IO ()
failuresCommand paths = do
  files <- jsonFiles (failedDir paths)
  records <- mapM readFailureRecordFile files
  mapM_ (BLC.putStrLn . canonical) (oldestFirst "failed_at" records)

resultsCommand :: Paths -> IO ()
resultsCommand paths = do
  files <- jsonFiles (resultsDir paths)
  records <- mapM (fmap fst . readResultRecordFile) files
  mapM_ (BLC.putStrLn . canonical) (oldestFirst "finished_at" records)

fetchAttachment :: Paths -> IO ()
fetchAttachment paths = BL.getContents >>= fetchAttachmentBytes paths

fetchAttachmentBytes :: Paths -> BL.ByteString -> IO ()
fetchAttachmentBytes paths bytes = do
  (ident, leaseIdent, digest) <- case parseFetchRequest bytes of
    Left message -> throwFailure (SpoolFailure 2 message)
    Right request -> pure request
  let leasePath = leasedDir paths </> T.unpack leaseIdent <> ".json"
  present <- fileExists leasePath
  unless present (throwFailure (SpoolFailure 4 "lease is unknown or stale"))
  task <- readTaskFile leasePath
  unless (taskId task == ident)
    (throwFailure (SpoolFailure 4 "lease does not belong to task_id"))
  attachment <- case
      [declaration | declaration <- taskAttachments task,
        SA.attachmentSha256 declaration == digest] of
    declaration : _ -> pure declaration
    [] -> throwFailure (SpoolFailure 2 "attachment is not declared by the task")
  path <- either (throwFailure . SpoolFailure 70) pure
    (SA.attachmentPath (attachmentsDir paths) ident attachment)
  verified <- SA.verifyAttachmentFile attachment path
  case verified of
    Left message -> throwFailure (SpoolFailure 70
      ("corrupt attachment for " <> T.unpack ident <> ": " <> message))
    Right () -> BL.readFile path >>= BL.putStr

oldestFirst :: T.Text -> [A.Value] -> [A.Value]
oldestFirst key records = map snd (sortOn fst [(extractTextField key record, record) | record <- records])

writeResultRecord
  :: Paths -> Task -> T.Text -> T.Text -> A.Value -> IO (Either String ())
writeResultRecord paths task leaseIdent worker output = do
  now <- getCurrentTime
  let finishedAt = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now)
      record = encodeResultRecord task leaseIdent worker finishedAt output
      path = resultsDir paths </> T.unpack leaseIdent <> ".json"
  created <- atomicCreate path record
  if created
    then pure (Right ())
    else do
      same <- completedResultMatches paths leaseIdent output
      pure $ if same
        then Right ()
        else Left "ack result differs from the result already stored for this lease"

reclaimTasks :: Paths -> Integer -> IO ()
reclaimTasks paths age = do
  now <- epochMicros
  files <- jsonFiles (leasedDir paths)
  forM_ files $ \path -> do
    let leaseIdent = T.pack (takeBaseName path)
    case leaseMicros leaseIdent of
      Nothing -> throwFailure (SpoolFailure 70 ("corrupt lease filename: " <> path))
      Just started -> do
        renewed <- readRenewedSidecar paths leaseIdent
        let effective = maybe started (max started) renewed
        when (now - effective >= age * 1000000) (reclaimOne paths path)

reclaimOne :: Paths -> FilePath -> IO ()
reclaimOne paths leasedPath = do
  task <- readTaskFile leasedPath
  let leaseIdent = T.pack (takeBaseName leasedPath)
  returnToPending paths task
  removeFile leasedPath
  removeSidecars paths leaseIdent
  BLC.putStrLn (encodeReclaimResult (taskId task))

leaseMicros :: T.Text -> Maybe Integer
leaseMicros value = case T.stripPrefix "lease_" value of
  Nothing -> Nothing
  Just rest -> readInteger (T.takeWhile isAsciiDigit rest)

isAsciiDigit :: Char -> Bool
isAsciiDigit character = '0' <= character && character <= '9'

readInteger :: T.Text -> Maybe Integer
readInteger value = case reads (T.unpack value) of
  [(number, "")] -> Just number
  _ -> Nothing

statusTasks :: Paths -> Bool -> IO ()
statusTasks paths json = do
  pending <- length <$> jsonFiles (pendingDir paths)
  leased <- length <$> jsonFiles (leasedDir paths)
  done <- length <$> jsonFiles (doneDir paths)
  failed <- length <$> jsonFiles (failedDir paths)
  if json
    then BLC.putStrLn (encodeStatus pending leased done failed)
    else putStrLn ("pending=" <> show pending <> " leased=" <> show leased
      <> " done=" <> show done <> " failed=" <> show failed)

--------------------------------------------------------------------------
-- Account grants and the exact SSH forced-command boundary.
--------------------------------------------------------------------------

accountGrantPaths :: IO (FilePath, FilePath)
accountGrantPaths = do
  home <- getHomeDirectory
  pure (home </> ".spool" </> "grants", home </> ".ssh" </> "authorized_keys")

prepareAccountPaths :: IO (FilePath, FilePath)
prepareAccountPaths = do
  (grants, authorizedKeys) <- accountGrantPaths
  createDirectoryIfMissing True grants
  createDirectoryIfMissing True (takeDirectory authorizedKeys)
  setFileMode (takeDirectory authorizedKeys) 0o700
  pure (grants, authorizedKeys)

grantAccess :: Paths -> T.Text -> T.Text -> FilePath -> Maybe T.Text -> IO ()
grantAccess paths peer worker keyPath expiry = do
  canonicalSpool <- canonicalizePath (rootDir paths)
  publicKey <- readCanonicalPublicKey keyPath
  (grants, authorizedKeys) <- prepareAccountPaths
  existing <- readGrantDirectory grants
  when (any (sameWorkerOrKey canonicalSpool worker publicKey) existing)
    (throwFailure (SpoolFailure 3
      "an active grant for this spool already uses that worker or public key"))
  identifier <- freshGrantId grants
  grant <- case Access.validateGrant identifier peer worker canonicalSpool publicKey expiry of
    Left message -> throwFailure (SpoolFailure 2 message)
    Right value -> pure value
  executablePath <- getExecutablePath >>= canonicalizePath
  managedLine <- case Access.renderManagedAuthorizedKeyLine executablePath grant of
    Left message -> throwFailure (SpoolFailure 2 message)
    Right value -> pure value
  recordPath <- either (throwFailure . SpoolFailure 2) pure
    (Access.grantRecordPath grants identifier)
  created <- atomicCreate recordPath (BL.fromStrict (Access.renderGrant grant))
  unless created (throwFailure (SpoolFailure 75 "could not create unique grant record"))
  appendManagedKey authorizedKeys managedLine
    `onException` ignoreMissing (removeFile recordPath)
  BLC.putStrLn (BL.fromStrict (Access.renderGrant grant))
  where
    sameWorkerOrKey spool workerName key grant =
      Access.grantSpool grant == spool
        && (Access.grantWorker grant == workerName
          || Access.grantPublicKey grant == key)

readCanonicalPublicKey :: FilePath -> IO T.Text
readCanonicalPublicKey path = do
  bytes <- BS.readFile path
  let withoutNewline =
        if not (BS.null bytes) && BS.last bytes == 10 then BS.init bytes else bytes
  when (BS.null withoutNewline || BS.elem 10 withoutNewline || BS.elem 13 withoutNewline)
    (throwFailure (SpoolFailure 2 "public key file must contain exactly one line"))
  key <- case TE.decodeUtf8' withoutNewline of
    Left _ -> throwFailure (SpoolFailure 2 "public key must be UTF-8")
    Right value -> pure value
  case Access.validatePublicKey key of
    Left message -> throwFailure (SpoolFailure 2 message)
    Right () -> pure key

readGrantDirectory :: FilePath -> IO [Access.Grant]
readGrantDirectory directory = do
  files <- jsonFiles directory
  forM files $ \path -> do
    grant <- readGrantRecord 70 path
    unless (T.unpack (Access.grantId grant) == takeBaseName path)
      (throwFailure (SpoolFailure 70
        ("grant filename does not match its record: " <> path)))
    pure grant

readGrantRecord :: Int -> FilePath -> IO Access.Grant
readGrantRecord failureCode path = do
  bytes <- BS.readFile path
  case Access.parseGrantJSON bytes of
    Left message -> throwFailure (SpoolFailure failureCode
      ("invalid grant record " <> path <> ": " <> message))
    Right grant -> pure grant

freshGrantId :: FilePath -> IO T.Text
freshGrantId grants = do
  bytes <- bracket (openBinaryFile "/dev/urandom" ReadMode) hClose (`BS.hGet` 16)
  unless (BS.length bytes == 16)
    (throwFailure (SpoolFailure 75 "could not read a grant identifier"))
  let identifier = "grant_" <> T.pack (concatMap renderByte (BS.unpack bytes))
  path <- either (throwFailure . SpoolFailure 70) pure
    (Access.grantRecordPath grants identifier)
  collision <- fileExists path
  if collision then freshGrantId grants else pure identifier
  where
    renderByte byte = case showHex byte "" of
      [digit] -> ['0', digit]
      digits -> digits

appendManagedKey :: FilePath -> BS.ByteString -> IO ()
appendManagedKey authorizedKeys managedLine = do
  present <- fileExists authorizedKeys
  current <- if present then BS.readFile authorizedKeys else pure BS.empty
  let separator = if BS.null current || BS.last current == 10 then BS.empty else "\n"
  atomicReplace authorizedKeys
    (BL.fromStrict (current <> separator <> managedLine))
  setFileMode authorizedKeys 0o600

rewriteAuthorizedKeys :: FilePath -> (BS.ByteString -> BS.ByteString) -> IO ()
rewriteAuthorizedKeys authorizedKeys transform = do
  present <- fileExists authorizedKeys
  when present $ do
    current <- BS.readFile authorizedKeys
    let updated = transform current
    when (updated /= current) $ do
      atomicReplace authorizedKeys (BL.fromStrict updated)
      setFileMode authorizedKeys 0o600

revokeAccess :: Paths -> T.Text -> IO ()
revokeAccess paths identifier = do
  case Access.validateGrantId identifier of
    Left message -> throwFailure (SpoolFailure 2 message)
    Right () -> pure ()
  canonicalSpool <- canonicalizePath (rootDir paths)
  (grants, authorizedKeys) <- prepareAccountPaths
  activePath <- either (throwFailure . SpoolFailure 2) pure
    (Access.grantRecordPath grants identifier)
  let tombstonePath = grants </> T.unpack identifier <> ".revoked"
  active <- fileExists activePath
  activeGrant <- if active
    then Just <$> readGrantRecord 70 activePath
    else pure Nothing
  case activeGrant of
    Just value | Access.grantId value /= identifier ->
      throwFailure (SpoolFailure 70 "grant filename does not match its record")
    _ -> pure ()
  case activeGrant of
    Just value | Access.grantSpool value /= canonicalSpool ->
      throwFailure (SpoolFailure 5 "grant belongs to a different spool")
    _ -> pure ()
  when active (renameFile activePath tombstonePath)
  tombstoned <- fileExists tombstonePath
  grant <- case activeGrant of
    Just value -> pure (Just value)
    Nothing | tombstoned -> Just <$> readGrantRecord 70 tombstonePath
    Nothing -> pure Nothing
  case grant of
    Just value | Access.grantId value /= identifier ->
      throwFailure (SpoolFailure 70 "grant tombstone does not match its identifier")
    _ -> pure ()
  case grant of
    Just value | Access.grantSpool value /= canonicalSpool ->
      throwFailure (SpoolFailure 5 "grant belongs to a different spool")
    _ -> pure ()
  rewriteAuthorizedKeys authorizedKeys
    (Access.filterManagedGrantLine identifier)
  case grant of
    Just value -> reclaimWorkerLeases paths (Access.grantWorker value)
    Nothing -> pure ()
  when tombstoned (removeFile tombstonePath)
  BLC.putStrLn (canonical (A.object
    [ "grant_id" .= identifier
    , "status" .= ("revoked" :: T.Text)
    ]))

reclaimWorkerLeases :: Paths -> T.Text -> IO ()
reclaimWorkerLeases paths worker = do
  files <- jsonFiles (leasedDir paths)
  forM_ files $ \path -> do
    let leaseIdent = T.pack (takeBaseName path)
    owner <- readWorkerSidecar paths leaseIdent
    when (owner == worker) $ do
      task <- readTaskFile path
      returnToPending paths task
      removeFile path
      removeSidecars paths leaseIdent

runRemote :: T.Text -> IO ()
runRemote identifier = do
  case Access.validateGrantId identifier of
    Left message -> failWith 2 ("spool: " <> message)
    Right () -> pure ()
  (grants, _) <- accountGrantPaths
  path <- either (failWith 2 . ("spool: " <>)) pure
    (Access.grantRecordPath grants identifier)
  grant <- loadActiveRemoteGrant identifier path
  requested <- PosixEnv.getEnv "SSH_ORIGINAL_COMMAND"
  operation <- case Access.parseRemoteCommand (maybe BS.empty id requested) of
    Left message -> failWith 2 ("spool: " <> message)
    Right value -> pure value
  let paths = makePaths (Access.grantSpool grant)
  initialise paths
  withLock paths $ do
    current <- loadActiveRemoteGrant identifier path
    unless (Access.grantSpool current == rootDir paths)
      (failWith 5 "spool: grant is missing, revoked, or expired")
    recoverAttachmentState paths
    dispatchRemote paths (Access.grantWorker current) operation

loadActiveRemoteGrant :: T.Text -> FilePath -> IO Access.Grant
loadActiveRemoteGrant identifier path = do
  present <- fileExists path
  unless present (failWith 5 "spool: grant is missing, revoked, or expired")
  grant <- readGrantRecord 5 path
  unless (Access.grantId grant == identifier)
    (failWith 5 "spool: grant is missing, revoked, or expired")
  now <- getCurrentTime
  when (maybe False (now >=) (Access.grantExpiresAt grant))
    (failWith 5 "spool: grant is missing, revoked, or expired")
  pure grant

dispatchRemote :: Paths -> T.Text -> Access.RemoteCommand -> IO ()
dispatchRemote paths worker operation = case operation of
  Access.RemoteLease count -> do
    let requested = maybe 1 id count
    when (requested > toInteger (maxBound :: Int))
      (throwFailure (SpoolFailure 2 "lease count is too large for this host"))
    leaseTasks paths worker (fromInteger requested)
  Access.RemoteAck -> do
    linesIn <- inputLines
    references <- mapM (fmap (\(ident, lease, _) -> (ident, lease)) . parseAckLine) linesIn
    mapM_ (ensureRemoteAckOwner paths worker) references
    ackLines paths linesIn
  Access.RemoteRenew -> do
    linesIn <- inputLines
    references <- mapM parseLeaseRefLine linesIn
    mapM_ (ensureLiveLeaseOwner paths worker) references
    renewLines paths linesIn
  Access.RemoteFail retry -> do
    linesIn <- inputLines
    references <- mapM (fmap (\(ident, lease, _) -> (ident, lease)) . parseFailLine) linesIn
    mapM_ (ensureLiveLeaseOwner paths worker) references
    failLines retry paths linesIn
  Access.RemoteFetch -> do
    bytes <- BL.getContents
    (ident, leaseIdent, _) <- case parseFetchRequest bytes of
      Left message -> throwFailure (SpoolFailure 2 message)
      Right value -> pure value
    ensureLiveLeaseOwner paths worker (ident, leaseIdent)
    fetchAttachmentBytes paths bytes

ensureLiveLeaseOwner :: Paths -> T.Text -> (T.Text, T.Text) -> IO ()
ensureLiveLeaseOwner paths worker (ident, leaseIdent) = do
  let path = leasedDir paths </> T.unpack leaseIdent <> ".json"
  present <- fileExists path
  unless present (throwFailure (SpoolFailure 4 "lease is unknown or stale"))
  task <- readTaskFile path
  unless (taskId task == ident)
    (throwFailure (SpoolFailure 4 "lease does not belong to task_id"))
  owner <- readWorkerSidecar paths leaseIdent
  unless (owner == worker)
    (throwFailure (SpoolFailure 4 "lease belongs to a different worker"))

ensureRemoteAckOwner :: Paths -> T.Text -> (T.Text, T.Text) -> IO ()
ensureRemoteAckOwner paths worker reference@(_, leaseIdent) = do
  live <- fileExists (leasedDir paths </> T.unpack leaseIdent <> ".json")
  if live
    then ensureLiveLeaseOwner paths worker reference
    else do
      let resultPath = resultsDir paths </> T.unpack leaseIdent <> ".json"
      present <- fileExists resultPath
      unless present (throwFailure (SpoolFailure 4 "lease is unknown or stale"))
      (record, _) <- readResultRecordFile resultPath
      let (ident, _) = reference
      unless (extractTextField "task_id" record == ident
        && extractTextField "worker" record == worker)
        (throwFailure (SpoolFailure 4 "lease belongs to a different worker"))

--------------------------------------------------------------------------
-- Worker: maps a capability to a locally configured executable and runs
-- leased tasks under Spool's own declared limits: concurrency, timeout,
-- payload size, and captured output size. These bound what Spool itself
-- does, not what the executable can do to the machine it runs on -- there
-- is no CPU/memory/file-size containment or sandbox. A capability owner who
-- needs that wraps their executable (rlimits, a container, a VM) themselves.
--------------------------------------------------------------------------

runWorkShow :: FilePath -> IO ()
runWorkShow configPath = do
  config <- loadWorkConfig configPath
  BLC.putStrLn (encodeWorkConfig config)
  exitSuccess

runWork :: Paths -> T.Text -> FilePath -> Maybe Int -> IO ()
runWork paths worker configPath maxTasks = do
  config <- loadWorkConfig configPath
  slots <- newQSem (wcMaxConcurrent config)
  completions <- newQSem 0
  workerFailures <- newMVar ([] :: [SomeException])
  launchedRef <- newIORef (0 :: Int)
  let loop = do
        launched <- readIORef launchedRef
        if maybe False (launched >=) maxTasks
          then pure ()
          else do
            waitQSem slots
            leased <- withLock paths (leaseUpTo paths worker 1)
            case leased of
              [] -> signalQSem slots
              (lease : _) -> do
                writeIORef launchedRef (launched + 1)
                _ <- forkFinally (runOneLease paths config lease) $ \outcome -> do
                  case outcome of
                    Left exception ->
                      modifyMVar_ workerFailures (pure . (exception :))
                    Right () -> pure ()
                  signalQSem slots
                  signalQSem completions
                loop
  loop
  final <- readIORef launchedRef
  waitAll completions final
  failures <- readMVar workerFailures
  case reverse failures of
    [] -> pure ()
    exception : _ -> throwIO exception
  where
    waitAll _ 0 = pure ()
    waitAll sem n = waitQSem sem >> waitAll sem (n - 1 :: Int)

loadWorkConfig :: FilePath -> IO WorkConfig
loadWorkConfig configPath = do
  exists <- fileExists configPath
  unless exists (failWith 2 ("spool: config file not found: " <> configPath))
  bytes <- BL.readFile configPath
  case parseWorkConfig bytes of
    Left message -> failWith 2 ("spool: " <> message)
    Right config -> do
      checked <- checkExecutables config
      case checked of
        Left message -> failWith 2 ("spool: " <> message)
        Right () -> pure config

parseWorkConfig :: BL.ByteString -> Either String WorkConfig
parseWorkConfig bytes = do
  value <- A.eitherDecode bytes
  case value of
    A.Object object -> do
      rejectUnknown ["max_concurrent", "renew_seconds", "env", "capabilities"] object
      maxConcurrent <- positiveField maxBound "max_concurrent" (Just 1) object
      renewSeconds <- positiveField maxDelaySeconds "renew_seconds" (Just 30) object
      envPairs <- optionalEnvMap object
      capsObject <- requiredObject "capabilities" object
      caps <- traverse (uncurry parseCapabilityEntry) (KM.toList capsObject)
      pure WorkConfig
        { wcMaxConcurrent = maxConcurrent
        , wcRenewSeconds = renewSeconds
        , wcEnv = envPairs
        , wcCapabilities = KM.fromList caps
        }
    _ -> Left "config must be a JSON object"

requiredObject :: T.Text -> Object -> Either String Object
requiredObject key object = case KM.lookup (K.fromText key) object of
  Just (A.Object inner) -> Right inner
  Just _ -> Left (T.unpack key <> " must be an object")
  Nothing -> Left ("config is missing " <> T.unpack key)

-- | A whole number from 1 through `limit`. aeson's bounded decoder does the
-- conversion: it refuses a fraction or a value outside the target type where
-- rounding through Integer would wrap it, and it never expands a huge
-- exponent to find out.
positiveField
  :: (A.FromJSON a, Integral a, Show a)
  => a -> T.Text -> Maybe a -> Object -> Either String a
positiveField limit key def object = case KM.lookup (K.fromText key) object of
  Nothing -> maybe (Left ("missing " <> T.unpack key)) Right def
  Just value@(A.Number _) -> case A.fromJSON value of
    A.Success number | number > 0 && number <= limit -> Right number
    _ -> Left outOfRange
  Just _ -> Left outOfRange
  where
    outOfRange = T.unpack key <> " must be a positive integer no greater than "
      <> show limit

-- | The largest number of seconds whose microseconds still fit the Int that
-- `threadDelay` takes.
maxDelaySeconds :: Int
maxDelaySeconds = maxBound `div` 1000000

optionalEnvMap :: Object -> Either String [(String, String)]
optionalEnvMap object = case KM.lookup "env" object of
  Nothing -> Right []
  Just (A.Object inner) -> traverse envPair (KM.toList inner)
  Just _ -> Left "env must be an object"
  where
    envPair (key, A.String value) = Right (T.unpack (K.toText key), T.unpack value)
    envPair (key, _) = Left ("env." <> T.unpack (K.toText key) <> " must be a string")

optionalArgList :: Object -> Either String [String]
optionalArgList object = case KM.lookup "args" object of
  Nothing -> Right []
  Just (A.Array values) -> traverse asArgString (foldr (:) [] values)
  Just _ -> Left "args must be an array of strings"
  where
    asArgString (A.String value) = Right (T.unpack value)
    asArgString _ = Left "args must be an array of strings"

requiredCapText :: T.Text -> Object -> Either String T.Text
requiredCapText key object = case KM.lookup (K.fromText key) object of
  Just (A.String value) | not (T.null value) -> Right value
  Just (A.String _) -> Left (T.unpack key <> " must be non-empty")
  Just _ -> Left (T.unpack key <> " must be a string")
  Nothing -> Left ("missing " <> T.unpack key)

parseCapabilityEntry :: K.Key -> A.Value -> Either String (K.Key, CapabilityConfig)
parseCapabilityEntry key value = do
  let capText = K.toText key
  validateCapability capText
  case value of
    A.Object object -> do
      rejectUnknown
        ["exec", "args", "timeout_seconds", "max_payload_bytes", "max_output_bytes"]
        object
      execPath <- requiredCapText "exec" object
      unless (isAbsolute (T.unpack execPath))
        (Left (T.unpack capText <> ": exec must be an absolute path"))
      args <- optionalArgList object
      timeoutSeconds <- positiveField maxDelaySeconds "timeout_seconds" Nothing object
      maxPayload <- positiveField maxBound "max_payload_bytes" Nothing object
      maxOutput <- positiveField maxBound "max_output_bytes" Nothing object
      pure (key, CapabilityConfig (T.unpack execPath) args timeoutSeconds maxPayload maxOutput)
    _ -> Left (T.unpack capText <> " must be an object")

checkExecutables :: WorkConfig -> IO (Either String ())
checkExecutables config = go (KM.toList (wcCapabilities config))
  where
    go [] = pure (Right ())
    go ((key, capConfig) : rest) = do
      result <- checkOneExecutable (K.toText key) capConfig
      case result of
        Left message -> pure (Left message)
        Right () -> go rest

checkOneExecutable :: T.Text -> CapabilityConfig -> IO (Either String ())
checkOneExecutable capText capConfig
  | not (isAbsolute (capExec capConfig)) =
      pure (Left (T.unpack capText <> ": exec must be an absolute path"))
  | otherwise = do
      exists <- fileExists (capExec capConfig)
      if not exists
        then pure (Left (T.unpack capText <> ": exec does not exist: " <> capExec capConfig))
        else do
          permissions <- getPermissions (capExec capConfig)
          if executable permissions
            then pure (Right ())
            else pure (Left (T.unpack capText <> ": exec is not executable: " <> capExec capConfig))

encodeWorkConfig :: WorkConfig -> BL.ByteString
encodeWorkConfig config = canonical (A.object
  [ "max_concurrent" .= wcMaxConcurrent config
  , "renew_seconds" .= wcRenewSeconds config
  , "env" .= KM.fromList [ (K.fromText (T.pack k), A.toJSON v) | (k, v) <- wcEnv config ]
  , "capabilities" .= KM.fromList
      [ (key, encodeCapabilityConfig capConfig) | (key, capConfig) <- KM.toList (wcCapabilities config) ]
  ])

encodeCapabilityConfig :: CapabilityConfig -> A.Value
encodeCapabilityConfig capConfig = A.object
  [ "exec" .= capExec capConfig
  , "args" .= capArgs capConfig
  , "timeout_seconds" .= capTimeoutSeconds capConfig
  , "max_payload_bytes" .= capMaxPayloadBytes capConfig
  , "max_output_bytes" .= capMaxOutputBytes capConfig
  ]

-- | Run one already-leased task to completion: refuse it outright if its
-- capability or payload size fails the configuration's rules, otherwise
-- run the mapped executable and ack or fail the lease with the result.
runOneLease :: Paths -> WorkConfig -> Lease -> IO ()
runOneLease paths config lease = do
  let task = leaseTask lease
      leaseIdent = leaseId lease
      worker = leaseWorker lease
      capText = taskCapability task
  case KM.lookup (K.fromText capText) (wcCapabilities config) of
    Nothing -> completeFailure paths (taskId task) leaseIdent
      ("capability " <> capText <> " is not in the worker configuration") False
    Just capConfig -> do
      let payloadBytes = canonical (taskPayload task)
      if BL.length payloadBytes > capMaxPayloadBytes capConfig
        then completeFailure paths (taskId task) leaseIdent
          ("payload of " <> T.pack (show (BL.length payloadBytes))
            <> " bytes exceeds max_payload_bytes " <> T.pack (show (capMaxPayloadBytes capConfig)))
          False
        else runExecutable paths config task leaseIdent worker capConfig payloadBytes

runExecutable
  :: Paths -> WorkConfig -> Task -> T.Text -> T.Text -> CapabilityConfig -> BL.ByteString -> IO ()
runExecutable paths config task leaseIdent worker capConfig payloadBytes = do
  tempDir <- freshTempDir
  renewalFailure <- newEmptyMVar
  renewalThreadId <- forkIO
    (renewalLoop paths (taskId task) leaseIdent (wcRenewSeconds config)
      renewalFailure)
  outcome <- (do
      receiveTaskAttachments paths task tempDir
      runCapability capConfig (wcEnv config) tempDir payloadBytes)
    `finally` (killThread renewalThreadId >> removeWorkerDirectory tempDir)
  renewalError <- tryReadMVar renewalFailure
  case renewalError of
    Just message -> throwFailure (SpoolFailure 4
      ("work: renewal failed: " <> message))
    Nothing -> case outcome of
      RunFailure reason -> completeFailure paths (taskId task) leaseIdent reason True
      RunSuccess stdoutBytes -> case A.eitherDecode stdoutBytes of
        Left _ -> completeFailure paths (taskId task) leaseIdent "output is not JSON" True
        Right outputValue -> completeSuccess paths task leaseIdent worker outputValue

receiveTaskAttachments :: Paths -> Task -> FilePath -> IO ()
receiveTaskAttachments paths task tempDir = do
  let workerAttachmentRoot = tempDir </> "attachments"
  forM_ (taskAttachments task) $ \attachment -> do
    source <- either (throwFailure . SpoolFailure 70) pure
      (SA.attachmentPath (attachmentsDir paths) (taskId task) attachment)
    bracket (openBinaryFile source ReadMode) hClose $ \handle -> do
      received <- SA.receiveAttachment workerAttachmentRoot attachment handle
      case received of
        Left message -> throwFailure (SpoolFailure 70
          ("attachment verification failed for " <> T.unpack (taskId task)
            <> ": " <> message))
        Right () -> pure ()

removeWorkerDirectory :: FilePath -> IO ()
removeWorkerDirectory directory = do
  removed <- SA.attemptRemoveWorkerDirectory directory
  case removed of
    Left exception -> ioError exception
    Right () -> pure ()

renewalLoop :: Paths -> T.Text -> T.Text -> Int -> MVar String -> IO ()
renewalLoop paths taskIdent leaseIdent renewSeconds failure = do
  threadDelay (renewSeconds * 1000000)
  result <- withLock paths (renewOne paths taskIdent leaseIdent)
  case result of
    Right () -> renewalLoop paths taskIdent leaseIdent renewSeconds failure
    Left message -> putMVar failure message

completeSuccess :: Paths -> Task -> T.Text -> T.Text -> A.Value -> IO ()
completeSuccess paths task leaseIdent _worker output = withLock paths $ do
  result <- ackOne paths (taskId task) leaseIdent output
  case result of
    Left message -> throwFailure (SpoolFailure 4 ("work: " <> message))
    Right _ -> pure ()

completeFailure :: Paths -> T.Text -> T.Text -> T.Text -> Bool -> IO ()
completeFailure paths taskIdent leaseIdent reason retry = withLock paths $ do
  result <- failLease paths taskIdent leaseIdent reason retry
  case result of
    Left message -> throwFailure (SpoolFailure 4 ("work: " <> message))
    Right _ -> pure ()

freshTempDir :: IO FilePath
freshTempDir = do
  base <- getTemporaryDirectory
  micros <- epochMicros
  unique <- hashUnique <$> newUnique
  let path = base </> ("spool-work-" <> show micros <> "-" <> show unique)
  createDirectoryIfMissing True path
  pure path

-- | How long a run that has been sent SIGTERM may keep going before it is
-- sent SIGKILL.
terminationGraceSeconds :: Int
terminationGraceSeconds = 5

-- | Run one capability executable with the given environment, cwd, and
-- stdin payload. It runs in its own process group (`create_group`), killed
-- (and reporting a timeout) if it outlives `capTimeoutSeconds`, or (and
-- reporting an overrun) if either stream's captured output outlives
-- `capMaxOutputBytes`. Killing the group, not just the immediate process,
-- reaches a descendant that would otherwise survive and keep the pipes
-- open. The kill is SIGTERM first; a program may ignore that, so one still
-- running `terminationGraceSeconds` later is sent SIGKILL, which it cannot.
runCapability :: CapabilityConfig -> [(String, String)] -> FilePath -> BL.ByteString -> IO RunOutcome
runCapability capConfig envPairs cwdPath payload = do
  (Just hin, Just hout, Just herr, ph) <- createProcess (proc (capExec capConfig) (capArgs capConfig))
    { cwd = Just cwdPath
    , env = Just envPairs
    , std_in = CreatePipe
    , std_out = CreatePipe
    , std_err = CreatePipe
    , create_group = True
    }
  inputResult <- try (BL.hPut hin payload >> hClose hin)
    :: IO (Either IOException ())
  -- The watchdog and both readers can each ask for the kill; the first
  -- request wins and the terminator carries it out once. The child may exit
  -- between a limit firing and a signal. That process race is the only
  -- error intentionally ignored here.
  killRequested <- newEmptyMVar
  terminator <- forkIO $ do
    takeMVar killRequested
    ignoreProcessRace (signalGroup sigTERM ph)
    threadDelay (terminationGraceSeconds * 1000000)
    ignoreProcessRace (signalGroup sigKILL ph)
  let limit = capMaxOutputBytes capConfig
      kill = void (tryPutMVar killRequested ())
  outVar <- newEmptyMVar
  errVar <- newEmptyMVar
  outputExceeded <- newIORef False
  _ <- forkIO (readerThread limit outputExceeded kill hout outVar)
  _ <- forkIO (readerThread limit outputExceeded kill herr errVar)
  timedOut <- newIORef False
  watchdog <- forkIO $ do
    threadDelay (capTimeoutSeconds capConfig * 1000000)
    writeIORef timedOut True
    kill
  exitCode <- waitForProcess ph
  killThread watchdog
  killThread terminator
  outResult <- readMVar outVar
  errResult <- readMVar errVar
  outBytes <- either ioError pure outResult
  errBytes <- either ioError pure errResult
  isTimeout <- readIORef timedOut
  isOutputExceeded <- readIORef outputExceeded
  pure $ case inputResult of
    Left exception -> RunFailure
      ("could not write payload: " <> T.pack (displayException exception))
    Right () | isTimeout ->
      RunFailure ("timeout after " <> T.pack (show (capTimeoutSeconds capConfig)) <> " s")
    Right () | isOutputExceeded ->
      RunFailure ("output exceeds max_output_bytes " <> T.pack (show limit))
    Right () -> case exitCode of
      ExitSuccess -> RunSuccess (BL.fromStrict outBytes)
      ExitFailure n -> RunFailure
        ("exit " <> T.pack (show n) <> ": " <> decodeLenient (tailBytes 1000 errBytes))

-- | Send a signal to the negative of the child's pid, i.e. every process in
-- its group, not just the one Spool exec'd. `getPid` returns Nothing once
-- the process handle has already been reaped, which this treats as nothing
-- left to signal.
signalGroup :: Signal -> ProcessHandle -> IO ()
signalGroup signal ph = do
  running <- getPid ph
  case running of
    Nothing -> pure ()
    Just pid -> signalProcess signal (negate pid)

readerThread
  :: Int64 -> IORef Bool -> IO () -> Handle -> MVar (Either IOException BS.ByteString) -> IO ()
readerThread limit exceededRef kill handle var = do
  result <- try (readCapped limit exceededRef kill handle) :: IO (Either IOException BS.ByteString)
  putMVar var result

-- | Read a handle to EOF in chunks, stopping (and killing the process) the
-- moment the total exceeds `limit`, so a capability that writes without
-- bound cannot grow the worker's memory without bound either.
readCapped :: Int64 -> IORef Bool -> IO () -> Handle -> IO BS.ByteString
readCapped limit exceededRef kill handle = go [] 0
  where
    chunkSize = 65536
    go chunks total = do
      chunk <- BS.hGetSome handle chunkSize
      if BS.null chunk
        then pure (BS.concat (reverse chunks))
        else do
          let total' = total + fromIntegral (BS.length chunk)
              chunks' = chunk : chunks
          if total' > limit
            then do
              writeIORef exceededRef True
              kill
              pure (BS.concat (reverse chunks'))
            else go chunks' total'

tailBytes :: Int -> BS.ByteString -> BS.ByteString
tailBytes n bytes = BS.drop (max 0 (BS.length bytes - n)) bytes

decodeLenient :: BS.ByteString -> T.Text
decodeLenient = TE.decodeUtf8With TEE.lenientDecode
