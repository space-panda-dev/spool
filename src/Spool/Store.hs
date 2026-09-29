{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

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

import Control.Exception (IOException, displayException, try)
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
import System.Exit (ExitCode (..), exitWith)
import System.FilePath (takeBaseName, (</>))
import System.IO (stderr)
import System.IO.Error (isDoesNotExistError)
import qualified Spool.Attachments as SA
import Spool.Failure (SpoolFailure (..), throwFailure)
import Spool.Files
  ( Paths (..)
  , withLock
  , makePaths
  , initialise
  , jsonFiles
  , fileExists
  , atomicCreate
  , atomicReplace
  , ignoreMissing
  , epochMicros
  )
import Spool.Input
  ( parseTaskLine
  , parseAckLine
  , parseLeaseRefLine
  , parseFailLine
  , inputLines
  )
import Spool.Wire
  ( Task (..)
  , Lease (..)
  , PutStatus (..)
  , AckStatus (..)
  , parseTask
  , parseFetchRequest
  , encodeTask
  , encodePutResult
  , encodeLease
  , encodeAckResult
  , encodeRenewResult
  , encodeFailResult
  , encodeReclaimResult
  , encodeFailedRecord
  , encodeResultRecord
  , encodeStatus
  , canonical
  , parseFailureRecord
  , parseResultRecord
  , extractTextField
  , leaseMicros
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
          stored <- writeFailureRecord paths task leaseIdent worker reason retry
          case stored of
            Left message -> pure (Left message)
            Right () -> do
              when retry (returnToPending paths task)
              removeFile source
              removeSidecars paths leaseIdent
              unless retry (tombstoneAndDelete paths (taskId task))
              pure (Right retry)

-- | Record a failure once. A record already there belongs to a fail that was
-- interrupted before it removed the lease: the same reason and retry choice
-- finish that fail, and anything else is refused, as a differing result is
-- for ack.
writeFailureRecord
  :: Paths -> Task -> T.Text -> T.Text -> T.Text -> Bool -> IO (Either String ())
writeFailureRecord paths task leaseIdent worker reason retry = do
  now <- getCurrentTime
  let failedAt = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now)
      record = encodeFailedRecord task leaseIdent worker failedAt reason retry
      path = failedDir paths </> T.unpack leaseIdent <> ".json"
  created <- atomicCreate path record
  if created
    then pure (Right ())
    else do
      existing <- readFailureRecordFile path
      pure $ if existing `recordsFailure` (reason, retry)
        then Right ()
        else Left "fail differs from the failure already recorded for this lease"
  where
    recordsFailure (A.Object object) (wantedReason, wantedRetry) =
      KM.lookup "reason" object == Just (A.String wantedReason)
        && KM.lookup "retried" object == Just (A.Bool wantedRetry)
    recordsFailure _ _ = False

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
