{-# LANGUAGE OverloadedStrings #-}

-- | The atomic, synced file operations every transition is built from.  No
-- test can show that bytes survive a power loss; these show that each
-- operation does what it says on a real file system, and that a synced
-- handle is closed by the sync.
module Test.Files (tests) where

import Control.Exception (IOException, bracket, try)
import qualified Data.ByteString as BS
import Data.Either (isLeft)
import Spool.Files
  ( Created (..)
  , atomicCreate
  , atomicReplace
  , syncDirectory
  , syncHandle
  , syncedRemove
  , syncedRename
  )
import System.Directory (createDirectoryIfMissing, doesFileExist,
                         getTemporaryDirectory, listDirectory,
                         removeDirectoryRecursive)
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), hPutStr, openBinaryFile)
import System.Posix.Temp (mkdtemp)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests = testGroup "files"
  [ testCase "a file is created whole and then found already there" $ inScratch $ \scratch -> do
      let path = scratch </> "one.json"
      first <- atomicCreate path "first"
      first @?= Created
      second <- atomicCreate path "second"
      second @?= AlreadyThere
      BS.readFile path >>= (@?= "first")
      listDirectory scratch >>= (@?= ["one.json"])
  , testCase "a file is replaced whole and nothing is left beside it" $ inScratch $ \scratch -> do
      let path = scratch </> "sequence"
      atomicReplace path "1\n"
      atomicReplace path "2\n"
      BS.readFile path >>= (@?= "2\n")
      listDirectory scratch >>= (@?= ["sequence"])
  , testCase "a synced rename moves the file between directories" $ inScratch $ \scratch -> do
      _ <- atomicCreate (scratch </> "pending" </> "t.json") "task"
      createDirectoryIfMissing True (scratch </> "leased")
      syncedRename (scratch </> "pending" </> "t.json") (scratch </> "leased" </> "t.json")
      doesFileExist (scratch </> "pending" </> "t.json") >>= (@?= False)
      BS.readFile (scratch </> "leased" </> "t.json") >>= (@?= "task")
  , testCase "a synced remove removes the file" $ inScratch $ \scratch -> do
      _ <- atomicCreate (scratch </> "gone.json") "bytes"
      syncedRemove (scratch </> "gone.json")
      listDirectory scratch >>= (@?= [])
  , testCase "a directory can be synced" $ inScratch syncDirectory
  , testCase "a synced handle has been written through and is closed" $ inScratch $ \scratch -> do
      let path = scratch </> "written"
      handle <- openBinaryFile path WriteMode
      hPutStr handle "through"
      syncHandle handle
      BS.readFile path >>= (@?= "through")
      again <- try (hPutStr handle "more") :: IO (Either IOException ())
      assertBool "the handle is closed" (isLeft again)
  ]

inScratch :: (FilePath -> IO a) -> IO a
inScratch action = do
  base <- getTemporaryDirectory
  bracket (mkdtemp (base </> "spool-files-test")) removeDirectoryRecursive $
    action
