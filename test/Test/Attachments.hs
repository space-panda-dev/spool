{-# LANGUAGE OverloadedStrings #-}

-- | The attachment boundary: declarations, the names of the writer's own
-- leftovers, and what is reported when a cleanup is itself refused.
module Test.Attachments (tests) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, bracket, finally, try)
import Control.Monad (when)
import Data.Either (isLeft)
import qualified Data.Text as T
import Spool.Attachments
  ( Attachment (..)
  , isStagingLeftover
  , receiveAttachment
  , validateAttachments
  )
import System.Directory (getTemporaryDirectory, listDirectory,
                         removeDirectoryRecursive)
import System.FilePath ((</>))
import System.IO (hClose)
import System.Posix.Files (setFileMode)
import System.Posix.Temp (mkdtemp)
import System.Posix.User (getEffectiveUserID)
import System.Process (createPipe)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: IO TestTree
tests = do
  user <- getEffectiveUserID
  pure $ testGroup "attachments"
    [ testGroup "declarations" declarations
    , testGroup "staging leftovers" leftovers
    , if user == 0
        then testCase
          "SKIPPED, the superuser is never refused a removal: a refused cleanup"
          (pure ())
        else testCase "a refused cleanup does not replace the refusal reported"
          refusalSurvivesRefusedCleanup
    ]

digest :: Char -> T.Text
digest = T.replicate 64 . T.singleton

declarations :: [TestTree]
declarations =
  [ testCase "sorted, distinct digests are accepted as given" $ do
      let list = [Attachment (digest 'a') 0, Attachment (digest 'b') 7]
      validateAttachments list @?= Right list
  , testCase "digests out of order are refused" $
      assertBool "refused" $ isLeft $
        validateAttachments [Attachment (digest 'b') 1, Attachment (digest 'a') 1]
  , testCase "a repeated digest is refused" $
      assertBool "refused" $ isLeft $
        validateAttachments [Attachment (digest 'a') 1, Attachment (digest 'a') 2]
  , testCase "an upper-case digest is refused" $
      assertBool "refused" (isLeft (validateAttachments [Attachment (digest 'A') 1]))
  , testCase "a short digest is refused" $
      assertBool "refused" $ isLeft $
        validateAttachments [Attachment (T.replicate 63 "a") 1]
  , testCase "a negative size is refused" $
      assertBool "refused" (isLeft (validateAttachments [Attachment (digest 'a') (-1)]))
  ]

leftovers :: [TestTree]
leftovers =
  [ testCase "the name the system gives a staging directory is one" $
      -- Copied from a directory a killed put left behind.
      isStagingLeftover "95428-0.spool-attachment-stage" @?= True
  , testCase "a name with the template in front is one" $
      isStagingLeftover ".spool-attachment-stage95428-0" @?= True
  , testCase "a task's directory is not one" $
      isStagingLeftover "task-one" @?= False
  , testCase "a task whose ID ends like a staging directory is not one" $
      isStagingLeftover "task-lookalike.spool-attachment-stage" @?= False
  ]

-- | No sequence of commands can make the removal of a temporary file fail at
-- the moment an attachment is refused, so the integration suite cannot reach
-- this.  Here the source is a pipe: the receiver has made its temporary file
-- and is waiting on the pipe when the directory is closed to writing, so the
-- removal that follows the refusal is itself refused.
refusalSurvivesRefusedCleanup :: IO ()
refusalSurvivesRefusedCleanup = do
  base <- getTemporaryDirectory
  bracket (mkdtemp (base </> "spool-cleanup-test")) removeDirectoryRecursive $
    \scratch -> do
      let workerRoot = scratch </> "attachments"
          -- A well-formed declaration that an empty stream cannot satisfy.
          declared = Attachment (digest '0') 1
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
      remaining <- listDirectory workerRoot
      when (null remaining) $
        assertFailure "the removal was not refused, so nothing was proven"
      case result of
        Right (Left "attachment sha256 does not match declaration") -> pure ()
        other -> assertFailure
          ("a refused cleanup replaced the refusal being reported: " <> show other)

-- | Wait for the receiver to create its temporary file, which it does just
-- before it starts reading the pipe.  Nothing else is ever in the directory,
-- so any entry is that file, whatever it is called.
awaitTemporary :: FilePath -> Int -> IO ()
awaitTemporary directory attempts = do
  names <- either (const []) id <$> tryList
  when (null names) $ do
    when (attempts <= 0) $
      assertFailure "the receiver never created its temporary file"
    threadDelay 10000
    awaitTemporary directory (attempts - 1)
  where
    tryList :: IO (Either IOError [FilePath])
    tryList = try (listDirectory directory)
