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
  , ackLines
  , ackOne
  , renewTasks
  , renewLines
  , renewOne
  , failTasks
  , failLines
  , failLease
  , returnToPending
  , failuresCommand
  , resultsCommand
  , fetchAttachment
  , fetchAttachmentBytes
  , reclaimTasks
  , statusTasks
  ) where

import Control.Exception (IOException, displayException, throwIO, try)
import Control.Monad (foldM, forM, forM_, unless, when)
import qualified Data.Aeson as A
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.List (sortOn)
import Data.Maybe (listToMaybe)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import System.Directory (listDirectory, removeDirectoryRecursive, removeFile,
                         removePathForcibly, renameDirectory, renameFile)
import System.FilePath (takeBaseName, (</>))
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
  , Paths (..)
  , atomicCreate
  , atomicReplace
  , donePath
  , epochMicros
  , failedPath
  , fileExists
  , ignoreMissing
  , initialise
  , jsonFiles
  , leasedPath
  , makePaths
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
  , newLeaseId
  , storedWorkerName
  , taskIdText
  , workerNameText
  )
import Spool.Wire
  ( AckStatus (..)
  , Lease (..)
  , PutStatus (..)
  , Task (..)
  , canonical
  , encodeAckResult
  , encodeFailResult
  , encodeFailedRecord
  , encodeLease
  , encodePutResult
  , encodeReclaimResult
  , encodeRenewResult
  , encodeResultRecord
  , encodeStatus
  , encodeTask
  , extractTextField
  , parseFailureRecord
  , parseFetchRequest
  , parseResultRecord
  , parseTask
  , readInteger
  )

withStore :: FilePath -> (Paths -> IO ()) -> IO ()
withStore directory action = do
  let paths = makePaths directory
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
      created <- atomicCreate (pendingPath paths (taskId task)) (encodeTask task)
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
  bytes <- BL.readFile path
  case parseTask bytes of
    Left message -> throwIO (corrupt
      ("corrupt task file " <> path <> ": " <> message))
    Right task -> pure task

readFailureRecordFile :: FilePath -> IO A.Value
readFailureRecordFile path = do
  bytes <- BL.readFile path
  case parseFailureRecord bytes of
    Left message -> throwIO (corrupt
      ("corrupt failure record " <> path <> ": " <> message))
    Right value -> pure value

readResultRecordFile :: FilePath -> IO (A.Value, A.Value)
readResultRecordFile path = do
  bytes <- BL.readFile path
  case parseResultRecord bytes of
    Left message -> throwIO (corrupt
      ("corrupt result record " <> path <> ": " <> message))
    Right value -> pure value

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
      case TE.decodeUtf8' bytes of
        Left _ -> throwIO (corrupt
          ("corrupt worker sidecar for " <> showLease leaseIdent))
        Right worker -> pure (storedWorkerName (T.strip worker))

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
      value <- readInteger . T.strip . T.pack . BLC.unpack <$> BL.readFile path
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
  forM_ leased (BLC.putStrLn . encodeLease)

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
          let lease = Lease task leaseIdent worker
                (T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now))
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
  current <- if present then readInteger . T.strip . T.pack <$> readFile path else pure (Just 0)
  case current of
    Nothing -> throwIO (corrupt "corrupt lease sequence")
    Just value -> do
      let next = value + 1
      atomicReplace path (BLC.pack (show next <> "\n"))
      pure next

-- | Apply one transition to each line. A lease that is stale is reported and
-- the lines after it still run; the command then ends as stale. Anything
-- else that goes wrong ends the command where it happens.
forEachLine :: (BL.ByteString -> IO (Either SpoolError BL.ByteString))
            -> [BL.ByteString] -> IO ()
forEachLine step linesIn = do
  refused <- foldM one False linesIn
  when refused (throwIO (stale "one or more leases were stale or unknown"))
  where
    one hadRefusal line = do
      result <- step line
      case result of
        Left failure -> report failure >> pure True
        Right reply -> BLC.putStrLn reply >> pure hadRefusal

