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
  , recover
  , putTasks
  , readTaskFile
  , readResultRecordFile
  , readWorkerSidecar
  , liveLeaseOwned
  , removeSidecars
  , leaseIdOfFile
  , leaseTasks
  , leaseUpTo
  , answerEach
  , ackTasks
  , ackStep
  , ackOne
  , checkStaged
  , renewTasks
  , renewStep
  , renewOne
  , failTasks
  , failStep
  , failLease
  , failOne
  , returnToPending
  , abandonLease
  , retryCap
  , attemptsBefore
  , failuresCommand
  , resultsCommand
  , fetchAttachment
  , Sender (..)
  , fitsLimit
  , Room (..)
  , roomFor
  , sendCommand
  , sendFrom
  , takeCommand
  , reclaimTasks
  , collectTasks
  , gcTasks
  , statusTasks
  ) where

import Control.Exception (IOException, displayException, finally, onException,
                          throwIO, try)
import Control.Monad (foldM, forM, forM_, unless, when)
import qualified Data.Aeson as A
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.Char (isDigit)
import Data.Int (Int64)
import Data.List (isSuffixOf, sortOn, stripPrefix)
import qualified Data.Map.Strict as Map
import Data.Maybe (listToMaybe)
import qualified Data.Set as Set
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import System.Directory (createDirectory, listDirectory, removeFile)
import System.FilePath (takeBaseName, (</>))
import System.IO (Handle, IOMode (ReadMode), SeekMode (AbsoluteSeek), hClose,
                  hSeek, hSetBinaryMode, openBinaryFile, openBinaryTempFile,
                  stdin)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (fileSize, getFileStatus)
import qualified Spool.Attachments as SA
import Spool.Error
  ( SpoolError (..)
  , conflict
  , corrupt
  , malformed
  , neverFits
  , orThrow
  , overLimit
  , report
  , retryable
  , stale
  )
import Spool.Files
  ( Created (..)
  , Paths
  , atomicCreate
  , attachmentCleanupDir
  , createMarker
  , layoutPath
  , taskCleanupDir
  , taskCleanupPath
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
  , resultLeaseDir
  , resultLeasesDir
  , resultTaskDir
  , resultTasksDir
  , syncDirectory
  , syncHandle
  , syncedRemove
  , syncedRemoveDirectory
  , syncedRename
  , syncedRenameDirectory
  , withLock
  , workerSidecarPath
  )
import Spool.Input
  ( inputLines
  , parseAckLine
  , parseCollectLine
  , parseFailLine
  , parseLeaseRefLine
  , parseTaskLine
  )
import Spool.Types
  ( LeaseId
  , Retry (..)
  , StatusFormat (..)
  , leaseSerialAndTask
  , TaskId
  , WorkerName
  , leaseIdText
  , leaseSerialAndTask
  , leaseStarted
  , mkLeaseId
  , mkTaskId
  , mkWorkerName
  , newLeaseId
  , taskIdText
  , timestamp
  , timestampTime
  , workerNameText
  )
import Spool.Wire
  ( Ack (..)
  , AckStatus (..)
  , CollectStatus (..)
  , Counts (..)
  , FailRequest (..)
  , FailureRecord (..)
  , FetchRequest (..)
  , Lease (..)
  , SendRequest (..)
  , TakeRequest (..)
  , LeaseRef (..)
  , PutStatus (..)
  , ResultRecord (..)
  , Task (..)
  , encode
  , encodeAckResult
  , encodeCollectResult
  , encodeExpiredResult
  , encodeFailResult
  , encodePutResult
  , encodeReclaimResult
  , encodeRenewResult
  , encodeSendResult
  , encodeStaleResult
  , parseFailureRecord
  , parseFetchRequest
  , parseResultRecord
  , parseSendRequest
  , parseTakeRequest
  , parseTask
  , readInteger
  )

withStore :: FilePath -> (Paths -> IO ()) -> IO ()
withStore directory action = do
  paths <- openSpool directory
  initialise paths
  withLock paths (recover paths >> action paths)

-- | Bring the spool into line with its records before any command acts on
-- it. Recovery runs under the transition lock, so it cannot race a
-- compliant put or resolution.
recover :: Paths -> IO ()
recover paths = do
  migrateLayout paths
  finishCommitted paths
  finishTaskCleanup paths
  recoverAttachmentState paths
  recoverResultAttachments paths

-- | Finish every transition whose record is written and whose lease still
-- stands. The record is the commit: an ack has happened once its result is
-- recorded and a fail once its failure is, and the steps after the record
-- only bring the rest of the spool into line. A crash between the record
-- and those steps leaves them to be done here, before reclaim or anything
-- else can see a lease whose transition has happened.
finishCommitted :: Paths -> IO ()
finishCommitted paths = do
  files <- jsonFiles (leasedDir paths)
  forM_ files $ \path -> do
    leaseIdent <- leaseIdOfFile path
    acked <- fileExists (resultPath paths leaseIdent)
    failed <- fileExists (failedPath paths leaseIdent)
    when (acked || failed) $ do
      task <- readTaskFile path
      if acked
        then do
          record <- readResultRecordFile (resultPath paths leaseIdent)
          completeAck paths task leaseIdent (resultAttachments record)
        else do
          record <- readFailureRecordFile (failedPath paths leaseIdent)
          completeFail paths task leaseIdent (failureRetried record)

