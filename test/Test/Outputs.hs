{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | What a program leaves in outputs/: which entries are sent, under which
-- limit, and every way an entry is refused, on a real directory as well as
-- in the pure decision.
module Test.Outputs (tests) where

import Control.Exception (IOException, bracket, try)
import qualified Data.ByteString as BS
import Data.Int (Int64)
import qualified Data.Text as T
import Spool.Attachments (Attachment (..), Sha256, mkSha256, sha256Text)
import Spool.Worker.Outputs
  ( Entry (..)
  , Kind (..)
  , collectOutputs
  , judgeOutputs
  , openOutput
  )
import System.Directory (createDirectory, getTemporaryDirectory,
                         removeDirectoryRecursive)
import System.FilePath ((</>))
import System.Posix.Files (createNamedPipe, createSymbolicLink)
import System.Posix.Temp (mkdtemp)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests = testGroup "outputs"
  [ testGroup "the decision" decisions
  , testGroup "a real directory" directories
  ]

-- | The digests of "abc" and of nothing, from FIPS 180-2 and known
-- independently of the code under test.
abc, empty :: Sha256
abc = digest "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
empty = digest "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

digest :: T.Text -> Sha256
digest = either error id . mkSha256

name :: Sha256 -> FilePath
name = T.unpack . sha256Text

decisions :: [TestTree]
decisions =
  [ testCase "nothing left is nothing to send, with or without a limit" $ do
      judgeOutputs Nothing [] @?= Right []
      judgeOutputs (Just 1) [] @?= Right []
  , testCase "a capability without a limit may leave nothing" $
      refusedWith "max_result_attachment_bytes" (judgeOutputs Nothing [Entry (name abc) (Regular 3)])
  , testCase "files named by their digests are sent, sorted" $
      judgeOutputs (Just 3) [Entry (name abc) (Regular 3), Entry (name empty) (Regular 0)]
        @?= Right [(abc, 3), (empty, 0)]
  , testCase "files may fill the limit exactly" $
      judgeOutputs (Just 3) [Entry (name abc) (Regular 3)] @?= Right [(abc, 3)]
  , testCase "files one byte past the limit are refused" $
      refusedWith "over max_result_attachment_bytes 2"
        (judgeOutputs (Just 2) [Entry (name abc) (Regular 3)])
  , testCase "the limit is on all the files together" $
      refusedWith "holds 6 bytes"
        (judgeOutputs (Just 5) [Entry (name abc) (Regular 3), Entry (name empty) (Regular 3)])
  , testCase "a symbolic link is refused" $
      refusedWith "is a symbolic link" (judgeOutputs (Just 9) [Entry (name abc) Link])
  , testCase "a directory is refused" $
      refusedWith "directory" (judgeOutputs (Just 9) [Entry (name abc) Directory])
  , testCase "anything else that is not a regular file is refused" $
      refusedWith "not a regular file" (judgeOutputs (Just 9) [Entry (name abc) Other])
  , testGroup "a file not named by a digest is refused"
      [ testCase label $ refusedWith "not named by a sha256 digest"
          (judgeOutputs (Just 9) [Entry entry (Regular 3)])
      | (label, entry) <-
          [ ("a filename", "vocals.flac")
          , ("upper case", map toUpperHex (name abc))
          , ("a digest with an extension", name abc <> ".flac")
          , ("a short digest", take 63 (name abc))
          ]
      ]
  ]
  where
    toUpperHex character
      | character >= 'a' && character <= 'f' = toEnum (fromEnum character - 32)
      | otherwise = character

refusedWith :: T.Text -> Either T.Text a -> Assertion
refusedWith expected outcome = case outcome of
  Left reason -> assertBool ("the reason says " <> show expected <> ": " <> show reason)
    (expected `T.isInfixOf` reason)
  Right _ -> assertFailure "accepted"

directories :: [TestTree]
directories =
  [ testCase "no outputs/ is nothing to send" $ inScratch $ \scratch ->
      collected Nothing (scratch </> "outputs") >>= (@?= Right [])
  , testCase "a file is sent once it hashes to its name" $ inScratch $ \scratch -> do
      outputs <- made scratch
      BS.writeFile (outputs </> name abc) "abc"
      BS.writeFile (outputs </> name empty) ""
      collected (Just 3) outputs >>= (@?= Right
        [(Attachment abc 3, outputs </> name abc), (Attachment empty 0, outputs </> name empty)])
  , testCase "a file whose bytes are not its name is refused" $ inScratch $ \scratch -> do
      outputs <- made scratch
      BS.writeFile (outputs </> name abc) "abd"
      collected (Just 3) outputs >>= refusedWith "does not hash to its name"
  , testCase "a link named by the digest of what it points at is still refused" $
      inScratch $ \scratch -> do
        outputs <- made scratch
        BS.writeFile (scratch </> "elsewhere") "abc"
        createSymbolicLink (scratch </> "elsewhere") (outputs </> name abc)
        collected (Just 3) outputs >>= refusedWith "is a symbolic link"
  , testCase "a directory in outputs/ is refused" $ inScratch $ \scratch -> do
      outputs <- made scratch
      createDirectory (outputs </> name abc)
      collected (Just 3) outputs >>= refusedWith "directory"
  , testCase "a named pipe in outputs/ is refused, and not opened" $ inScratch $ \scratch -> do
      outputs <- made scratch
      createNamedPipe (outputs </> name abc) 0o600
      collected (Just 3) outputs >>= refusedWith "not a regular file"
  , testCase "outputs that is a link to a directory is refused" $ inScratch $ \scratch -> do
      createDirectory (scratch </> "real")
      BS.writeFile (scratch </> "real" </> name abc) "abc"
      createSymbolicLink (scratch </> "real") (scratch </> "outputs")
      collected (Just 3) (scratch </> "outputs") >>= refusedWith "not a directory"
  , testCase "outputs that is a file is refused" $ inScratch $ \scratch -> do
      BS.writeFile (scratch </> "outputs") "abc"
      collected (Just 3) (scratch </> "outputs") >>= refusedWith "not a directory"
  , testCase "opening a file to send refuses a link put in its place" $ inScratch $ \scratch -> do
      BS.writeFile (scratch </> "elsewhere") "abc"
      createSymbolicLink (scratch </> "elsewhere") (scratch </> "link")
      opened <- try (openOutput (scratch </> "link"))
      case opened of
        Left (_ :: IOException) -> pure ()
        Right _ -> assertFailure "a symbolic link was opened"
  , testCase "the files of a capability without a limit are refused before they are read" $
      inScratch $ \scratch -> do
        outputs <- made scratch
        createNamedPipe (outputs </> name abc) 0o600
        collected Nothing outputs >>= refusedWith "max_result_attachment_bytes"
  ]
  where
    made scratch = do
      createDirectory (scratch </> "outputs")
      pure (scratch </> "outputs")
    collected :: Maybe Int64 -> FilePath -> IO (Either T.Text [(Attachment, FilePath)])
    collected = collectOutputs

inScratch :: (FilePath -> IO ()) -> IO ()
inScratch action = do
  base <- getTemporaryDirectory
  bracket (mkdtemp (base </> "spool-outputs-test")) removeDirectoryRecursive action
