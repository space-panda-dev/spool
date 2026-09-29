{-# LANGUAGE OverloadedStrings #-}

-- | The envelopes and records of the protocol: their shapes, their grammars,
-- and the one canonical encoding. Everything here is pure.
--
-- Each shape is a type, read by one function that checks every field and
-- refuses any it does not define.  What has been read is never looked into
-- as JSON again.
module Spool.Wire
  ( -- * A task and its lease
    Task (..)
  , Lease (..)
  , parseTask
    -- * What a worker sends
  , LeaseRef (..)
  , Ack (..)
  , FailRequest (..)
  , FetchRequest (..)
  , parseLeaseRef
  , parseAck
  , parseFail
  , parseFetchRequest
    -- * What the spool keeps
  , ResultRecord (..)
  , FailureRecord (..)
  , parseResultRecord
  , parseFailureRecord
    -- * What the spool answers
  , PutStatus (..)
  , AckStatus (..)
  , Counts (..)
  , encodePutResult
  , encodeAckResult
  , encodeRenewResult
  , encodeFailResult
  , encodeReclaimResult
    -- * Encoding
  , encode
  , canonical
    -- * For other parsers of strict objects
  , Object
  , rejectUnknown
  , readInteger
  ) where

import Data.Aeson (ToJSON (..), (.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.Foldable (toList)
import Data.List (sortOn)
import qualified Data.Text as T
import qualified Spool.Attachments as SA
import Spool.Types
  ( Capability
  , LeaseId
  , Retry (..)
  , TaskId
  , Timestamp
  , WorkerName
  , mkCapability
  , mkLeaseId
  , mkTaskId
  , retryFlag
  , storedTimestamp
  , storedWorkerName
  )

type Object = KM.KeyMap A.Value

data Task = Task
  { taskId :: TaskId
  , taskCapability :: Capability
  , taskPayload :: A.Value
  , taskAttachments :: [SA.Attachment]
  } deriving (Eq, Show)

instance ToJSON Task where
  toJSON task = A.object
    [ "task_id" .= taskId task
    , "capability" .= taskCapability task
    , "payload" .= taskPayload task
    , "attachments" .= taskAttachments task
    ]

data Lease = Lease
  { leaseTask :: Task
  , leaseId :: LeaseId
  , leaseWorker :: WorkerName
  , leaseTime :: Timestamp
  } deriving (Eq, Show)

instance ToJSON Lease where
  toJSON lease = A.object
    [ "task_id" .= taskId (leaseTask lease)
    , "capability" .= taskCapability (leaseTask lease)
    , "lease_id" .= leaseId lease
    , "worker" .= leaseWorker lease
    , "leased_at" .= leaseTime lease
    , "payload" .= taskPayload (leaseTask lease)
    , "attachments" .= taskAttachments (leaseTask lease)
    ]

-- | A task and the lease a worker claims to hold on it.  Every request a
-- worker sends names one.
data LeaseRef = LeaseRef
  { refTask :: TaskId
  , refLease :: LeaseId
  } deriving (Eq, Show)

data Ack = Ack
  { ackRef :: LeaseRef
  , ackResult :: A.Value
  } deriving (Eq, Show)

data FailRequest = FailRequest
  { failRef :: LeaseRef
  , failReason :: T.Text
  } deriving (Eq, Show)

data FetchRequest = FetchRequest
  { fetchRef :: LeaseRef
  , fetchDigest :: SA.Sha256
  } deriving (Eq, Show)

-- | The record of an acknowledged task, kept until whoever put the task
-- reads it.
data ResultRecord = ResultRecord
  { resultTask :: TaskId
  , resultLease :: LeaseId
  , resultCapability :: Capability
  , resultWorker :: WorkerName
  , resultFinishedAt :: Timestamp
  , resultValue :: A.Value
  } deriving (Eq, Show)

instance ToJSON ResultRecord where
  toJSON record = A.object
    [ "task_id" .= resultTask record
    , "lease_id" .= resultLease record
    , "capability" .= resultCapability record
    , "worker" .= resultWorker record
    , "finished_at" .= resultFinishedAt record
    , "result" .= resultValue record
    ]

-- | The record of one reported failure, whether or not the task went back
-- to pending.
data FailureRecord = FailureRecord
  { failureTask :: TaskId
  , failureLease :: LeaseId
  , failureCapability :: Capability
  , failureWorker :: WorkerName
  , failureFailedAt :: Timestamp
  , failureReason :: T.Text
  , failureRetried :: Retry
  } deriving (Eq, Show)

instance ToJSON FailureRecord where
  toJSON record = A.object
    [ "task_id" .= failureTask record
    , "lease_id" .= failureLease record
    , "capability" .= failureCapability record
    , "worker" .= failureWorker record
    , "failed_at" .= failureFailedAt record
    , "reason" .= failureReason record
    , "retried" .= retryFlag (failureRetried record)
    ]

data PutStatus = PutInserted | PutExisting deriving (Eq, Show)

data AckStatus = Acked | AlreadyDone deriving (Eq, Show)

-- | What @status@ counts: task files in three places, and failure records.
data Counts = Counts
  { countPending :: Int
  , countLeased :: Int
  , countDone :: Int
  , countFailed :: Int
  } deriving (Eq, Show)

instance ToJSON Counts where
  toJSON counts = A.object
    [ "pending" .= countPending counts
    , "leased" .= countLeased counts
    , "done" .= countDone counts
    , "failed" .= countFailed counts
    ]

-- | Read one JSON object that defines exactly these fields.  The name is
-- what the refusal calls the thing when it is not an object at all.
strictObject
  :: String -> [T.Text] -> (Object -> Either String a)
  -> BL.ByteString -> Either String a
strictObject name fields body bytes = do
  value <- A.eitherDecode bytes
  case value of
    A.Object object -> rejectUnknown fields object >> body object
    _ -> Left (name <> " must be a JSON object")

parseTask :: BL.ByteString -> Either String Task
parseTask = strictObject "task"
  ["task_id", "capability", "payload", "attachments"] $ \object -> do
    ident <- mkTaskId =<< requiredText "task_id" object
    capability <- mkCapability =<< requiredText "capability" object
    payload <- required "task is missing payload" "payload" object
    attachments <- case KM.lookup "attachments" object of
      Nothing -> Right []
      Just value -> case A.fromJSON value of
        A.Error message -> Left message
        A.Success declarations -> SA.validateAttachments declarations
    pure (Task ident capability payload attachments)

parseLeaseRef :: BL.ByteString -> Either String LeaseRef
parseLeaseRef = strictObject "lease reference" ["task_id", "lease_id"] $ \object -> do
  identText <- requiredText "task_id" object
  leaseText <- requiredText "lease_id" object
  leaseRef identText leaseText

parseAck :: BL.ByteString -> Either String Ack
parseAck = strictObject "ack" ["task_id", "lease_id", "result"] $ \object -> do
  identText <- requiredText "task_id" object
  leaseText <- requiredText "lease_id" object
  result <- required "ack is missing result" "result" object
  reference <- leaseRef identText leaseText
  pure (Ack reference result)

parseFail :: BL.ByteString -> Either String FailRequest
parseFail = strictObject "fail" ["task_id", "lease_id", "reason"] $ \object -> do
  identText <- requiredText "task_id" object
  leaseText <- requiredText "lease_id" object
  reason <- requiredText "reason" object
  reference <- leaseRef identText leaseText
  pure (FailRequest reference reason)

parseFetchRequest :: BL.ByteString -> Either String FetchRequest
parseFetchRequest = strictObject "fetch request"
  ["task_id", "lease_id", "sha256"] $ \object -> do
    identText <- requiredText "task_id" object
    leaseText <- requiredText "lease_id" object
    digestText <- requiredText "sha256" object
    reference <- leaseRef identText leaseText
    digest <- SA.mkSha256 digestText
    pure (FetchRequest reference digest)

-- | The two identifiers of a request, checked only once every field of the
-- request is known to be there, so that a missing field is what is reported
-- when a field is missing.
leaseRef :: T.Text -> T.Text -> Either String LeaseRef
leaseRef identText leaseText = LeaseRef <$> mkTaskId identText <*> mkLeaseId leaseText

parseResultRecord :: BL.ByteString -> Either String ResultRecord
parseResultRecord = strictObject "result record"
  ["task_id", "lease_id", "capability", "worker", "finished_at", "result"] $
  \object -> do
    (ident, lease, capability, worker) <- recordIdentity object
    finishedAt <- requiredText "finished_at" object
    result <- required "missing result" "result" object
    pure ResultRecord
      { resultTask = ident
      , resultLease = lease
      , resultCapability = capability
      , resultWorker = worker
      , resultFinishedAt = storedTimestamp finishedAt
      , resultValue = result
      }

parseFailureRecord :: BL.ByteString -> Either String FailureRecord
parseFailureRecord = strictObject "failure record"
  [ "task_id", "lease_id", "capability", "worker", "failed_at", "reason"
  , "retried" ] $
  \object -> do
    (ident, lease, capability, worker) <- recordIdentity object
    failedAt <- requiredText "failed_at" object
    reason <- requiredText "reason" object
    retried <- case KM.lookup "retried" object of
      Just (A.Bool True) -> Right Retry
      Just (A.Bool False) -> Right NoRetry
      Just _ -> Left "retried must be a boolean"
      Nothing -> Left "missing retried"
    pure FailureRecord
      { failureTask = ident
      , failureLease = lease
      , failureCapability = capability
      , failureWorker = worker
      , failureFailedAt = storedTimestamp failedAt
      , failureReason = reason
      , failureRetried = retried
      }

-- | What a result record and a failure record have in common.
recordIdentity :: Object -> Either String (TaskId, LeaseId, Capability, WorkerName)
recordIdentity object = do
  identText <- requiredText "task_id" object
  leaseText <- requiredText "lease_id" object
  capabilityText <- requiredText "capability" object
  worker <- requiredText "worker" object
  ident <- mkTaskId identText
  lease <- mkLeaseId leaseText
  capability <- mkCapability capabilityText
  pure (ident, lease, capability, storedWorkerName worker)

-- | A field that must be there and may hold any value, null included.
required :: String -> K.Key -> Object -> Either String A.Value
required refusal key object = maybe (Left refusal) Right (KM.lookup key object)

requiredText :: T.Text -> Object -> Either String T.Text
requiredText key object = case KM.lookup (K.fromText key) object of
  Nothing -> Left ("missing " <> T.unpack key)
  Just (A.String value)
    | T.null value -> Left (T.unpack key <> " must be non-empty")
    | otherwise -> Right value
  Just _ -> Left (T.unpack key <> " must be a string")

rejectUnknown :: [T.Text] -> Object -> Either String ()
rejectUnknown allowed object =
  case filter (`notElem` allowed) (map K.toText (KM.keys object)) of
    [] -> Right ()
    extras -> Left ("unknown fields: " <> T.unpack (T.intercalate ", " extras))

encodePutResult :: Task -> PutStatus -> BL.ByteString
encodePutResult task result = reply (taskId task) $ case result of
  PutInserted -> "inserted"
  PutExisting -> "existing"

encodeAckResult :: TaskId -> AckStatus -> BL.ByteString
encodeAckResult ident result = reply ident $ case result of
  Acked -> "acked"
  AlreadyDone -> "already_done"

encodeRenewResult :: TaskId -> BL.ByteString
encodeRenewResult ident = reply ident "renewed"

encodeFailResult :: TaskId -> Retry -> BL.ByteString
encodeFailResult ident retry = reply ident $ case retry of
  Retry -> "failed_retry"
  NoRetry -> "failed"

encodeReclaimResult :: TaskId -> BL.ByteString
encodeReclaimResult ident = reply ident "reclaimed"

-- | What a transition answers: the task, and what became of it.
reply :: TaskId -> T.Text -> BL.ByteString
reply ident status = canonical (A.object ["task_id" .= ident, "status" .= status])

-- | The canonical bytes of anything the protocol writes.
encode :: ToJSON a => a -> BL.ByteString
encode = canonical . toJSON

-- | One line, no spaces, and the keys of every object in order, so that
-- equal values are equal bytes.
canonical :: A.Value -> BL.ByteString
canonical value = case value of
  A.Null -> "null"
  A.Bool True -> "true"
  A.Bool False -> "false"
  A.Number number -> A.encode number
  A.String text -> A.encode text
  A.Array values -> "[" <> joinComma (map canonical (toList values)) <> "]"
  A.Object object -> "{" <> joinComma (map encodePair ordered) <> "}"
    where
      ordered = sortOn (K.toText . fst) (KM.toList object)
      encodePair (key, child) = A.encode (K.toText key) <> ":" <> canonical child

joinComma :: [BL.ByteString] -> BL.ByteString
joinComma [] = ""
joinComma (firstValue : rest) = firstValue <> foldMap ("," <>) rest

readInteger :: T.Text -> Maybe Integer
readInteger value = case reads (T.unpack value) of
  [(number, "")] -> Just number
  _ -> Nothing