-- | Finish interrupted attachment deletion and remove spool-owned copies for
-- tasks which no longer have a pending or leased state.
recoverAttachmentState :: Paths -> IO ()
recoverAttachmentState paths = do
  cleanupNames <- listDirectory (attachmentCleanupDir paths)
  mapM_ (syncedRemoveDirectory . (attachmentCleanupDir paths </>)) cleanupNames
  pending <- jsonFiles (pendingDir paths) >>= mapM (fmap taskId . readTaskFile)
  leased <- jsonFiles (leasedDir paths) >>= mapM (fmap taskId . readTaskFile)
  let active = pending <> leased
  names <- listDirectory (attachmentsDir paths)
  forM_ names $ \name ->
    if SA.isStagingLeftover name
      then syncedRemoveDirectory (attachmentsDir paths </> name)
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
    syncedRenameDirectory source target
    syncedRemoveDirectory target

putTasks :: Paths -> Maybe FilePath -> IO ()
putTasks paths sourceDirectory = do
  tasks <- inputLines >>= mapM parseTaskLine
  forM_ tasks $ \task -> do
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

-- | A pending or done task is looked up under its own identifier, and no
-- other done task is read, so a put costs no more as history grows. The
-- leased directory is scanned, because a lease is filed under its own
-- identifier; it holds only the leases in flight.
findTask :: Paths -> Task -> IO (Maybe Found)
findTask paths wanted = do
  pending <- comparePath (pendingPath paths (taskId wanted)) wanted
  done <- comparePath (donePath paths (taskId wanted)) wanted
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
  ignoreMissing (syncedRemove (workerSidecarPath paths leaseIdent))
  ignoreMissing (syncedRemove (renewedSidecarPath paths leaseIdent))

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
          moved <- try (syncedRename path (leasedPath paths leaseIdent))
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

-- | Apply one transition to each of these, in order, and answer each on
-- stdout in that order. A lease that is stale is answered so, said on
-- stderr, and the ones after it still run; the command then ends as stale.
-- Anything else that goes wrong ends the command where it happens.
answerEach
  :: (a -> LeaseRef) -> (a -> IO (Either SpoolError BL.ByteString)) -> [a] -> IO ()
answerEach reference step items = do
  refused <- foldM one False items
  when refused (throwIO (stale "one or more leases were stale or unknown"))
  where
    one hadRefusal item = do
      result <- step item
      case result of
        Left failure -> do
          report failure
          BLC.putStrLn (encodeStaleResult (reference item))
          pure True
        Right reply -> BLC.putStrLn reply >> pure hadRefusal

-- Every command reads and checks all of its lines before it acts on any, so
-- a malformed line stops it with nothing done.

ackTasks :: Paths -> IO ()
ackTasks paths = do
  acks <- inputLines >>= mapM parseAckLine
  mapM_ (checkStaged paths) acks
  answerEach ackRef (ackStep paths) acks

ackStep :: Paths -> Ack -> IO (Either SpoolError BL.ByteString)
ackStep paths ack = fmap (encodeAckResult (ackRef ack)) <$> ackOne paths ack

ackOne :: Paths -> Ack -> IO (Either SpoolError AckStatus)
ackOne paths ack@(Ack (LeaseRef ident leaseIdent) output attachments) = do
  let source = leasedPath paths leaseIdent
  sourceExists <- fileExists source
  if sourceExists
    then do
      task <- readTaskFile source
      if taskId task /= ident
        then pure (Left (stale "lease does not belong to task_id"))
        else do
          checkStaged paths ack
          worker <- readWorkerSidecar paths leaseIdent
          stored <- writeResultRecord paths task leaseIdent worker output attachments
          case stored of
            Left failure -> pure (Left failure)
            Right () -> Right Acked <$ completeAck paths task leaseIdent attachments
    else repeatedAck paths ident leaseIdent output attachments

-- | An ack whose lease is in flight may name only result attachments sent
-- under that lease, each whole; otherwise it is malformed input, refused
-- before anything is done (ADR 0020). An ack whose lease is not in flight
-- is answered from its record, as any repeat is.
checkStaged :: Paths -> Ack -> IO ()
checkStaged paths (Ack (LeaseRef ident leaseIdent) _ attachments) =
  unless (null attachments) $ do
    let leasePath = leasedPath paths leaseIdent
    live <- fileExists leasePath
    when live $ do
      task <- readTaskFile leasePath
      when (taskId task == ident) $ forM_ attachments $ \attachment -> do
        size <- sizeOf (stagedPath paths leaseIdent attachment)
        unless (size == Just (SA.attachmentSize attachment)) (throwIO (malformed
          ("result attachment " <> digestOf attachment
            <> " is not staged whole under lease " <> showLease leaseIdent)))

-- | An ack for a lease that is no longer in flight, answered from that
-- lease's own result record alone: the same result is already done, and
-- anything else is stale, an ack whose task has been collected included.
repeatedAck
  :: Paths -> TaskId -> LeaseId -> A.Value -> [SA.Attachment]
  -> IO (Either SpoolError AckStatus)
