{-# LANGUAGE OverloadedStrings #-}

-- No sequence of commands can make the removal of a temporary file fail at
-- the moment an attachment is refused, so the integration suite cannot reach
-- this.  Here the source is a pipe: the receiver has made its temporary file
-- and is waiting on the pipe when the directory is closed to writing, so the
-- removal that follows the refusal is itself refused.
module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, bracket, finally, try)
import Control.Monad (when)
import qualified Data.Text as T
import SpoolAttachments (Attachment (..), receiveAttachment)
import System.Directory (getTemporaryDirectory, listDirectory,
                         removeDirectoryRecursive)
import System.Exit (exitSuccess)
import System.FilePath ((</>))
import System.IO (hClose, hPutStrLn, stderr)
import System.Posix.Files (setFileMode)
import System.Posix.Temp (mkdtemp)
import System.Posix.User (getEffectiveUserID)
import System.Process (createPipe)

main :: IO ()
main = do
  user <- getEffectiveUserID
  when (user == 0) $ do
    hPutStrLn stderr
      "SKIPPED: the superuser is never refused a removal, so this proves nothing"
    exitSuccess
  base <- getTemporaryDirectory
  bracket (mkdtemp (base </> "spool-cleanup-test")) removeDirectoryRecursive
    refusalSurvivesRefusedCleanup

-- | A refused attachment is reported as refused even when the temporary file
-- cannot be removed afterwards.
refusalSurvivesRefusedCleanup :: FilePath -> IO ()
refusalSurvivesRefusedCleanup scratch = do
  let workerRoot = scratch </> "attachments"
      -- A well-formed declaration that an empty stream cannot satisfy.
      declared = Attachment (T.replicate 64 "0") 1
  (readEnd, writeEnd) <- createPipe
  outcome <- newEmptyMVar
  _ <- forkIO $ do
    result <- try (receiveAttachment workerRoot declared readEnd)
    putMVar outcome (result :: Either SomeException (Either String ()))
  awaitTemporary workerRoot 500
  setFileMode workerRoot 0o500
  hClose writeEnd
  result <- takeMVar outcome `finally` setFileMode workerRoot 0o700
  hClose readEnd
  leftovers <- listDirectory workerRoot
  when (null leftovers) $
    fail "the removal was not refused, so nothing was proven"
  case result of
    Right (Left "attachment sha256 does not match declaration") -> pure ()
    other -> fail
      ("a refused cleanup replaced the refusal being reported: " <> show other)

-- | Wait for the receiver to create its temporary file, which it does just
-- before it starts reading the pipe.  Nothing else is ever in the directory,
-- so any entry is that file, whatever it is called.
awaitTemporary :: FilePath -> Int -> IO ()
awaitTemporary directory attempts = do
  names <- either (const []) id <$> tryList
  when (null names) $ do
    when (attempts <= 0) $
      fail "the receiver never created its temporary file"
    threadDelay 10000
    awaitTemporary directory (attempts - 1)
  where
    tryList :: IO (Either IOError [FilePath])
    tryList = try (listDirectory directory)
