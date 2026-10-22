-- | The spool's directories, its lock, and the atomic file operations every
-- transition is built from.
module Spool.Files
  ( Paths
  , rootDir
  , pendingDir
  , leasedDir
  , doneDir
  , failedDir
  , resultsDir
  , attachmentsDir
  , attachmentCleanupDir
  , taskCleanupDir
  , resultLeasesDir
  , resultTasksDir
  , withdrawnDir
  , layoutPath
  , lockPath
  , openSpool
  , withLock
  , initialise
  , pendingPath
  , leasedPath
  , donePath
  , failedPath
  , resultPath
  , taskCleanupPath
  , resultLeaseDir
  , resultTaskDir
  , withdrawnPath
  , workerSidecarPath
  , renewedSidecarPath
  , jsonFiles
  , fileExists
  , Created (..)
  , atomicCreate
  , atomicReplace
  , createMarker
  , syncedRename
  , syncedRemove
  , syncedRenameDirectory
  , syncedRemoveDirectory
  , syncHandle
  , syncDirectory
  , ignoreMissing
  , epochMicros
  ) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (IOException, bracket, catch, finally, try)
import Control.Monad (unless)
import qualified Data.ByteString.Lazy as BL
import Data.List (sort)
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.Directory (createDirectoryIfMissing, listDirectory, removeFile,
                         removePathForcibly, renameDirectory, renameFile)
import System.FilePath (takeDirectory, takeExtension, (</>))
import System.IO (Handle, hClose, hFlush, openBinaryTempFile)
import GHC.IO.Handle.Lock (LockMode (ExclusiveLock), hLock)
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import System.Posix.Files (FileStatus, createLink, getFileStatus)
import System.Posix.IO (OpenFileFlags (cloexec, creat, exclusive), OpenMode (ReadOnly, WriteOnly),
                        closeFd, defaultFileFlags, fdToHandle, handleToFd, openFd)
import System.Posix.Types (Fd)
import System.Posix.Unistd (fileSynchronise)
import qualified Data.Text as T
import Spool.Types (LeaseId, TaskId, leaseIdText, taskIdText)

data Paths = Paths
  { rootDir :: FilePath
  , pendingDir :: FilePath
  , leasedDir :: FilePath
  , doneDir :: FilePath
  , failedDir :: FilePath
  , resultsDir :: FilePath
  , attachmentsDir :: FilePath
  , attachmentCleanupDir :: FilePath
  , taskCleanupDir :: FilePath
    -- ^ One empty marker for each finished task being deleted (ADR 0018).
  , resultLeasesDir :: FilePath
    -- ^ The result attachments sent under each lease in flight (ADR 0020).
  , resultTasksDir :: FilePath
    -- ^ The result attachments of each done task (ADR 0020).
  , withdrawnDir :: FilePath
    -- ^ A record for each lease whose task was withdrawn while it was held
    -- (ADR 0023).
  , layoutPath :: FilePath
    -- ^ Which layout the spool's files are in (ADR 0018).
  , lockPath :: FilePath
  , processLock :: MVar ()
    -- ^ Keeps this process's own threads from the lock file at once. See
    -- 'withLock'.
  }

-- | Acquire the store's exclusive lock for exactly one transition. The
-- "work" command takes this per lease/renew/ack/fail rather than once for
-- the whole command, so an executable never runs while the lock is held.
--
-- The "work" command's concurrent tasks each take the lock for their own
-- transition, from separate green threads in this one process. GHC's file
-- lock (flock(2) under the hood) is scoped to the OS process, so two threads
-- in the same process racing to open and lock the same path is not the
-- cross-process case it was designed for, and observably (macOS, GHC 9.14) a
-- losing open can raise "resource busy" instead of blocking. The
-- spool's own mutex serialises those threads before any of them touches the
-- file, leaving the file lock doing only what it always did: keeping a
-- second "spool" process out.
--
-- The lock belongs to the open file, not to the descriptor, so a program
-- started while it is held, by another thread, would hold it until that
-- program ended. The file is opened close-on-exec, and programs are started
-- with only their three pipes, so no program ever holds it.
withLock :: Paths -> IO a -> IO a
withLock paths action = withMVar (processLock paths) $ \() ->
  bracket openLock hClose $ \handle -> do
    hLock handle ExclusiveLock
    action
  where
    openLock = openFd (lockPath paths) WriteOnly defaultFileFlags
      { creat = Just 0o644, cloexec = True } >>= fdToHandle