repeatedAck paths ident leaseIdent output attachments = do
  let path = resultPath paths leaseIdent
  present <- fileExists path
  if not present
    then pure (Left (stale "lease is unknown or stale"))
    else do
      stored <- readResultRecordFile path
      pure $ if resultTask stored /= ident
        then Left (stale "lease does not belong to task_id")
        else if resultValue stored == output && resultAttachments stored == attachments
          then Right AlreadyDone
          else Left (stale "ack result differs from completed result")

-- | The steps after an ack's commit: the result attachments are filed with
-- the task, the lease's staging goes, the lease moves to done, filed under
-- its task, its sidecars go, and the task's attachments go. The lease moves
-- after the result attachments, so that recovery, which looks for leases,
-- finds one whose attachments a crash left unfiled.
completeAck :: Paths -> Task -> LeaseId -> [SA.Attachment] -> IO ()
completeAck paths task leaseIdent attachments = do
  fileResultAttachments paths (taskId task) leaseIdent attachments
  removeResultLease paths leaseIdent
  syncedRename (leasedPath paths leaseIdent) (donePath paths (taskId task))
  removeSidecars paths leaseIdent
  tombstoneAndDelete paths (taskId task)

completedResultMatches :: Paths -> LeaseId -> A.Value -> [SA.Attachment] -> IO Bool
completedResultMatches paths leaseIdent output attachments = do
  let path = resultPath paths leaseIdent
  present <- fileExists path
  unless present (throwIO (retryable
    ("completed lease has no result: " <> showLease leaseIdent)))
  stored <- readResultRecordFile path
  pure (resultValue stored == output && resultAttachments stored == attachments)

renewTasks :: Paths -> IO ()
renewTasks paths =
  inputLines >>= mapM parseLeaseRefLine >>= answerEach id (renewStep paths)

renewStep :: Paths -> LeaseRef -> IO (Either SpoolError BL.ByteString)
renewStep paths reference =
  fmap (const (encodeRenewResult reference)) <$> renewOne paths reference

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
  inputLines >>= mapM parseFailLine >>= answerEach failRef (failStep retry paths)

failStep :: Retry -> Paths -> FailRequest -> IO (Either SpoolError BL.ByteString)
failStep retry paths request =
  fmap (encodeFailResult (failRef request))
    <$> failOne paths (failRef request) (failReason request) retry

-- | 'failOne', for a caller that does not need to know whether the task
-- went back to pending. Used by the `work` loop's failure paths.
failLease :: Paths -> LeaseRef -> T.Text -> Retry -> IO (Either SpoolError ())
failLease paths reference reason retry =
  fmap (const ()) <$> failOne paths reference reason retry

-- | Move a leased task to failed/, recording why, and (with retry, while
-- the task has retries left) put an identical task back in pending/.
-- Answers whether it went back.
failOne :: Paths -> LeaseRef -> T.Text -> Retry -> IO (Either SpoolError Retry)
failOne paths (LeaseRef ident leaseIdent) reason retry = do
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
          (effective, recorded) <- capped paths task leaseIdent reason retry
          stored <- writeFailureRecord paths task leaseIdent worker recorded effective
          case stored of
            Left failure -> pure (Left failure)
            Right () -> Right effective <$ completeFail paths task leaseIdent effective

-- | How many times a task goes back to pending after failing, under
-- ADR 0017: three attempts in all.
retryCap :: Int
retryCap = 2

-- | How many attempts a task has had before a lease, from the serial
-- number and retry of each of its other failure records: the retried
-- ones since its latest one that was not retried. A task put again after
-- it failed for good starts afresh.
attemptsBefore :: [(Integer, Retry)] -> Int
attemptsBefore history = length
  [ serial | (serial, Retry) <- history, all (serial >) finals ]
  where
    finals = [serial | (serial, NoRetry) <- history]

-- | The retry a failure of this lease gets, and the reason to record with
-- it: what was asked for, unless this is the task's last attempt, when it
-- is not retried and the reason says so. The decision is written into the
-- record, which recovery follows; it is never worked out again.
capped :: Paths -> Task -> LeaseId -> T.Text -> Retry -> IO (Retry, T.Text)
capped _ _ _ reason NoRetry = pure (NoRetry, reason)
capped paths task leaseIdent reason Retry = do
  history <- failureHistory paths (taskId task) leaseIdent
  pure $ if attemptsBefore history >= retryCap
    then (NoRetry, reason <> "; retries exhausted after "
      <> T.pack (show (retryCap + 1)) <> " attempts")
    else (Retry, reason)

-- | The serial number and retry of every failure record of this task but
-- the one for this lease. A record is named by its lease, which names its
-- task, so only this task's records are read.
failureHistory :: Paths -> TaskId -> LeaseId -> IO [(Integer, Retry)]
failureHistory paths ident leaseIdent = do
  files <- jsonFiles (failedDir paths)
  named <- forM files $ \path -> do
    recordLease <- leaseIdOfFile path
    case leaseSerialAndTask recordLease of
      Nothing -> throwIO (corrupt ("corrupt failure record name: " <> path))
      Just (serial, owner)
        | owner == ident && recordLease /= leaseIdent -> pure (Just (serial, path))
        | otherwise -> pure Nothing
  forM [entry | Just entry <- named] $ \(serial, path) -> do
    record <- readFailureRecordFile path
    pure (serial, failureRetried record)

