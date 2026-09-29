{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The attachment boundary for the file-backed spool.
--
-- This module deliberately does not know about task records or leases; of a
-- task it knows only the identifier.  It owns the small, digest-addressed
-- file operation which those records use:
-- declarations are strict, copies are staged before they become visible, and
-- received bytes are verified before they are renamed into a worker's fresh
-- directory.
module Spool.Attachments
  ( Attachment (..)
  , Sha256
  , mkSha256
  , sha256Text
  , validateAttachments
  , attachmentDirectory
  , attachmentPath
  , stageAttachments
  , isStagingLeftover
  , receiveAttachment
  , verifyAttachmentFile
  , attemptRemoveWorkerDirectory
  ) where

import Control.Exception (IOException, bracket, onException, try)
import Control.Monad (forM_, unless, when)
import Crypto.Hash (Context, Digest, SHA256, hashFinalize, hashInit,
                    hashUpdate)
import Data.Aeson (FromJSON (..), ToJSON (..), Value, (.:), (.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Aeson.Types as AT
import qualified Data.ByteString as BS
import Data.Int (Int64)
import Data.List (isInfixOf, isPrefixOf, nub, sort)
import qualified Data.Text as T
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive,
                         removeFile, renameDirectory, renameFile)
import System.FilePath ((</>))
import System.IO (Handle, IOMode (ReadMode), hClose, hFlush,
                  openBinaryFile, openBinaryTempFile)
import System.IO.Error (isDoesNotExistError)
import Spool.Types (TaskId, taskIdText)

-- | A SHA-256 digest as a declaration carries it: 64 lower-case hexadecimal
-- characters.  It is safe as a file name, which is what it is used for.
newtype Sha256 = Sha256 T.Text
  deriving (Eq, Ord, Show)

mkSha256 :: T.Text -> Either String Sha256
mkSha256 value
  | T.length value == 64 && T.all lowerHex value = Right (Sha256 value)
  | otherwise = Left "sha256 must be 64 lower-case hexadecimal characters"
  where
    lowerHex character = character >= '0' && character <= '9'
      || character >= 'a' && character <= 'f'

sha256Text :: Sha256 -> T.Text
sha256Text (Sha256 value) = value

instance ToJSON Sha256 where
  toJSON = toJSON . sha256Text

-- | An attachment declaration is deliberately only a digest and a byte
-- count.  There is no caller filename or path in the protocol.
data Attachment = Attachment
  { attachmentSha256 :: Sha256
  , attachmentSize :: Int64
  } deriving (Eq, Ord, Show)

instance ToJSON Attachment where
  toJSON attachment =
    A.object
      [ "sha256" .= attachmentSha256 attachment
      , "size" .= attachmentSize attachment
      ]

instance FromJSON Attachment where
  parseJSON = parseAttachment

-- | Parse one declaration, rejecting unknown or missing fields.  List-level
-- ordering and uniqueness are checked by 'validateAttachments'.
parseAttachment :: Value -> AT.Parser Attachment
parseAttachment = A.withObject "attachment" $ \object -> do
  let expected = sort [K.fromText "sha256", K.fromText "size"]
      actual = sort (KM.keys object)
  unless (actual == expected) $
    fail "attachment must contain exactly sha256 and size"
  digest <- either fail pure . mkSha256 =<< object .: "sha256"
  size <- object .: "size"
  case validateAttachment (Attachment digest size) of
    Left message -> fail message
    Right () -> pure (Attachment digest size)

-- | Validate a canonical declaration list.  The input must already be
-- strictly sorted and contain no duplicate digest.
validateAttachments :: [Attachment] -> Either String [Attachment]
validateAttachments attachments = do
  forM_ attachments validateAttachment
  let digests = map attachmentSha256 attachments
  when (digests /= sort digests) $
    Left "attachments must be sorted by sha256"
  when (length digests /= length (nub digests)) $
    Left "attachments must have unique sha256 digests"
  pure attachments

validateAttachment :: Attachment -> Either String ()
validateAttachment attachment =
  unless (attachmentSize attachment >= 0) $
    Left "attachment size must be non-negative"

-- | A task's directory beneath the attachment root.  Its name has a fixed
-- prefix and an identifier whose grammar admits no separator, so it cannot
-- leave the root.
attachmentDirectory :: FilePath -> TaskId -> FilePath
attachmentDirectory root task = root </> ("task-" <> T.unpack (taskIdText task))

attachmentPath :: FilePath -> TaskId -> Attachment -> FilePath
attachmentPath root task attachment =
  attachmentDirectory root task </> digestName attachment

-- | The file name an attachment goes by: its digest.
digestName :: Attachment -> FilePath
digestName = T.unpack . sha256Text . attachmentSha256

-- | The template for a staging directory's name.  The name itself is the
-- system's to choose, and it puts its unique part in front of a template that
-- begins with a dot: "12345-0.spool-attachment-stage".
stagingTemplate :: String
stagingTemplate = ".spool-attachment-stage"

-- | Whether an entry in the attachment root is a staging directory left by an
-- interrupted put.  The template is looked for anywhere in the name, so the
-- answer does not rest on where the system puts its unique part.  A task's
-- own directory is never one, whatever its ID contains.
isStagingLeftover :: FilePath -> Bool
isStagingLeftover name =
  stagingTemplate `isInfixOf` name && not ("task-" `isPrefixOf` name)

-- | Stage all source files into a temporary directory and atomically publish
-- the task directory.  A failed digest leaves no visible task directory.
-- Existing destination directories are never removed or overwritten.
stageAttachments :: FilePath -> FilePath -> TaskId
                 -> [Attachment] -> IO (Either String ())
stageAttachments attachmentRoot sourceRoot task attachments = do
  validated <- pure (validateAttachments attachments)
  case validated of
    Left message -> pure (Left message)
    Right [] -> pure (Right ())
    Right declarations -> do
      let destination = attachmentDirectory attachmentRoot task
      createDirectoryIfMissing True attachmentRoot
      (temporary, handle) <- openBinaryTempFile attachmentRoot stagingTemplate
      hClose handle
      removeFile temporary
      createDirectoryIfMissing True temporary
      result <- stageFiles temporary sourceRoot declarations
        `onException` removeDirectoryRecursive temporary
      case result of
        Left message -> do
          removeDirectoryRecursive temporary
          pure (Left message)
        Right () -> do
          renameDirectory temporary destination
            `onException` removeDirectoryRecursive temporary
          pure (Right ())

stageFiles :: FilePath -> FilePath -> [Attachment] -> IO (Either String ())
stageFiles temporary sourceRoot declarations = do
  go declarations
  where
    go [] = pure (Right ())
    go (attachment : rest) = do
      let source = sourceRoot </> digestName attachment
          destination = temporary </> digestName attachment
      checked <- copyVerified attachment source temporary destination
      case checked of
        Left message -> pure (Left message)
        Right () -> go rest

-- | Receive exactly one attachment stream into a worker directory.  The
-- caller supplies a handle connected to the fetch response.  The destination
-- is renamed only after both digest and size match the declaration.
receiveAttachment :: FilePath -> Attachment -> Handle -> IO (Either String ())
receiveAttachment workerAttachmentRoot attachment source = do
  validated <- pure (validateAttachment attachment)
  case validated of
    Left message -> pure (Left message)
    Right () -> do
      createDirectoryIfMissing True workerAttachmentRoot
      let destination = workerAttachmentRoot </> digestName attachment
      (temporary, handle) <- openBinaryTempFile workerAttachmentRoot ".spool-attachment-receive"
      result <- try (receiveInto handle source)
      hClose handle
      case result of
        Left (exception :: IOException) -> do
          discardTemporary temporary
          ioError exception
        Right checked -> case checked of
          Left message -> do
            discardTemporary temporary
            pure (Left message)
          Right () -> do
            published <- try (renameFile temporary destination)
            case published of
              Left (exception :: IOException) -> do
                discardTemporary temporary
                ioError exception
              Right () -> pure (Right ())
  where
    receiveInto handle sourceHandle = do
      (context, size) <- copyStream sourceHandle handle hashInit 0
      hFlush handle
      pure (verifyDigest attachment context size)

-- | Check an existing file without copying it.
verifyAttachmentFile :: Attachment -> FilePath -> IO (Either String ())
verifyAttachmentFile attachment path = do
  validated <- pure (validateAttachment attachment)
  case validated of
    Left message -> pure (Left message)
    Right () -> withBinaryFile path $ \handle -> do
      (context, size) <- hashStream handle hashInit 0
      pure (verifyDigest attachment context size)

copyVerified :: Attachment -> FilePath -> FilePath -> FilePath -> IO (Either String ())
copyVerified attachment source temporary destination = do
  sourceHandle <- openBinaryFile source ReadMode
  (temporaryFile, destinationHandle) <- openBinaryTempFile temporary ".spool-attachment-copy"
  result <- try $ do
    (context, size) <- copyStream sourceHandle destinationHandle hashInit 0
    hFlush destinationHandle
    pure (verifyDigest attachment context size)
  hClose sourceHandle
  hClose destinationHandle
  case result of
    Left (exception :: IOException) -> do
      discardTemporary temporaryFile
      ioError exception
    Right (Left message) -> do
      discardTemporary temporaryFile
      pure (Left message)
    Right (Right ()) -> do
      renameFile temporaryFile destination
      pure (Right ())

-- | Remove a temporary file on the way out of a failure.  The failure already
-- in hand is the one to report, so a refusal here must not replace it.  The
-- file is not lost sight of: it lies in a directory whose own removal fails
-- loudly.
discardTemporary :: FilePath -> IO ()
discardTemporary path = do
  result <- try (removeFile path)
  case result of
    Left (_ :: IOException) -> pure ()
    Right () -> pure ()

withBinaryFile :: FilePath -> (Handle -> IO a) -> IO a
withBinaryFile path action = bracket (openBinaryFile path ReadMode) hClose action

hashStream :: Handle -> Context SHA256 -> Int64 -> IO (Context SHA256, Int64)
hashStream handle context size = do
  bytes <- BS.hGetSome handle (64 * 1024)
  if BS.null bytes
    then pure (context, size)
    else do
      nextSize <- checkedAdd size (fromIntegral (BS.length bytes))
      hashStream handle (hashUpdate context bytes) nextSize

copyStream :: Handle -> Handle -> Context SHA256 -> Int64
           -> IO (Context SHA256, Int64)
copyStream source destination context size = do
  bytes <- BS.hGetSome source (64 * 1024)
  if BS.null bytes
    then pure (context, size)
    else do
      BS.hPut destination bytes
      nextSize <- checkedAdd size (fromIntegral (BS.length bytes))
      copyStream source destination (hashUpdate context bytes) nextSize

checkedAdd :: Int64 -> Int64 -> IO Int64
checkedAdd left right
  | right > maxBound - left = ioError (userError "attachment exceeds Int64 size")
  | otherwise = pure (left + right)

verifyDigest :: Attachment -> Context SHA256 -> Int64 -> Either String ()
verifyDigest attachment context size =
  let digest = renderDigest (hashFinalize context :: Digest SHA256)
  in if digest /= sha256Text (attachmentSha256 attachment)
       then Left "attachment sha256 does not match declaration"
       else if size /= attachmentSize attachment
         then Left "attachment size does not match declaration"
         else Right ()

-- | A digest shows as its lower-case hexadecimal, which is the form a
-- declaration carries.
renderDigest :: Digest SHA256 -> T.Text
renderDigest = T.pack . show

-- | Workers attempt to remove their entire fresh working directory after
-- every program exit.  Returning the exception lets the caller fail loudly
-- instead of silently claiming cleanup that did not happen.
attemptRemoveWorkerDirectory :: FilePath -> IO (Either IOException ())
attemptRemoveWorkerDirectory directory = do
  result <- try (removeDirectoryRecursive directory)
  pure (case result of
    Left exception | isMissing exception -> Right ()
    Left exception -> Left exception
    Right () -> Right ())

isMissing :: IOException -> Bool
isMissing = isDoesNotExistError