-- | The spool in a directory. A process opens its spool once and passes it
-- on: the mutex that keeps its threads apart is made here, so two openings
-- of one directory would not keep each other's threads apart.
openSpool :: FilePath -> IO Paths
openSpool directory = spoolAt directory <$> newMVar ()

spoolAt :: FilePath -> MVar () -> Paths
spoolAt directory lock = Paths
  { rootDir = directory
  , pendingDir = directory </> "pending"
  , leasedDir = directory </> "leased"
  , doneDir = directory </> "done"
  , failedDir = directory </> "failed"
  , resultsDir = directory </> "results"
  , attachmentsDir = directory </> "attachments"
  , attachmentCleanupDir = directory </> ".attachment-cleanup"
  , taskCleanupDir = directory </> ".task-cleanup"
  , resultLeasesDir = directory </> "result-attachments" </> "leases"
  , resultTasksDir = directory </> "result-attachments" </> "tasks"
  , withdrawnDir = directory </> "withdrawn"
  , layoutPath = directory </> ".spool-layout"
  , lockPath = directory </> ".spool.lock"
  , processLock = lock
  }

-- A pending task and a done task are filed under the task's own identifier,
-- so that a put looks for its task and at nothing else (ADR 0018). A lease,
-- and the records of what came of it, are filed under the lease's, which is
-- what fences a stale worker.
pendingPath, donePath, taskCleanupPath :: Paths -> TaskId -> FilePath
pendingPath paths = underTask (pendingDir paths) ".json"
donePath paths = underTask (doneDir paths) ".json"
taskCleanupPath paths = underTask (taskCleanupDir paths) ""

-- | Where a done task's result attachments are kept, and where a lease's
-- are staged until its ack files them there.
resultTaskDir :: Paths -> TaskId -> FilePath
resultTaskDir paths = underTask (resultTasksDir paths) ""

resultLeaseDir :: Paths -> LeaseId -> FilePath
resultLeaseDir paths = underLease (resultLeasesDir paths) ""

underTask :: FilePath -> String -> TaskId -> FilePath
underTask directory extension ident =
  directory </> T.unpack (taskIdText ident) <> extension

leasedPath, failedPath, resultPath, withdrawnPath :: Paths -> LeaseId -> FilePath
leasedPath paths = underLease (leasedDir paths) ".json"
failedPath paths = underLease (failedDir paths) ".json"
resultPath paths = underLease (resultsDir paths) ".json"
withdrawnPath paths = underLease (withdrawnDir paths) ".json"

workerSidecarPath, renewedSidecarPath :: Paths -> LeaseId -> FilePath
workerSidecarPath paths = underLease (leasedDir paths) ".worker"
renewedSidecarPath paths = underLease (leasedDir paths) ".renewed"

underLease :: FilePath -> String -> LeaseId -> FilePath
underLease directory extension leaseIdent =
  directory </> T.unpack (leaseIdText leaseIdent) <> extension

initialise :: Paths -> IO ()
initialise paths = mapM_ (createDirectoryIfMissing True)
  [rootDir paths, pendingDir paths, leasedDir paths, doneDir paths,
   failedDir paths, resultsDir paths, attachmentsDir paths,
   attachmentCleanupDir paths, taskCleanupDir paths, resultLeasesDir paths,
   resultTasksDir paths, withdrawnDir paths]

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

-- | Whether 'atomicCreate' made the file or found one already there.
data Created = Created | AlreadyThere
  deriving (Eq, Show)