-- | The steps after a fail's commit: the task goes back to pending if it is
-- to be retried, the lease and its sidecars go, and for a task left failed
-- its attachments go. Whatever result attachments the lease sent go with
-- it, since no result will name them.
completeFail :: Paths -> Task -> LeaseId -> Retry -> IO ()
completeFail paths task leaseIdent retry = do
  when (retry == Retry) (returnToPending paths task)
  removeResultLease paths leaseIdent
  syncedRemove (leasedPath paths leaseIdent)
  removeSidecars paths leaseIdent
  when (retry == NoRetry) (tombstoneAndDelete paths (taskId task))

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

-- | Write one verified attachment of a leased task to stdout, for a request
-- on stdin. As for 'takeCommand', the lease is checked and the file opened
-- under the lock, and its bytes are verified and written after it is let
-- go: a reader that is slow to read holds up nobody else. When a worker is
-- named, the lease must be that worker's.
fetchAttachment :: Paths -> IO () -> Maybe WorkerName -> IO ()
fetchAttachment paths guard worker = do
  request <- BL.getContents >>= orThrow malformed . parseFetchRequest
  (attachment, handle) <- withLock paths $ do
    guard
    either throwIO pure =<< liveLeaseOwned paths worker (fetchRef request)
    openFetched paths request
  (`finally` hClose handle) $ do
    verified <- SA.verifyHandle attachment handle
    case verified of
      Left message -> throwIO (corrupt
        ("corrupt attachment for " <> showTask (refTask (fetchRef request))
          <> ": " <> message))
      Right () -> do
        hSeek handle AbsoluteSeek 0
        copyToOutput handle

-- | Write what is left of a file to stdout.
copyToOutput :: Handle -> IO ()
copyToOutput handle = do
  chunk <- BS.hGetSome handle 65536
  unless (BS.null chunk) (BS.putStr chunk >> copyToOutput handle)

-- | The declared attachment a current lease asks for, opened for reading.
openFetched :: Paths -> FetchRequest -> IO (SA.Attachment, Handle)
openFetched paths (FetchRequest (LeaseRef ident leaseIdent) digest) = do
  task <- readTaskFile (leasedPath paths leaseIdent)
  attachment <- case
      [declaration | declaration <- taskAttachments task,
        SA.attachmentSha256 declaration == digest] of
    declaration : _ -> pure declaration
    [] -> throwIO (malformed "attachment is not declared by the task")
  let path = SA.attachmentPath (attachmentsDir paths) ident attachment
  present <- fileExists path
  unless present (throwIO (corrupt
    ("attachment " <> digestOf attachment <> " of " <> showTask ident <> " is missing")))
  handle <- openBinaryFile path ReadMode
  pure (attachment, handle)

writeResultRecord
  :: Paths -> Task -> LeaseId -> WorkerName -> A.Value -> [SA.Attachment]
  -> IO (Either SpoolError ())
writeResultRecord paths task leaseIdent worker output attachments = do
  now <- getCurrentTime
  let record = ResultRecord
        { resultTask = taskId task
        , resultLease = leaseIdent
        , resultCapability = taskCapability task
        , resultWorker = worker
        , resultFinishedAt = timestamp now
        , resultValue = output
        , resultAttachments = attachments
        }
  created <- atomicCreate (resultPath paths leaseIdent) (encode record)
  case created of
    Created -> pure (Right ())
    AlreadyThere -> do
      same <- completedResultMatches paths leaseIdent output attachments
      pure $ if same
        then Right ()
        else Left (stale
          "ack result differs from the result already stored for this lease")

-- Result attachments (ADR 0020). A worker sends each file its program left
-- in outputs/ under its lease, before it acknowledges; the ack names them,
-- and is the commit that files them with the task. Bytes are never moved
-- while the lock is held: it is taken before a send, to check the lease and
-- reserve the file's place, and after, to check the lease again and give the
-- file its name.

-- | Who is sending: a worker on the spool's host, or one whose grant fixes
-- its name and limits the bytes the spool holds from it.
data Sender = HostWorker | GrantedWorker WorkerName Int64

-- | Whether a grant's limit leaves room for this many more bytes beside
-- those it holds. A limit of 0 holds none, not even an empty file.
fitsLimit :: Int64 -> Integer -> Int64 -> Bool
fitsLimit limit held size = limit > 0 && held + toInteger size <= toInteger limit

-- | What room a grant's limit has for a file (ADR 0021).
data Room = HasRoom | NoRoomNow | NoRoomEver
  deriving (Eq, Show)

-- | The room a grant's limit has for this many more bytes, given those
-- staged under the sender's own lease and those the grant holds in all.
-- What the lease staged no collect can free while it stands, so a file
-- they leave no room for never fits, and a limit of 0 holds none.
roomFor :: Int64 -> Integer -> Integer -> Int64 -> Room
roomFor limit own held size
  | not (fitsLimit limit own size) = NoRoomEver
  | fitsLimit limit held size = HasRoom
  | otherwise = NoRoomNow

