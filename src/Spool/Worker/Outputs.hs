{-# LANGUAGE OverloadedStrings #-}

-- | What a program leaves to be sent back with its result (ADR 0020): each
-- file in outputs/ below its working directory, named by its own SHA-256,
-- as each attachment a task carries arrives at attachments/SHA256.
--
-- Nothing in outputs/ is followed. An entry that is not a regular file is
-- refused, a symbolic link above all, and so is a file whose name is not
-- the digest of what it holds. Each refusal is the program's doing, and
-- fails its run for good.
module Spool.Worker.Outputs
  ( Entry (..)
  , Kind (..)
  , judgeOutputs
  , collectOutputs
  , openOutput
  ) where

import Control.Exception (IOException, displayException, onException, throwIO, try)
import Control.Monad (forM, unless)
import Data.Int (Int64)
import Data.List (sortOn)
import qualified Data.Text as T
import System.Directory (listDirectory)
import System.FilePath ((</>))
import System.IO (Handle, hClose)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files
  ( FileStatus
  , fileSize
  , getFdStatus
  , getSymbolicLinkStatus
  , isDirectory
  , isRegularFile
  , isSymbolicLink
  )
import System.Posix.IO
  ( OpenFileFlags (cloexec, nofollow)
  , OpenMode (ReadOnly)
  , closeFd
  , defaultFileFlags
  , fdToHandle
  , openFd
  )
import qualified Spool.Attachments as SA

-- | What lstat says an entry of outputs/ is.
data Kind = Regular Int64 | Link | Directory | Other
  deriving (Eq, Show)

data Entry = Entry
  { entryName :: FilePath
  , entryKind :: Kind
  } deriving (Eq, Show)

-- | Which entries of outputs/ are to be sent, by digest and size, sorted, or
-- why the run fails. A capability without a limit may leave nothing there;
-- one with a limit may leave regular files named by digests, together no
-- larger than it.
judgeOutputs :: Maybe Int64 -> [Entry] -> Either T.Text [(SA.Sha256, Int64)]
judgeOutputs limit entries = do
  case (limit, entries) of
    (Nothing, _ : _) -> Left
      "outputs/ is not empty, and the capability sets no max_result_attachment_bytes"
    _ -> Right ()
  files <- mapM sendable entries
  let total = sum (map (toInteger . snd) files)
  case limit of
    Just most | total > toInteger most -> Left
      ("outputs/ holds " <> shown total <> " bytes, over max_result_attachment_bytes "
        <> shown most)
    _ -> Right (sortOn fst files)
  where
    sendable (Entry name kind) = case kind of
      Regular size -> case SA.mkSha256 (T.pack name) of
        Right digest -> Right (digest, size)
        Left _ -> Left (named name <> " is not named by a sha256 digest")
      Link -> Left (named name <> " is a symbolic link")
      Directory -> Left (named name <> " is a directory")
      Other -> Left (named name <> " is not a regular file")
    named name = "outputs/" <> T.pack name
    shown :: Show a => a -> T.Text
    shown = T.pack . show

-- | The files a run left in this outputs/ directory, judged, and each
-- hashed to prove it is what its name says: the attachments to send, with
-- where each is. An outputs/ that is not there is empty.
collectOutputs :: Maybe Int64 -> FilePath -> IO (Either T.Text [(SA.Attachment, FilePath)])
collectOutputs limit directory = do
  status <- lstat directory
  case status of
    Left exception
      | isDoesNotExistError exception -> pure (Right [])
      | otherwise -> pure (Left (failure "outputs/" exception))
    Right found
      | not (isDirectory found) -> pure (Left "outputs is not a directory")
      | otherwise -> do
          listed <- try (listDirectory directory >>= mapM entry)
          case listed of
            Left exception -> pure (Left (failure "outputs/" exception))
            Right entries -> case judgeOutputs limit entries of
              Left reason -> pure (Left reason)
              Right files -> verified files
  where
    entry name = do
      found <- getSymbolicLinkStatus (directory </> name)
      pure (Entry name (kindOf found))
    verified files = do
      checked <- forM files $ \(digest, size) -> do
        let path = directory </> T.unpack (SA.sha256Text digest)
            attachment = SA.Attachment digest size
        read' <- try (openOutput path >>= \handle ->
          (SA.verifyHandle attachment handle `onException` hClose handle)
            <* hClose handle)
        pure $ case read' of
          Left exception -> Left (failure ("outputs/" <> SA.sha256Text digest) exception)
          Right (Left _) -> Left ("outputs/" <> SA.sha256Text digest
            <> " does not hash to its name")
          Right (Right ()) -> Right (attachment, path)
      pure (sequence checked)
    failure what exception = what <> ": " <> T.pack (displayException (exception :: IOException))

lstat :: FilePath -> IO (Either IOException FileStatus)
lstat = try . getSymbolicLinkStatus

kindOf :: FileStatus -> Kind
kindOf status
  | isSymbolicLink status = Link
  | isRegularFile status = Regular (fromIntegral (fileSize status))
  | isDirectory status = Directory
  | otherwise = Other

-- | Open a file in outputs/ to read, refusing a symbolic link in its place
-- and anything else that is not a regular file, whatever lstat said a
-- moment before.
openOutput :: FilePath -> IO Handle
openOutput path = do
  fd <- openFd path ReadOnly defaultFileFlags { nofollow = True, cloexec = True }
  status <- getFdStatus fd `onException` closeFd fd
  unless (isRegularFile status) $ do
    closeFd fd
    throwIO (userError (path <> " is not a regular file"))
  fdToHandle fd
