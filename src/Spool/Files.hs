-- | The spool's directories, its lock, and the atomic file operations every
-- transition is built from.
module Spool.Files
  ( Paths (..)
  , withLock
  , makePaths
  , initialise
  , pendingPath
  , leasedPath
  , donePath
  , failedPath
  , resultPath
  , workerSidecarPath
  , renewedSidecarPath
  , jsonFiles
  , fileExists
  , Created (..)
  , atomicCreate
  , atomicReplace
  , ignoreMissing
  , epochMicros
  ) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (IOException, bracket, catch, finally, try)
import qualified Data.ByteString.Lazy as BL
import Data.List (sort)
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.Directory (createDirectoryIfMissing, listDirectory, removeFile,
                         renameFile)
import System.FilePath (takeDirectory, takeExtension, (</>))
import System.IO (IOMode (AppendMode), hClose, openBinaryTempFile, openFile)
import GHC.IO.Handle.Lock (LockMode (ExclusiveLock), hLock)
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import System.Posix.Files (FileStatus, createLink, getFileStatus)
import System.IO.Unsafe (unsafePerformIO)
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
  , lockPath :: FilePath
  }

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

-- A pending task is filed under its own identifier. Everything that follows
-- a lease is filed under the lease's, which is what fences a stale worker.
pendingPath :: Paths -> TaskId -> FilePath
pendingPath paths ident = pendingDir paths </> T.unpack (taskIdText ident) <> ".json"

leasedPath, donePath, failedPath, resultPath :: Paths -> LeaseId -> FilePath
leasedPath paths = underLease (leasedDir paths) ".json"
donePath paths = underLease (doneDir paths) ".json"
failedPath paths = underLease (failedDir paths) ".json"
resultPath paths = underLease (resultsDir paths) ".json"

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
   attachmentCleanupDir paths]

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
  result <- (BL.hPut handle bytes >> hClose handle >> try (createLink temporary path))
    `finally` ignoreMissing (removeFile temporary)
  case result of
    Right () -> pure Created
    Left exception
      | isAlreadyExistsError exception -> pure AlreadyThere
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

epochMicros :: IO Integer
epochMicros = round . (* 1000000) <$> getPOSIXTime