-- | The longest request line a send reads before its bytes.
sendLineLimit :: Int
sendLineLimit = 4096

-- | Send one result attachment: its request line on stdin, then its bytes.
-- The guard is run first in each locked step: recovery, and for a peer, the
-- check that its grant still stands.
sendCommand :: Paths -> IO () -> Sender -> IO ()
sendCommand paths guard sender = do
  hSetBinaryMode stdin True
  (line, already) <- SA.readHeaderLine sendLineLimit stdin >>= orThrow malformed
  request <- orThrow malformed (parseSendRequest (BL.fromStrict line))
  sendFrom paths guard sender request already stdin
  BLC.putStrLn (encodeSendResult (sendRef request))

-- | Stage one result attachment under its lease: the bytes already read,
-- then the rest of the stream. Under the lock, the lease must be in flight
-- and the sender's, and its grant must have room; a temporary file is made,
-- whose name carries the size declared, so that it is counted against the
-- limit while it fills. The bytes are copied, counted, hashed, and synced
-- with the lock let go. Under the lock again, the lease must still stand,
-- and the file is given its digest for a name.
sendFrom :: Paths -> IO () -> Sender -> SendRequest -> BS.ByteString -> Handle -> IO ()
sendFrom paths guard sender (SendRequest reference attachment) already source = do
  let leaseIdent = refLease reference
      directory = resultLeaseDir paths leaseIdent
  (temporary, handle) <- withLock paths $ do
    guard
    either throwIO pure =<< liveLeaseOwned paths (senderWorker sender) reference
    withinLimit paths sender leaseIdent attachment
    present <- fileExists directory
    unless present $ do
      createDirectory directory
      syncDirectory (resultLeasesDir paths)
    openBinaryTempFile directory (sendingTemplate (SA.attachmentSize attachment))
  received <- (do
      copied <- SA.receiveExactly attachment already source handle
      case copied of
        Left message -> pure (Left message)
        Right () -> Right () <$ syncHandle handle)
    `onException` abandon temporary handle
  case received of
    Left message -> do
      abandon temporary handle
      throwIO (malformed ("send: " <> message))
    Right () -> pure ()
  withLock paths $ do
    guard
    allowed <- liveLeaseOwned paths (senderWorker sender) reference
    case allowed of
      Left refusal -> discard temporary >> throwIO refusal
      Right () -> syncedRename temporary (stagedPath paths leaseIdent attachment)
  where
    senderWorker HostWorker = Nothing
    senderWorker (GrantedWorker worker _) = Just worker
    abandon temporary handle = do
      closed <- try (hClose handle) :: IO (Either IOException ())
      either (const (pure ())) pure closed
      discard temporary
    -- The failure in hand is the one to report. A temporary that cannot be
    -- removed is counted against the grant until its lease ends, and goes
    -- with it.
    discard temporary = do
      removed <- try (removeFile temporary) :: IO (Either IOException ())
      either (const (pure ())) pure removed

-- | The name a result attachment has while it is being sent: the size it
-- declared, then what the system makes unique.
sendingTemplate :: Int64 -> FilePath
sendingTemplate size = ".send-" <> show size <> "-.part"

-- | The size a file being sent declared, read from its name.
sendingSize :: FilePath -> Maybe Integer
sendingSize name = do
  rest <- stripPrefix ".send-" name
  let (digits, after) = span isDigit rest
  if not (null digits) && take 1 after == "-" && ".part" `isSuffixOf` after
    then Just (read digits)
    else Nothing

-- | Refuse a file the grant could never hold beside what its own lease
-- staged (7), and then one it has no room for now (6).
withinLimit :: Paths -> Sender -> LeaseId -> SA.Attachment -> IO ()
withinLimit _ HostWorker _ _ = pure ()
withinLimit paths (GrantedWorker worker limit) leaseIdent attachment = do
  let size = SA.attachmentSize attachment
  own <- stagedBytes paths leaseIdent
  held <- heldBytes paths worker
  case roomFor limit own held size of
    HasRoom -> pure ()
    NoRoomNow -> throwIO (overLimit
      ("a result attachment of " <> show size
        <> " bytes is over this grant's max_result_bytes of " <> show limit
        <> ", with " <> show held <> " bytes held"))
    NoRoomEver -> throwIO (neverFits
      ("a result attachment of " <> show size
        <> " bytes could never fit under this grant's max_result_bytes of " <> show limit
        <> ", with " <> show own <> " bytes staged under its lease"))

-- | The bytes of result attachments the spool holds from a worker: those
-- staged and being sent under its leases in flight, and those its acks
-- filed with tasks not yet collected or expired.
heldBytes :: Paths -> WorkerName -> IO Integer
heldBytes paths worker = do
  leases <- jsonFiles (leasedDir paths)
  staged <- forM leases $ \path -> do
    leaseIdent <- leaseIdOfFile path
    handedOut <- fileExists (workerSidecarPath paths leaseIdent)
    owner <- if handedOut then Just <$> readWorkerSidecar paths leaseIdent else pure Nothing
    if owner == Just worker then stagedBytes paths leaseIdent else pure 0
  records <- jsonFiles (resultsDir paths) >>= mapM readResultRecordFile
  pure (sum staged + sum
    [ toInteger (SA.attachmentSize attachment)
    | record <- records, resultWorker record == worker
    , attachment <- resultAttachments record ])