-- | Create a file with these bytes, or leave the one already there alone.
-- The bytes are written to a temporary file and linked into place, so the
-- name appears complete or not at all and never replaces another.
atomicCreate :: FilePath -> BL.ByteString -> IO Created
atomicCreate path bytes = do
  let directory = takeDirectory path
  createDirectoryIfMissing True directory
  (temporary, handle) <- openBinaryTempFile directory ".spool-task"
  result <- (BL.hPut handle bytes >> syncHandle handle >> try (createLink temporary path))
    `finally` ignoreMissing (removeFile temporary)
  case result of
    Right () -> Created <$ syncDirectory directory
    Left exception
      | isAlreadyExistsError exception -> pure AlreadyThere
      | otherwise -> ioError exception

-- | Give a file these bytes, replacing what it held, so that it holds the
-- old bytes or the new and never part of either.
atomicReplace :: FilePath -> BL.ByteString -> IO ()
atomicReplace path bytes = do
  let directory = takeDirectory path
  (temporary, handle) <- openBinaryTempFile directory ".spool-sequence"
  (BL.hPut handle bytes >> syncHandle handle >> renameFile temporary path)
    `finally` ignoreMissing (removeFile temporary)
  syncDirectory directory

-- | Create an empty file, or leave the one already there alone, and sync
-- the directory. A marker has no bytes to be torn, so it is made in place,
-- and its directory holds nothing but markers.
createMarker :: FilePath -> IO ()
createMarker path = do
  made <- try (openFd path WriteOnly defaultFileFlags
    { creat = Just 0o644, exclusive = True }) :: IO (Either IOException Fd)
  case made of
    Right fd -> closeFd fd
    Left exception
      | isAlreadyExistsError exception -> pure ()
      | otherwise -> ioError exception
  syncDirectory (takeDirectory path)

-- What a command answers for is on the disk when it answers (ADR 0014). A
-- file's bytes are synced before it is given its name, and a directory is
-- synced after a name is added to it, removed from it, or moved.

-- | Move a file, and sync the directories it left and joined.
syncedRename :: FilePath -> FilePath -> IO ()
syncedRename from to = do
  renameFile from to
  syncDirectories from to

-- | Remove a file, and sync the directory it left.
syncedRemove :: FilePath -> IO ()
syncedRemove path = do
  removeFile path
  syncDirectory (takeDirectory path)

-- | Move a directory, and sync the directories it left and joined.
syncedRenameDirectory :: FilePath -> FilePath -> IO ()
syncedRenameDirectory from to = do
  renameDirectory from to
  syncDirectories from to

-- | Remove a directory and everything in it, and sync the directory it left.
syncedRemoveDirectory :: FilePath -> IO ()
syncedRemoveDirectory path = do
  removePathForcibly path
  syncDirectory (takeDirectory path)

syncDirectories :: FilePath -> FilePath -> IO ()
syncDirectories from to = do
  syncDirectory (takeDirectory from)
  unless (takeDirectory from == takeDirectory to) (syncDirectory (takeDirectory to))

-- | Write a handle's bytes through to the disk and close it.  The handle is
-- unusable afterwards.
syncHandle :: Handle -> IO ()
syncHandle handle = do
  hFlush handle
  fd <- handleToFd handle
  fileSynchronise fd `finally` closeFd fd

-- | Write a directory's entries through to the disk, so that a name added,
-- removed, or moved is there after a power loss.
syncDirectory :: FilePath -> IO ()
syncDirectory directory =
  bracket (openFd directory ReadOnly defaultFileFlags) closeFd fileSynchronise

ignoreMissing :: IO () -> IO ()
ignoreMissing action = action `catch` ignore
  where
    ignore :: IOException -> IO ()
    ignore exception
      | isDoesNotExistError exception = pure ()
      | otherwise = ioError exception

epochMicros :: IO Integer
epochMicros = round . (* 1000000) <$> getPOSIXTime
