{-# LANGUAGE OverloadedStrings #-}

-- | The task lifecycle: pending -> leased -> done|failed.
--
-- Payloads are opaque JSON. A lease is a filename transition; the lease id
-- remains in the filename so an old worker cannot acknowledge a newer lease
-- after reclaim. Two non-.json sidecars ride next to a leased task file:
-- "<lease>.worker" (the leasing worker, written once) and "<lease>.renewed"
-- (the last renewal's epoch microseconds, rewritten on every renew). Neither
-- is a task file, so the pending/leased/done scan (which only looks at
-- ".json" names) never sees them.
module Spool.Store
  ( withStore
  , recoverAttachmentState
  , putTasks
  , readTaskFile
  , readResultRecordFile
  , readWorkerSidecar
  , removeSidecars
  , leaseIdOfFile
  , leaseTasks
  , leaseUpTo
  , ackTasks
  , ackAll
  , ackOne
  , renewTasks
  , renewAll
  , renewOne
  , failTasks
  , failAll
  , failLease
  , returnToPending
  , failuresCommand
  , resultsCommand
  , fetchAttachment
  , fetchFor
  , reclaimTasks
  , statusTasks
  ) where

import Control.Exception (IOException, displayException, throwIO, try)
import Control.Monad (foldM, forM, forM_, unless, when)
import qualified Data.Aeson as A
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.List (sortOn)
import Data.Maybe (listToMaybe)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (getCurrentTime)
import System.Directory (listDirectory, removeDirectoryRecursive, removeFile,
                         removePathForcibly, renameDirectory, renameFile)
import System.FilePath (takeBaseName, (</>))
import System.IO (IOMode (ReadMode), withBinaryFile)
import System.IO.Error (isDoesNotExistError)
import qualified Spool.Attachments as SA
import Spool.Error
  ( SpoolError (..)
  , conflict
  , corrupt
  , malformed
  , orThrow
  , report
  , retryable
  , stale
  )
import Spool.Files
  ( Created (..)
  , Paths
  , atomicCreate
  , attachmentCleanupDir
  , attachmentsDir
  , doneDir
  , failedDir
  , leasedDir
  , pendingDir
  , resultsDir
  , rootDir
  , atomicReplace
  , donePath
  , epochMicros
  , failedPath
  , fileExists
  , ignoreMissing
  , initialise
  , jsonFiles
  , leasedPath
  , openSpool
  , pendingPath
  , renewedSidecarPath
  , resultPath
  , withLock
  , workerSidecarPath
  )
import Spool.Input
  ( inputLines
  , parseAckLine
  , parseFailLine
  , parseLeaseRefLine
  , parseTaskLine
  )
import Spool.Types
  ( LeaseId
  , Retry (..)
  , StatusFormat (..)
  , TaskId
  , WorkerName
  , leaseIdText
  , leaseStarted
  , mkLeaseId
  , mkTaskId
  , mkWorkerName
  , newLeaseId
  , taskIdText
  , timestamp
  , workerNameText
  )
import Spool.Wire
  ( Ack (..)
  , AckStatus (..)
  , Counts (..)
  , FailRequest (..)
  , FailureRecord (..)
  , FetchRequest (..)
  , Lease (..)
  , LeaseRef (..)
  , PutStatus (..)
  , ResultRecord (..)
  , Task (..)
  , encode
  , encodeAckResult
  , encodeFailResult
  , encodePutResult
  , encodeReclaimResult
  , encodeRenewResult
  , parseFailureRecord
  , parseFetchRequest
  , parseResultRecord
  , parseTask
  , readInteger
  )

withStore :: FilePath -> (Paths -> IO ()) -> IO ()
withStore directory action = do
  paths <- openSpool directory
  initialise paths
  withLock paths (recoverAttachmentState paths >> action paths)

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
    if SA.isStagingLeftover name
      then removePathForcibly (attachmentsDir paths </> name)
      else case T.stripPrefix "task-" (T.pack name) of
        Just owner -> do
          ident <- orThrow corrupt (mkTaskId owner)
          when (ident `notElem` active) (tombstoneAndDelete paths ident)
        Nothing -> throwIO (corrupt
          ("unexpected entry in attachment store: " <> name))

tombstoneAndDelete :: Paths -> TaskId -> IO ()
tombstoneAndDelete paths ident = do
  let source = SA.attachmentDirectory (attachmentsDir paths) ident
      target = SA.attachmentDirectory (attachmentCleanupDir paths) ident
  present <- fileExists source
  when present $ do
    renameDirectory source target
    removeDirectoryRecursive target

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
    Just SameTask -> pure PutExisting
    Just OtherTask -> throwIO different
    Nothing -> do
      stageTaskAttachments paths sourceDirectory task
      created <- atomicCreate (pendingPath paths (taskId task)) (encode task)
      case created of
        Created -> pure PutInserted
        AlreadyThere -> do
          retry <- findTask paths task
          case retry of
            Just SameTask -> pure PutExisting
            Just OtherTask -> throwIO different
            Nothing -> throwIO (retryable "could not create pending task")
  where
    different = conflict
      ("task " <> showTask (taskId task) <> " already exists with different content")

stageTaskAttachments :: Paths -> Maybe FilePath -> Task -> IO ()
stageTaskAttachments _ _ task | null (taskAttachments task) = pure ()
stageTaskAttachments _ Nothing _ = throwIO (malformed
  "tasks declaring attachments require put --attachments DIR")
stageTaskAttachments paths (Just sourceDirectory) task =
  orThrow malformed =<< SA.stageAttachments (attachmentsDir paths) sourceDirectory
    (taskId task) (taskAttachments task)

-- | What the spool already holds under a task's identifier.
data Found
  = SameTask   -- ^ an equal task
  | OtherTask  -- ^ the identifier, with different content
  deriving (Eq, Show)

-- | The leased and done directories are intentionally scanned because their
-- filenames are coordination tokens, not task ids.
findTask :: Paths -> Task -> IO (Maybe Found)
findTask paths wanted = do
  pending <- comparePath (pendingPath paths (taskId wanted)) wanted
  done <- compareFiles (doneDir paths) wanted
  leased <- compareFiles (leasedDir paths) wanted
  pure (listToMaybe [found | Just found <- [pending, done, leased]])

comparePath :: FilePath -> Task -> IO (Maybe Found)
comparePath path wanted = do
  exists <- fileExists path
  if not exists then pure Nothing else Just . compareTask wanted <$> readTaskFile path

compareFiles :: FilePath -> Task -> IO (Maybe Found)
compareFiles directory wanted = do
  files <- jsonFiles directory
  results <- forM files $ \path -> do
    task <- readTaskFile path
    pure $ if taskId task == taskId wanted
      then Just (compareTask wanted task)
      else Nothing
  pure (listToMaybe [found | Just found <- results])

compareTask :: Task -> Task -> Found
compareTask wanted held = if held == wanted then SameTask else OtherTask

equalTaskFile :: FilePath -> Task -> IO Bool
equalTaskFile path wanted = (== wanted) <$> readTaskFile path

readTaskFile :: FilePath -> IO Task
readTaskFile path = do
  bytes <- readWhole path
  case parseTask bytes of
    Left message -> throwIO (corrupt
      ("corrupt task file " <> path <> ": " <> message))
    Right task -> pure task

readFailureRecordFile :: FilePath -> IO FailureRecord
readFailureRecordFile path = do
  bytes <- readWhole path
  case parseFailureRecord bytes of
    Left message -> throwIO (corrupt
      ("corrupt failure record " <> path <> ": " <> message))
    Right value -> pure value

readResultRecordFile :: FilePath -> IO ResultRecord
readResultRecordFile path = do
  bytes <- readWhole path
  case parseResultRecord bytes of
    Left message -> throwIO (corrupt
      ("corrupt result record " <> path <> ": " <> message))
    Right value -> pure value

-- | The bytes of a file, all read and the file closed before any is looked
-- at, so that a record can be moved or removed as soon as it has been read.
readWhole :: FilePath -> IO BL.ByteString
readWhole path = BL.fromStrict <$> BS.readFile path

-- | The one number a file holds, or nothing if that is not what it holds.
readNumber :: FilePath -> IO (Maybe Integer)
readNumber path = do
  bytes <- BS.readFile path
  pure $ case TE.decodeUtf8' bytes of
    Left _ -> Nothing
    Right text -> readInteger (T.strip text)

-- Sidecars: a lease's worker (written once, as UTF-8) and its last renewal
-- (rewritten on every renew). Neither has a ".json" extension, so jsonFiles
-- never returns them.
writeWorkerSidecar :: Paths -> LeaseId -> WorkerName -> IO ()
writeWorkerSidecar paths leaseIdent worker = do
  created <- atomicCreate (workerSidecarPath paths leaseIdent)
    (BL.fromStrict (TE.encodeUtf8 (workerNameText worker)))
  when (created == AlreadyThere) (throwIO (corrupt
    ("worker sidecar already exists for " <> showLease leaseIdent)))

readWorkerSidecar :: Paths -> LeaseId -> IO WorkerName
readWorkerSidecar paths leaseIdent = do
  let path = workerSidecarPath paths leaseIdent
  exists <- fileExists path
  if not exists
    then throwIO (corrupt
      ("leased task has no worker sidecar: " <> showLease leaseIdent))
    else do
      bytes <- BS.readFile path
      case mkWorkerName . T.strip =<< decoded bytes of
        Left _ -> throwIO (corrupt
          ("corrupt worker sidecar for " <> showLease leaseIdent))
        Right worker -> pure worker
  where
    decoded = either (const (Left "not UTF-8")) Right . TE.decodeUtf8'

writeRenewedSidecar :: Paths -> LeaseId -> Integer -> IO ()
writeRenewedSidecar paths leaseIdent micros =
  atomicReplace (renewedSidecarPath paths leaseIdent) (BLC.pack (show micros))

readRenewedSidecar :: Paths -> LeaseId -> IO (Maybe Integer)
readRenewedSidecar paths leaseIdent = do
  let path = renewedSidecarPath paths leaseIdent
  exists <- fileExists path
  if not exists
    then pure Nothing
    else do
      value <- readNumber path
      case value of
        Just micros -> pure (Just micros)
        Nothing -> throwIO (corrupt
          ("corrupt renewal sidecar for " <> showLease leaseIdent))

removeSidecars :: Paths -> LeaseId -> IO ()
removeSidecars paths leaseIdent = do
  ignoreMissing (removeFile (workerSidecarPath paths leaseIdent))
  ignoreMissing (removeFile (renewedSidecarPath paths leaseIdent))

-- | The lease a file in the leased directory holds, which is its name.
leaseIdOfFile :: FilePath -> IO LeaseId
leaseIdOfFile path = case mkLeaseId (T.pack (takeBaseName path)) of
  Right leaseIdent -> pure leaseIdent
  Left _ -> throwIO (corrupt ("corrupt lease filename: " <> path))

leaseTasks :: Paths -> WorkerName -> Int -> IO ()
leaseTasks paths worker count = do
  leased <- leaseUpTo paths worker count
  when (null leased) (throwIO NothingPending)
  forM_ leased (BLC.putStrLn . encode)

-- | Lease up to `count` pending tasks for `worker`. Used by both the CLI
-- `lease` command and the `work` loop (with count 1). Returns fewer than
-- `count` (possibly none) when pending is exhausted.
leaseUpTo :: Paths -> WorkerName -> Int -> IO [Lease]
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
          let lease = Lease task leaseIdent worker (timestamp now)
          moved <- try (renameFile path (leasedPath paths leaseIdent))
            :: IO (Either IOException ())
          case moved of
            Left exception
              | isDoesNotExistError exception ->
                  leaseMany rest active remaining output
              | otherwise -> throwIO (retryable
                  ("could not lease " <> path <> ": " <> displayException exception))
            Right () -> do
              writeWorkerSidecar paths leaseIdent worker
              leaseMany rest (taskId task : active) (remaining - 1) (lease : output)

activeTaskIds :: Paths -> IO [TaskId]
activeTaskIds paths = do
  files <- jsonFiles (leasedDir paths)
  mapM (fmap taskId . readTaskFile) files

uniqueLeaseId :: Paths -> Integer -> TaskId -> IO LeaseId
uniqueLeaseId paths micros ident = do
  serial <- nextLeaseSerial paths
  pure (newLeaseId micros serial ident)

nextLeaseSerial :: Paths -> IO Integer
nextLeaseSerial paths = do
  let path = rootDir paths </> ".lease-sequence"
  present <- fileExists path
  current <- if present then readNumber path else pure (Just 0)
  case current of
    Nothing -> throwIO (corrupt "corrupt lease sequence")
    Just value -> do
      let next = value + 1
      atomicReplace path (BLC.pack (show next <> "\n"))
      pure next

-- | Apply one transition to each of these, in order. A lease that is stale
-- is reported and the ones after it still run; the command then ends as
-- stale. Anything else that goes wrong ends the command where it happens.
forEach :: (a -> IO (Either SpoolError BL.ByteString)) -> [a] -> IO ()
forEach step items = do
  refused <- foldM one False items
  when refused (throwIO (stale "one or more leases were stale or unknown"))
  where
    one hadRefusal item = do
      result <- step item
      case result of
        Left failure -> report failure >> pure True
        Right reply -> BLC.putStrLn reply >> pure hadRefusal

-- A command reads its lines one at a time, so a line is applied before the
-- next is read, and a malformed line stops the command with the lines
-- before it already applied. The remote command reads every line before it
-- applies any, because it checks who owns each lease first; it uses the
-- forms that take what it has already read.

ackTasks :: Paths -> IO ()
ackTasks paths = inputLines >>= forEach (\line -> parseAckLine line >>= ackStep paths)

ackAll :: Paths -> [Ack] -> IO ()
ackAll paths = forEach (ackStep paths)

ackStep :: Paths -> Ack -> IO (Either SpoolError BL.ByteString)
ackStep paths ack =
  fmap (encodeAckResult (refTask (ackRef ack)))
    <$> ackOne paths (ackRef ack) (ackResult ack)

ackOne :: Paths -> LeaseRef -> A.Value -> IO (Either SpoolError AckStatus)
ackOne paths (LeaseRef ident leaseIdent) output = do
  let source = leasedPath paths leaseIdent
  sourceExists <- fileExists source
  if sourceExists
    then do
      task <- readTaskFile source
      if taskId task /= ident
        then pure (Left (stale "lease does not belong to task_id"))
        else do
          worker <- readWorkerSidecar paths leaseIdent
          stored <- writeResultRecord paths task leaseIdent worker output
          case stored of
            Left failure -> pure (Left failure)
            Right () -> do
              moved <- try (renameFile source (donePath paths leaseIdent))
                :: IO (Either IOException ())
              case moved of
                Right () -> do
                  removeSidecars paths leaseIdent
                  tombstoneAndDelete paths (taskId task)
                  pure (Right Acked)
                Left exception
                  | isDoesNotExistError exception -> do
                      done <- findDoneLease paths ident leaseIdent
                      doneResult paths leaseIdent output done
                  | otherwise -> throwIO (retryable
                      ("could not move leased task to done: "
                        <> displayException exception))
    else do
      done <- findDoneLease paths ident leaseIdent
      doneResult paths leaseIdent output done

-- | How a task that is done relates to the lease a caller named.
data DoneUnder
  = ThisLease     -- ^ it was done under that lease
  | AnotherLease  -- ^ it was done under a later one
  deriving (Eq, Show)

doneResult :: Paths -> LeaseId -> A.Value -> Maybe DoneUnder
           -> IO (Either SpoolError AckStatus)
doneResult paths leaseIdent output done = case done of
  Just ThisLease -> do
    same <- completedResultMatches paths leaseIdent output
    pure $ if same
      then Right AlreadyDone
      else Left (stale "ack result differs from completed result")
  Just AnotherLease -> pure (Left (stale "lease is stale"))
  Nothing -> pure (Left (stale "lease is unknown or stale"))

completedResultMatches :: Paths -> LeaseId -> A.Value -> IO Bool
completedResultMatches paths leaseIdent output = do
  let path = resultPath paths leaseIdent
  present <- fileExists path
  unless present (throwIO (retryable
    ("completed lease has no result: " <> showLease leaseIdent)))
  stored <- readResultRecordFile path
  pure (resultValue stored == output)

findDoneLease :: Paths -> TaskId -> LeaseId -> IO (Maybe DoneUnder)
findDoneLease paths ident leaseIdent = do
  files <- jsonFiles (doneDir paths)
  matches <- forM files $ \path -> do
    task <- readTaskFile path
    pure $ if taskId task /= ident then Nothing
      else Just (if takeBaseName path == showLease leaseIdent
        then ThisLease
        else AnotherLease)
  pure (listToMaybe [found | Just found <- matches])

renewTasks :: Paths -> IO ()
renewTasks paths =
  inputLines >>= forEach (\line -> parseLeaseRefLine line >>= renewStep paths)

renewAll :: Paths -> [LeaseRef] -> IO ()
renewAll paths = forEach (renewStep paths)

renewStep :: Paths -> LeaseRef -> IO (Either SpoolError BL.ByteString)
renewStep paths reference =
  fmap (const (encodeRenewResult (refTask reference))) <$> renewOne paths reference

renewOne :: Paths -> LeaseRef -> IO (Either SpoolError ())
renewOne paths (LeaseRef ident leaseIdent) = do
  let source = leasedPath paths leaseIdent
  exists <- fileExists source
  if not exists
    then pure (Left (stale "lease is unknown or stale"))
    else do
      task <- readTaskFile source
      if taskId task /= ident
        then pure (Left (stale "lease does not belong to task_id"))
        else do
          micros <- epochMicros
          writeRenewedSidecar paths leaseIdent micros
          pure (Right ())

failTasks :: Retry -> Paths -> IO ()
failTasks retry paths =
  inputLines >>= forEach (\line -> parseFailLine line >>= failStep retry paths)

failAll :: Retry -> Paths -> [FailRequest] -> IO ()
failAll retry paths = forEach (failStep retry paths)

failStep :: Retry -> Paths -> FailRequest -> IO (Either SpoolError BL.ByteString)
failStep retry paths request =
  fmap (const (encodeFailResult (refTask (failRef request)) retry))
    <$> failLease paths (failRef request) (failReason request) retry

-- | Move a leased task to failed/, recording why, and (with retry) put an
-- identical task back in pending/. Shared by the CLI `fail` command and the
-- `work` loop's failure paths.
failLease :: Paths -> LeaseRef -> T.Text -> Retry -> IO (Either SpoolError ())
failLease paths (LeaseRef ident leaseIdent) reason retry = do
  let source = leasedPath paths leaseIdent
  exists <- fileExists source
  if not exists
    then pure (Left (stale "lease is unknown or stale"))
    else do
      task <- readTaskFile source
      if taskId task /= ident
        then pure (Left (stale "lease does not belong to task_id"))
        else do
          worker <- readWorkerSidecar paths leaseIdent
          stored <- writeFailureRecord paths task leaseIdent worker reason retry
          case stored of
            Left failure -> pure (Left failure)
            Right () -> do
              when (retry == Retry) (returnToPending paths task)
              removeFile source
              removeSidecars paths leaseIdent
              when (retry == NoRetry) (tombstoneAndDelete paths (taskId task))
              pure (Right ())

-- | Record a failure once. A record already there belongs to a fail that was
-- interrupted before it removed the lease: the same reason and retry choice
-- finish that fail, and anything else is refused, as a differing result is
-- for ack.
writeFailureRecord
  :: Paths -> Task -> LeaseId -> WorkerName -> T.Text -> Retry
  -> IO (Either SpoolError ())
writeFailureRecord paths task leaseIdent worker reason retry = do
  now <- getCurrentTime
  let record = FailureRecord
        { failureTask = taskId task
        , failureLease = leaseIdent
        , failureCapability = taskCapability task
        , failureWorker = worker
        , failureFailedAt = timestamp now
        , failureReason = reason
        , failureRetried = retry
        }
      path = failedPath paths leaseIdent
  created <- atomicCreate path (encode record)
  case created of
    Created -> pure (Right ())
    AlreadyThere -> do
      existing <- readFailureRecordFile path
      pure $ if failureReason existing == reason && failureRetried existing == retry
        then Right ()
        else Left (stale
          "fail differs from the failure already recorded for this lease")

-- | Recreate a task in pending/, exactly as reclaim does: idempotent if an
-- equal task is already there, a hard failure if a conflicting one is.
returnToPending :: Paths -> Task -> IO ()
returnToPending paths task = do
  let path = pendingPath paths (taskId task)
  present <- fileExists path
  if present
    then do
      same <- equalTaskFile path task
      unless same (throwIO (conflict
        ("pending task conflicts with returned lease for " <> showTask (taskId task))))
    else do
      created <- atomicCreate path (encode task)
      when (created == AlreadyThere) $ do
        same <- equalTaskFile path task
        unless same (throwIO (conflict
          ("could not return task " <> showTask (taskId task))))

failuresCommand :: Paths -> IO ()
failuresCommand paths = do
  files <- jsonFiles (failedDir paths)
  records <- mapM readFailureRecordFile files
  mapM_ (BLC.putStrLn . encode) (sortOn failureFailedAt records)

resultsCommand :: Paths -> IO ()
resultsCommand paths = do
  files <- jsonFiles (resultsDir paths)
  records <- mapM readResultRecordFile files
  mapM_ (BLC.putStrLn . encode) (sortOn resultFinishedAt records)

fetchAttachment :: Paths -> IO ()
fetchAttachment paths =
  BL.getContents >>= orThrow malformed . parseFetchRequest >>= fetchFor paths

-- | Write one verified attachment to stdout, for a request already read.
fetchFor :: Paths -> FetchRequest -> IO ()
fetchFor paths (FetchRequest (LeaseRef ident leaseIdent) digest) = do
  let leasePath = leasedPath paths leaseIdent
  present <- fileExists leasePath
  unless present (throwIO (stale "lease is unknown or stale"))
  task <- readTaskFile leasePath
  unless (taskId task == ident)
    (throwIO (stale "lease does not belong to task_id"))
  attachment <- case
      [declaration | declaration <- taskAttachments task,
        SA.attachmentSha256 declaration == digest] of
    declaration : _ -> pure declaration
    [] -> throwIO (malformed "attachment is not declared by the task")
  let path = SA.attachmentPath (attachmentsDir paths) ident attachment
  verified <- SA.verifyAttachmentFile attachment path
  case verified of
    Left message -> throwIO (corrupt
      ("corrupt attachment for " <> showTask ident <> ": " <> message))
    Right () -> withBinaryFile path ReadMode copyToOutput
  where
    copyToOutput handle = do
      chunk <- BS.hGetSome handle 65536
      unless (BS.null chunk) (BS.putStr chunk >> copyToOutput handle)

writeResultRecord
  :: Paths -> Task -> LeaseId -> WorkerName -> A.Value -> IO (Either SpoolError ())
writeResultRecord paths task leaseIdent worker output = do
  now <- getCurrentTime
  let record = ResultRecord
        { resultTask = taskId task
        , resultLease = leaseIdent
        , resultCapability = taskCapability task
        , resultWorker = worker
        , resultFinishedAt = timestamp now
        , resultValue = output
        }
  created <- atomicCreate (resultPath paths leaseIdent) (encode record)
  case created of
    Created -> pure (Right ())
    AlreadyThere -> do
      same <- completedResultMatches paths leaseIdent output
      pure $ if same
        then Right ()
        else Left (stale
          "ack result differs from the result already stored for this lease")

reclaimTasks :: Paths -> Integer -> IO ()
reclaimTasks paths age = do
  now <- epochMicros
  files <- jsonFiles (leasedDir paths)
  forM_ files $ \path -> do
    leaseIdent <- leaseIdOfFile path
    case leaseStarted leaseIdent of
      Nothing -> throwIO (corrupt ("corrupt lease filename: " <> path))
      Just started -> do
        renewed <- readRenewedSidecar paths leaseIdent
        let effective = maybe started (max started) renewed
        when (now - effective >= age * 1000000) (reclaimOne paths path leaseIdent)

reclaimOne :: Paths -> FilePath -> LeaseId -> IO ()
reclaimOne paths leasedFile leaseIdent = do
  task <- readTaskFile leasedFile
  returnToPending paths task
  removeFile leasedFile
  removeSidecars paths leaseIdent
  BLC.putStrLn (encodeReclaimResult (taskId task))

statusTasks :: Paths -> StatusFormat -> IO ()
statusTasks paths format = do
  counts <- Counts
    <$> count (pendingDir paths)
    <*> count (leasedDir paths)
    <*> count (doneDir paths)
    <*> count (failedDir paths)
  case format of
    StatusJson -> BLC.putStrLn (encode counts)
    StatusText -> putStrLn
      ("pending=" <> show (countPending counts)
        <> " leased=" <> show (countLeased counts)
        <> " done=" <> show (countDone counts)
        <> " failed=" <> show (countFailed counts))
  where
    count directory = length <$> jsonFiles directory

showTask :: TaskId -> String
showTask = T.unpack . taskIdText

showLease :: LeaseId -> String
showLease = T.unpack . leaseIdText