-- | The bytes staged under one lease, each file being sent counted at the
-- size it declared.
stagedBytes :: Paths -> LeaseId -> IO Integer
stagedBytes paths leaseIdent = do
  let directory = resultLeaseDir paths leaseIdent
  present <- fileExists directory
  names <- if present then listDirectory directory else pure []
  sizes <- forM names $ \name -> case (sendingSize name, SA.mkSha256 (T.pack name)) of
    (Just declared, _) -> pure declared
    (Nothing, Right _) -> maybe 0 toInteger <$> sizeOf (directory </> name)
    _ -> throwIO (corrupt ("unexpected entry in result attachments of "
      <> showLease leaseIdent <> ": " <> name))
  pure (sum sizes)

stagedPath :: Paths -> LeaseId -> SA.Attachment -> FilePath
stagedPath paths leaseIdent attachment =
  resultLeaseDir paths leaseIdent </> digestOf attachment

digestOf :: SA.Attachment -> FilePath
digestOf = T.unpack . SA.sha256Text . SA.attachmentSha256

-- | A file's size, or nothing if it is not there.
sizeOf :: FilePath -> IO (Maybe Int64)
sizeOf path = do
  status <- try (getFileStatus path)
  case status of
    Right found -> pure (Just (fromIntegral (fileSize found)))
    Left exception
      | isDoesNotExistError exception -> pure Nothing
      | otherwise -> ioError exception

-- | File an ack's result attachments with its task. Recovery repeats this,
-- so a file already moved is looked for where it went.
fileResultAttachments :: Paths -> TaskId -> LeaseId -> [SA.Attachment] -> IO ()
fileResultAttachments _ _ _ [] = pure ()
fileResultAttachments paths ident leaseIdent attachments = do
  let target = resultTaskDir paths ident
  present <- fileExists target
  unless present $ do
    createDirectory target
    syncDirectory (resultTasksDir paths)
  forM_ attachments $ \attachment -> do
    let from = stagedPath paths leaseIdent attachment
        to = target </> digestOf attachment
    staged <- fileExists from
    if staged
      then syncedRename from to
      else do
        filed <- fileExists to
        unless filed (throwIO (corrupt
          ("result attachment " <> digestOf attachment <> " of "
            <> showTask ident <> " is neither staged nor filed")))

-- | What a lease staged goes when the lease ends.
removeResultLease :: Paths -> LeaseId -> IO ()
removeResultLease paths leaseIdent = removeIfPresent (resultLeaseDir paths leaseIdent)

removeIfPresent :: FilePath -> IO ()
removeIfPresent directory = do
  present <- fileExists directory
  when present (syncedRemoveDirectory directory)

-- | Remove what no lease in flight staged and no done task keeps: what a
-- crash left between a lease's end and the removal of its staging.
recoverResultAttachments :: Paths -> IO ()
recoverResultAttachments paths = do
  leases <- listDirectory (resultLeasesDir paths)
  forM_ leases $ \name -> do
    leaseIdent <- orThrow (corrupt . (("unexpected entry in result attachments: "
      <> name <> ": ") <>)) (mkLeaseId (T.pack name))
    live <- fileExists (leasedPath paths leaseIdent)
    unless live (syncedRemoveDirectory (resultLeasesDir paths </> name))
  tasks <- listDirectory (resultTasksDir paths)
  forM_ tasks $ \name -> do
    ident <- orThrow (corrupt . (("unexpected entry in result attachments: "
      <> name <> ": ") <>)) (mkTaskId (T.pack name))
    done <- fileExists (donePath paths ident)
    unless done (syncedRemoveDirectory (resultTasksDir paths </> name))

-- | Write one result attachment of a done task to stdout, for a request on
-- stdin. The file is opened under the lock and read after it is let go: it
-- is hashed and counted to its end, and only if it matches its declaration
-- is it read again and written.
takeCommand :: Paths -> IO () -> IO ()
takeCommand paths guard = do
  TakeRequest ident digest <- BL.getContents >>= orThrow malformed . parseTakeRequest
  (attachment, handle) <- withLock paths $ do
    guard
    done <- fileExists (donePath paths ident)
    unless done (throwIO (malformed ("task " <> showTask ident <> " is not done")))
    records <- resultRecordsOf paths ident
    attachment <- case [ declared | record <- records
                       , declared <- resultAttachments record
                       , SA.attachmentSha256 declared == digest ] of
      declared : _ -> pure declared
      [] -> throwIO (malformed "attachment is not declared by the task's result")
    let path = resultTaskDir paths ident </> digestOf attachment
    present <- fileExists path
    unless present (throwIO (corrupt
      ("result attachment " <> digestOf attachment <> " of " <> showTask ident
        <> " is missing")))
    handle <- openBinaryFile path ReadMode
    pure (attachment, handle)
  (`finally` hClose handle) $ do
    verified <- SA.verifyHandle attachment handle
    case verified of
      Left message -> throwIO (corrupt
        ("corrupt result attachment of " <> showTask ident <> ": " <> message))
      Right () -> do
        hSeek handle AbsoluteSeek 0
        copyToOutput handle

