{-# LANGUAGE OverloadedStrings #-}

-- | The protocol's identifiers, each its own type.
--
-- A value of one of these types has passed its grammar: the only way to make
-- one is the function that checks it.  Code that holds a 'TaskId' never checks
-- it again, and cannot pass it where a 'LeaseId' is wanted.
module Spool.Types
  ( TaskId
  , mkTaskId
  , taskIdText
  , Capability
  , mkCapability
  , capabilityText
  , LeaseId
  , mkLeaseId
  , newLeaseId
  , leaseIdText
  , leaseStarted
  , WorkerName
  , mkWorkerName
  , workerNameText
  , validatePeer
  , Retry (..)
  , retryFlag
  , StatusFormat (..)
  , Timestamp
  , timestamp
  , storedTimestamp
  , timestampText
  ) where

import Data.Aeson (ToJSON (..), ToJSONKey (..))
import Data.Aeson.Types (toJSONKeyText)
import qualified Data.Text as T
import Data.Time (UTCTime, defaultTimeLocale, formatTime)

-- | A name: 1 to 128 of ASCII letters, digits, @.@, @_@, and @-@.  Every
-- identifier a caller chooses is one, so that it is the same wherever it is
-- typed, is safe as a file name, and leaves a file name room for what the
-- spool adds to it.
nameChecked :: String -> Int -> T.Text -> Either String T.Text
nameChecked what longest value
  | T.null value = Left (what <> " must be non-empty")
  | T.length value > longest =
      Left (what <> " must be at most " <> show longest <> " characters")
  | T.all tokenChar value = Right value
  | otherwise =
      Left (what <> " must contain only ASCII letters, digits, '.', '_' or '-'")

-- | A name; @--@ is reserved.
newtype TaskId = TaskId T.Text
  deriving (Eq, Ord, Show)

mkTaskId :: T.Text -> Either String TaskId
mkTaskId value
  | T.isInfixOf "--" value = Left "task_id cannot contain --"
  | otherwise = TaskId <$> nameChecked "task_id" 128 value

taskIdText :: TaskId -> T.Text
taskIdText (TaskId value) = value

instance ToJSON TaskId where
  toJSON = toJSON . taskIdText

-- | @name\@version@, at most 128 characters in all.  Only the grammar is
-- checked; the name means whatever a worker's owner configured it to mean.
newtype Capability = Capability T.Text
  deriving (Eq, Ord, Show)

mkCapability :: T.Text -> Either String Capability
mkCapability value = case T.breakOn "@" value of
  (name, rest)
    | T.null rest -> Left "capability must be of the form name@version"
    | T.length value > 128 -> Left "capability must be at most 128 characters"
    | T.null name -> Left "capability name must be non-empty"
    | T.null version -> Left "capability version must be non-empty"
    | not (T.all tokenChar name) ->
        Left "capability name must match [A-Za-z0-9._-]+"
    | not (T.all versionChar version) ->
        Left "capability version must match [A-Za-z0-9.]+"
    | otherwise -> Right (Capability value)
    where
      version = T.drop 1 rest
      versionChar character = asciiAlphaNum character || character == '.'

capabilityText :: Capability -> T.Text
capabilityText (Capability value) = value

instance ToJSON Capability where
  toJSON = toJSON . capabilityText

instance ToJSONKey Capability where
  toJSONKey = toJSONKeyText capabilityText

-- | @lease_@ and then the characters of a name, at most 200 characters in
-- all.  A lease made here is @lease_MICROS_SERIAL_TASK@, and that form is
-- this spool's own: a holder gives the identifier back unchanged and reads
-- nothing from it.  One a caller names need only fit the grammar, and then
-- either matches a lease on file or does not.
newtype LeaseId = LeaseId T.Text
  deriving (Eq, Ord, Show)

mkLeaseId :: T.Text -> Either String LeaseId
mkLeaseId value
  | T.null value = Left "lease_id must be non-empty"
  | T.isInfixOf "--" value = Left "lease_id cannot contain --"
  | T.length value > 200 = Left "lease_id must be at most 200 characters"
  | T.isPrefixOf "lease_" value && T.all tokenChar (T.drop 6 value) =
      Right (LeaseId value)
  | otherwise = Left "lease_id is invalid"

-- | The identifier of a lease taken at this many microseconds since the
-- epoch, with this serial number, on this task.
newLeaseId :: Integer -> Integer -> TaskId -> LeaseId
newLeaseId micros serial task = LeaseId
  ("lease_" <> T.pack (show micros) <> "_" <> T.pack (show serial)
    <> "_" <> taskIdText task)

leaseIdText :: LeaseId -> T.Text
leaseIdText (LeaseId value) = value

-- | When the lease was taken, in microseconds since the epoch, as its
-- identifier records it.
leaseStarted :: LeaseId -> Maybe Integer
leaseStarted (LeaseId value) =
  case reads (T.unpack (T.takeWhile asciiDigit (T.drop 6 value))) of
    [(number, "")] -> Just number
    _ -> Nothing

instance ToJSON LeaseId where
  toJSON = toJSON . leaseIdText

-- | Who is leasing: a name of at most 64 characters, the same wherever it
-- is given, as an argument, in a grant, or in a lease.
newtype WorkerName = WorkerName T.Text
  deriving (Eq, Ord, Show)

mkWorkerName :: T.Text -> Either String WorkerName
mkWorkerName = fmap WorkerName . nameChecked "worker" 64

workerNameText :: WorkerName -> T.Text
workerNameText (WorkerName value) = value

-- | A peer is a label for a person to read, never compared or made into a
-- path: 1 to 128 characters, none of them a control character.
validatePeer :: T.Text -> Either String ()
validatePeer value
  | T.null value = Left "peer must be non-empty"
  | T.length value > 128 = Left "peer must be at most 128 characters"
  | T.all printable value = Right ()
  | otherwise = Left "peer must not contain control characters"
  where
    printable character = character >= ' ' && character /= '\DEL'

instance ToJSON WorkerName where
  toJSON = toJSON . workerNameText

-- | Whether a failed task goes back to pending.
data Retry = Retry | NoRetry
  deriving (Eq, Show)

-- | The @retried@ field of a failure record.
retryFlag :: Retry -> Bool
retryFlag Retry = True
retryFlag NoRetry = False

-- | How @status@ prints its counters.
data StatusFormat = StatusText | StatusJson
  deriving (Eq, Show)

-- | When something happened, as a record carries it: UTC to the second,
-- written so that the order of the text is the order of the times.
newtype Timestamp = Timestamp T.Text
  deriving (Eq, Ord, Show)

timestamp :: UTCTime -> Timestamp
timestamp = Timestamp . T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

-- | A time read back from the spool's own files, taken as it was written.
storedTimestamp :: T.Text -> Timestamp
storedTimestamp = Timestamp

timestampText :: Timestamp -> T.Text
timestampText (Timestamp value) = value

instance ToJSON Timestamp where
  toJSON = toJSON . timestampText

tokenChar :: Char -> Bool
tokenChar character = asciiAlphaNum character || character `elem` ("._-" :: String)

asciiAlphaNum :: Char -> Bool
asciiAlphaNum character =
  ('a' <= character && character <= 'z') ||
  ('A' <= character && character <= 'Z') ||
  asciiDigit character

asciiDigit :: Char -> Bool
asciiDigit character = '0' <= character && character <= '9'
