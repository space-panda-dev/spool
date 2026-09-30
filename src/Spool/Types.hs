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
  , workerNameFromArgument
  , workerNameFromGrant
  , storedWorkerName
  , workerNameText
  , Retry (..)
  , retryFlag
  , StatusFormat (..)
  ) where

import Data.Aeson (ToJSON (..), ToJSONKey (..))
import Data.Aeson.Types (toJSONKeyText)
import qualified Data.Text as T

-- | ASCII letters, digits, @.@, @_@, and @-@; @--@ is reserved.
newtype TaskId = TaskId T.Text
  deriving (Eq, Ord, Show)

mkTaskId :: T.Text -> Either String TaskId
mkTaskId value
  | T.null value = Left "task_id must be non-empty"
  | T.isInfixOf "--" value = Left "task_id cannot contain --"
  | T.all tokenChar value = Right (TaskId value)
  | otherwise = Left "task_id must contain only ASCII letters, digits, '.', '_' or '-'"

taskIdText :: TaskId -> T.Text
taskIdText (TaskId value) = value

instance ToJSON TaskId where
  toJSON = toJSON . taskIdText

-- | @name\@version@.  Only the grammar is checked; the name means whatever
-- a worker's owner configured it to mean.
newtype Capability = Capability T.Text
  deriving (Eq, Ord, Show)

mkCapability :: T.Text -> Either String Capability
mkCapability value = case T.breakOn "@" value of
  (name, rest)
    | T.null rest -> Left "capability must be of the form name@version"
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

-- | @lease_@ and then the characters of a task identifier.  A lease made here
-- is @lease_MICROS_SERIAL_TASK@; one a caller names need only fit the
-- grammar, and then either matches a lease on file or does not.
newtype LeaseId = LeaseId T.Text
  deriving (Eq, Ord, Show)

mkLeaseId :: T.Text -> Either String LeaseId
mkLeaseId value
  | T.null value = Left "lease_id must be non-empty"
  | T.isInfixOf "--" value = Left "lease_id cannot contain --"
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

-- | Who is leasing.  Two rules admit a name, and they differ: a name given as
-- an argument may hold no whitespace, and a name in a grant may hold no
-- control character.  The protocol states neither, so both stand until it
-- does, each under its own name here.
newtype WorkerName = WorkerName T.Text
  deriving (Eq, Ord, Show)

-- | A name from the command line: non-empty, with no space, tab, or line end.
workerNameFromArgument :: String -> Either String WorkerName
workerNameFromArgument value
  | not (null value) && all (`notElem` ['\n', '\r', '\t', ' ']) value =
      Right (WorkerName (T.pack value))
  | otherwise = Left "worker must be a non-empty token"

-- | A name from a grant record: non-empty, with no control character.
workerNameFromGrant :: T.Text -> Either String WorkerName
workerNameFromGrant value
  | T.null value = Left "worker must be non-empty"
  | T.all printable value = Right (WorkerName value)
  | otherwise = Left "worker must not contain control characters"
  where
    printable character = character >= ' ' && character /= '\DEL'

-- | A name read back from the spool's own files, taken as it was written.
-- It passed one of the two rules when it was recorded.
storedWorkerName :: T.Text -> WorkerName
storedWorkerName = WorkerName

workerNameText :: WorkerName -> T.Text
workerNameText (WorkerName value) = value

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

tokenChar :: Char -> Bool
tokenChar character = asciiAlphaNum character || character `elem` ("._-" :: String)

asciiAlphaNum :: Char -> Bool
asciiAlphaNum character =
  ('a' <= character && character <= 'z') ||
  ('A' <= character && character <= 'Z') ||
  asciiDigit character

asciiDigit :: Char -> Bool
asciiDigit character = '0' <= character && character <= '9'