-- | The result records of a task, found by their names and checked to be
-- its own.
resultRecordsOf :: Paths -> TaskId -> IO [ResultRecord]
resultRecordsOf paths ident = do
  files <- (`filedUnder` ident) <$> filedUnderTasks (resultsDir paths)
  forM files $ \path -> do
    record <- readResultRecordFile path
    unless (resultTask record == ident) (throwIO (corrupt
      ("record filed under " <> showTask ident <> " is another task's: " <> path)))
    pure record

-- | Whether a live lease is on this task and, when a worker is named, is
-- that worker's to act on.
liveLeaseOwned :: Paths -> Maybe WorkerName -> LeaseRef -> IO (Either SpoolError ())
liveLeaseOwned paths worker (LeaseRef ident leaseIdent) = do
  let path = leasedPath paths leaseIdent
  present <- fileExists path
  if not present
    then pure (Left (stale "lease is unknown or stale"))
    else do
      task <- readTaskFile path
      if taskId task /= ident
        then pure (Left (stale "lease does not belong to task_id"))
        else case worker of
          Nothing -> pure (Right ())
          Just name -> do
            owner <- readWorkerSidecar paths leaseIdent
            pure $ if owner == name
              then Right ()
              else Left (stale "lease belongs to a different worker")

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
        when (now - effective >= age * 1000000) $ do
          (ident, retry) <- abandonLease paths
            ("reclaimed: not renewed within " <> T.pack (show age) <> " s")
            path leaseIdent
          BLC.putStrLn (encodeReclaimResult ident retry)

-- | End a lease that has no result, as a failure of the task under it
-- (ADR 0017): the failure is recorded with this reason, and the task goes
-- back to pending unless it has used its retries. Answers the task and
-- whether it went back. A lease with no worker recorded was never handed
-- to one: its task goes back to pending with no record, since nothing ran.
abandonLease :: Paths -> T.Text -> FilePath -> LeaseId -> IO (TaskId, Retry)
abandonLease paths reason leasedFile leaseIdent = do
  task <- readTaskFile leasedFile
  handedOut <- fileExists (workerSidecarPath paths leaseIdent)
  if not handedOut
    then do
      returnToPending paths task
      removeResultLease paths leaseIdent
      syncedRemove leasedFile
      removeSidecars paths leaseIdent
      pure (taskId task, Retry)
    else do
      worker <- readWorkerSidecar paths leaseIdent
      (retry, recorded) <- capped paths task leaseIdent reason Retry
      stored <- writeFailureRecord paths task leaseIdent worker recorded retry
      either throwIO pure stored
      completeFail paths task leaseIdent retry
      pure (taskId task, retry)

-- Retention (ADR 0018). A finished task is a done task, or one whose latest
-- failure was final. It is kept until whoever put it collects it, or until
-- gc finds it older than it was asked to keep, and then it goes with its
-- result and every failure record.

-- | The layout this binary keeps: each done task filed under its task ID.
currentLayout :: BL.ByteString
currentLayout = "1\n"

-- | Bring a spool written before ADR 0018 into the current layout, and
-- refuse one in a layout this binary does not know. A done task was filed
-- under the lease that finished it. What each file holds decides where it
-- goes, because a task ID may itself look like a lease ID. Each rename is
-- whole and the layout is written last, so a migration that is interrupted
-- runs again and finds less to do.
migrateLayout :: Paths -> IO ()
migrateLayout paths = do
  let marker = layoutPath paths
  present <- fileExists marker
  if present
    then do
      layout <- readWhole marker
      unless (layout == currentLayout) (throwIO (corrupt
        ("unknown spool layout in " <> marker)))
    else do
      files <- jsonFiles (doneDir paths)
      forM_ files $ \path -> do
        task <- readTaskFile path
        let target = donePath paths (taskId task)
        unless (path == target) $ do
          taken <- fileExists target
          if not taken
            then syncedRename path target
            else do
              same <- equalTaskFile target task
              unless same (throwIO (corrupt
                ("two done tasks differ under " <> showTask (taskId task))))
              syncedRemove path
      _ <- atomicCreate marker currentLayout
      pure ()

-- | Finish every deletion whose marker was made.
finishTaskCleanup :: Paths -> IO ()
finishTaskCleanup paths = do
  names <- listDirectory (taskCleanupDir paths)
  unless (null names) $ do
    results <- filedUnderTasks (resultsDir paths)
    failures <- filedUnderTasks (failedDir paths)
    forM_ names $ \name -> case mkTaskId (T.pack name) of
      Left _ -> throwIO (corrupt ("unexpected entry in task cleanup: " <> name))
      Right ident ->
        removeTask paths ident (filedUnder results ident <> filedUnder failures ident)