ackTasks :: Paths -> IO ()
ackTasks paths = inputLines >>= ackLines paths

ackLines :: Paths -> [BL.ByteString] -> IO ()
ackLines paths = forEachLine $ \line -> do
  (ident, leaseIdent, output) <- parseAckLine line
  fmap (encodeAckResult ident) <$> ackOne paths ident leaseIdent output

ackOne :: Paths -> TaskId -> LeaseId -> A.Value -> IO (Either SpoolError AckStatus)
ackOne paths ident leaseIdent output = do
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
  (_, stored) <- readResultRecordFile path
  pure (stored == output)

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
renewTasks paths = inputLines >>= renewLines paths

renewLines :: Paths -> [BL.ByteString] -> IO ()
renewLines paths = forEachLine $ \line -> do
  (ident, leaseIdent) <- parseLeaseRefLine line
  fmap (const (encodeRenewResult ident)) <$> renewOne paths ident leaseIdent

renewOne :: Paths -> TaskId -> LeaseId -> IO (Either SpoolError ())
renewOne paths ident leaseIdent = do
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
failTasks retry paths = inputLines >>= failLines retry paths

failLines :: Retry -> Paths -> [BL.ByteString] -> IO ()
failLines retry paths = forEachLine $ \line -> do
  (ident, leaseIdent, reason) <- parseFailLine line
  fmap (const (encodeFailResult ident retry))
    <$> failLease paths ident leaseIdent reason retry

-- | Move a leased task to failed/, recording why, and (with retry) put an
-- identical task back in pending/. Shared by the CLI `fail` command and the
-- `work` loop's failure paths.
failLease :: Paths -> TaskId -> LeaseId -> T.Text -> Retry -> IO (Either SpoolError ())
failLease paths ident leaseIdent reason retry = do
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
  let failedAt = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now)
      record = encodeFailedRecord task leaseIdent worker failedAt reason retry
      path = failedPath paths leaseIdent
  created <- atomicCreate path record
  case created of
    Created -> pure (Right ())
    AlreadyThere -> do
      existing <- readFailureRecordFile path
      pure $ if recordsThisFailure existing
        then Right ()
        else Left (stale
          "fail differs from the failure already recorded for this lease")
  where
    recordsThisFailure (A.Object object) =
      KM.lookup "reason" object == Just (A.String reason)
        && KM.lookup "retried" object == Just (A.Bool (retry == Retry))
    recordsThisFailure _ = False

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
      created <- atomicCreate path (encodeTask task)
      when (created == AlreadyThere) $ do
        same <- equalTaskFile path task
        unless same (throwIO (conflict
          ("could not return task " <> showTask (taskId task))))

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
  (ident, leaseIdent, digest) <- orThrow malformed (parseFetchRequest bytes)
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
    Right () -> BL.readFile path >>= BL.putStr

oldestFirst :: T.Text -> [A.Value] -> [A.Value]
oldestFirst key records = map snd (sortOn fst [(extractTextField key record, record) | record <- records])

writeResultRecord
  :: Paths -> Task -> LeaseId -> WorkerName -> A.Value -> IO (Either SpoolError ())
writeResultRecord paths task leaseIdent worker output = do
  now <- getCurrentTime
  let finishedAt = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now)
      record = encodeResultRecord task leaseIdent worker finishedAt output
  created <- atomicCreate (resultPath paths leaseIdent) record
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
  pending <- length <$> jsonFiles (pendingDir paths)
  leased <- length <$> jsonFiles (leasedDir paths)
  done <- length <$> jsonFiles (doneDir paths)
  failed <- length <$> jsonFiles (failedDir paths)
  case format of
    StatusJson -> BLC.putStrLn (encodeStatus pending leased done failed)
    StatusText -> putStrLn ("pending=" <> show pending <> " leased=" <> show leased
      <> " done=" <> show done <> " failed=" <> show failed)

showTask :: TaskId -> String
showTask = T.unpack . taskIdText

showLease :: LeaseId -> String
showLease = T.unpack . leaseIdText