-- | The records in a directory filed under leases, by the task each lease
-- was on, found from their names alone: a lease this spool made is named
-- for its task.
filedUnderTasks :: FilePath -> IO (Map.Map TaskId [FilePath])
filedUnderTasks directory = do
  files <- jsonFiles directory
  owned <- forM files $ \path -> do
    leaseIdent <- leaseIdOfFile path
    case leaseSerialAndTask leaseIdent of
      Just (_, ident) -> pure (ident, [path])
      Nothing -> throwIO (corrupt
        ("record is not filed under a lease this spool made: " <> path))
  pure (Map.fromListWith (flip (<>)) owned)

filedUnder :: Map.Map TaskId [FilePath] -> TaskId -> [FilePath]
filedUnder index ident = Map.findWithDefault [] ident index

-- | Delete a finished task. Making its marker is the commit: from then on
-- recovery finishes the deletion, however much of it a crash left undone.
retire :: Paths -> TaskId -> [FilePath] -> IO ()
retire paths ident records = do
  createMarker (taskCleanupPath paths ident)
  removeTask paths ident records

-- | The steps after the marker: the done file, then its result
-- attachments, then the records, then the marker itself, each removal
-- synced.
removeTask :: Paths -> TaskId -> [FilePath] -> IO ()
removeTask paths ident records = do
  ignoreMissing (syncedRemove (donePath paths ident))
  removeIfPresent (resultTaskDir paths ident)
  mapM_ (ignoreMissing . syncedRemove) records
  syncedRemove (taskCleanupPath paths ident)

collectTasks :: Paths -> IO ()
collectTasks paths = do
  idents <- inputLines >>= mapM parseCollectLine
  forM_ idents $ \ident -> do
    status <- collectOne paths ident
    BLC.putStrLn (encodeCollectResult ident status)

-- | Delete a finished task now, because whoever put it has read what came
-- of it. A task still pending or leased is left whole, and its history of
-- retried failures with it.
collectOne :: Paths -> TaskId -> IO CollectStatus
collectOne paths ident = do
  pending <- fileExists (pendingPath paths ident)
  leased <- elem ident <$> activeTaskIds paths
  if pending || leased
    then pure NotFinished
    else do
      done <- fileExists (donePath paths ident)
      results <- (`filedUnder` ident) <$> filedUnderTasks (resultsDir paths)
      failures <- (`filedUnder` ident) <$> filedUnderTasks (failedDir paths)
      forM_ results $ \path -> readResultRecordFile path >>= named path . resultTask
      forM_ failures $ \path -> readFailureRecordFile path >>= named path . failureTask
      if done || not (null results) || not (null failures)
        then Collected <$ retire paths ident (results <> failures)
        else pure Unknown
  where
    named path held = unless (held == ident) (throwIO (corrupt
      ("record filed under " <> showTask ident <> " is another task's: " <> path)))

-- | Delete every finished task that finished at least this many seconds
-- ago, oldest first. A caller runs it; nothing in Spool does.
gcTasks :: Paths -> Integer -> IO ()
gcTasks paths age = do
  now <- getCurrentTime
  finished <- finishedTasks paths
  let expired = sortOn (\(ident, at) -> (at, ident))
        [entry | entry@(_, at) <- finished, diffUTCTime now at >= fromInteger age]
  results <- filedUnderTasks (resultsDir paths)
  failures <- filedUnderTasks (failedDir paths)
  forM_ expired $ \(ident, _) -> do
    retire paths ident (filedUnder results ident <> filedUnder failures ident)
    BLC.putStrLn (encodeExpiredResult ident)

-- | Every finished task and when it finished: a done task when its result
-- was recorded, a finally failed one at its latest final failure. It reads
-- every record the spool holds, so its cost grows with what is retained.
finishedTasks :: Paths -> IO [(TaskId, UTCTime)]
finishedTasks paths = do
  results <- jsonFiles (resultsDir paths) >>= mapM readResultRecordFile
  failures <- jsonFiles (failedDir paths) >>= mapM readFailureRecordFile
  doneIds <- jsonFiles (doneDir paths) >>= mapM taskOfFileName
  pendingIds <- jsonFiles (pendingDir paths) >>= mapM taskOfFileName
  leasedIds <- activeTaskIds paths
  finishedAt <- latest [(resultTask record, resultFinishedAt record) | record <- results]
  failedAt <- latest
    [ (failureTask record, failureFailedAt record)
    | record <- failures, failureRetried record == NoRetry ]
  done <- forM doneIds $ \ident -> case Map.lookup ident finishedAt of
    Just at -> pure (ident, at)
    Nothing -> throwIO (corrupt ("done task has no result: " <> showTask ident))
  let standing = Set.fromList (doneIds <> pendingIds <> leasedIds)
  pure (done <> [entry | entry@(ident, _) <- Map.toList failedAt,
    ident `Set.notMember` standing])
  where
    latest entries = Map.fromListWith max <$> forM entries (\(ident, at) ->
      case timestampTime at of
        Just time -> pure (ident, time)
        Nothing -> throwIO (corrupt ("unreadable time in a record of " <> showTask ident)))

-- | The task a pending or done file is filed under.
taskOfFileName :: FilePath -> IO TaskId
taskOfFileName path = case mkTaskId (T.pack (takeBaseName path)) of
  Right ident -> pure ident
  Left _ -> throwIO (corrupt ("corrupt task filename: " <> path))

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
