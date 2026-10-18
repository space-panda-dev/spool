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
  , parseLease
    -- * What a worker sends
  , LeaseRef (..)
  , Ack (..)
  , FailRequest (..)
  , FetchRequest (..)
  , SendRequest (..)
  , TakeRequest (..)
  , Answer (..)
  , parseAnswer
  , parseLeaseRef
  , parseAck
  , parseFail
  , parseFetchRequest
  , parseSendRequest
  , parseTakeRequest
  , parseCollectRequest
    -- * What the spool keeps
  , ResultRecord (..)
  , FailureRecord (..)
  , parseResultRecord
  , parseFailureRecord
    -- * What the spool answers
  , PutStatus (..)
  , AckStatus (..)
  , CollectStatus (..)
  , Counts (..)
  , encodePutResult
  , encodeAckResult
  , encodeRenewResult
  , encodeFailResult
  , encodeSendResult
  , encodeStaleResult
  , encodeReclaimResult
  , encodeCollectResult
  , encodeExpiredResult
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
import qualified Data.Aeson.Types as AT
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import qualified Spool.Attachments as SA
import Spool.Canonical (canonical, encode)
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
  , mkWorkerName
  , retryFlag
  , storedTimestamp
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

-- The requests are written as well as read: a worker on another machine
-- sends them to its spool.

instance ToJSON LeaseRef where
  toJSON reference = A.object (referenceFields reference)

referenceFields :: LeaseRef -> [AT.Pair]
referenceFields reference =
  ["task_id" .= refTask reference, "lease_id" .= refLease reference]

-- | An acknowledgement: the result, and the result attachments sent under
-- the lease that it files with the task (ADR 0020).
data Ack = Ack
  { ackRef :: LeaseRef
  , ackResult :: A.Value
  , ackAttachments :: [SA.Attachment]
  } deriving (Eq, Show)

instance ToJSON Ack where
  toJSON ack = A.object (referenceFields (ackRef ack) <> ["result" .= ackResult ack]
    <> attachmentsField (ackAttachments ack))

-- | Result attachments are written only when there are some, so that an
-- acknowledgement or a result without them is what 0.0.3 wrote, byte for
-- byte, and an older reader meets the field only where it matters.
attachmentsField :: [SA.Attachment] -> [AT.Pair]
attachmentsField [] = []
attachmentsField attachments = ["attachments" .= attachments]

data FailRequest = FailRequest
  { failRef :: LeaseRef
  , failReason :: T.Text
  } deriving (Eq, Show)

instance ToJSON FailRequest where
  toJSON request =
    A.object (referenceFields (failRef request) <> ["reason" .= failReason request])

data FetchRequest = FetchRequest
  { fetchRef :: LeaseRef
  , fetchDigest :: SA.Sha256
  } deriving (Eq, Show)

instance ToJSON FetchRequest where
  toJSON request =
    A.object (referenceFields (fetchRef request) <> ["sha256" .= fetchDigest request])

-- | One result attachment a worker sends under its lease: the bytes follow
-- this request on the same stream.
data SendRequest = SendRequest
  { sendRef :: LeaseRef
  , sendAttachment :: SA.Attachment
  } deriving (Eq, Show)

instance ToJSON SendRequest where
  toJSON request = A.object (referenceFields (sendRef request)
    <> [ "sha256" .= SA.attachmentSha256 (sendAttachment request)
       , "size" .= SA.attachmentSize (sendAttachment request) ])

-- | One result attachment of a done task, asked for by whoever reads its
-- result.
data TakeRequest = TakeRequest
  { takeTask :: TaskId
  , takeDigest :: SA.Sha256
  } deriving (Eq, Show)

instance ToJSON TakeRequest where
  toJSON request =
    A.object ["task_id" .= takeTask request, "sha256" .= takeDigest request]

-- | The record of an acknowledged task, kept until whoever put the task
-- reads it.
data ResultRecord = ResultRecord
  { resultTask :: TaskId
  , resultLease :: LeaseId
  , resultCapability :: Capability
  , resultWorker :: WorkerName
  , resultFinishedAt :: Timestamp
  , resultValue :: A.Value
  , resultAttachments :: [SA.Attachment]
  } deriving (Eq, Show)

instance ToJSON ResultRecord where
  toJSON record = A.object $
    [ "task_id" .= resultTask record
    , "lease_id" .= resultLease record
    , "capability" .= resultCapability record
    , "worker" .= resultWorker record
    , "finished_at" .= resultFinishedAt record
    , "result" .= resultValue record
    ] <> attachmentsField (resultAttachments record)

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

-- | What @collect@ found under a task's identifier (ADR 0018).
data CollectStatus
  = Collected    -- ^ it was finished, and is gone with its records
  | NotFinished  -- ^ it is pending or leased, and nothing was deleted
  | Unknown      -- ^ the spool holds nothing under it
  deriving (Bounded, Enum, Eq, Show)

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

-- | The lease envelope, as a worker reads it back from a spool.
parseLease :: BL.ByteString -> Either String Lease
parseLease = strictObject "lease"
  [ "task_id", "capability", "lease_id", "worker", "leased_at", "payload"
  , "attachments" ] $ \object -> do
    ident <- mkTaskId =<< requiredText "task_id" object
    capability <- mkCapability =<< requiredText "capability" object
    leaseIdent <- mkLeaseId =<< requiredText "lease_id" object
    worker <- mkWorkerName =<< requiredText "worker" object
    leasedAt <- requiredText "leased_at" object
    payload <- required "lease is missing payload" "payload" object
    attachments <- case KM.lookup "attachments" object of
      Nothing -> Left "missing attachments"
      Just value -> case A.fromJSON value of
        A.Error message -> Left message
        A.Success declarations -> SA.validateAttachments declarations
    pure (Lease (Task ident capability payload attachments) leaseIdent worker
      (storedTimestamp leasedAt))

-- | What a transition on a lease answered, as a worker reads it back.
data Answer = Answer
  { answerRef :: LeaseRef
  , answerStatus :: T.Text
  } deriving (Eq, Show)

parseAnswer :: BL.ByteString -> Either String Answer
parseAnswer = strictObject "answer" ["task_id", "lease_id", "status"] $ \object -> do
  identText <- requiredText "task_id" object
  leaseText <- requiredText "lease_id" object
  status <- requiredText "status" object
  reference <- leaseRef identText leaseText
  pure (Answer reference status)

parseLeaseRef :: BL.ByteString -> Either String LeaseRef
parseLeaseRef = strictObject "lease reference" ["task_id", "lease_id"] $ \object -> do
  identText <- requiredText "task_id" object
  leaseText <- requiredText "lease_id" object
  leaseRef identText leaseText

parseAck :: BL.ByteString -> Either String Ack
parseAck = strictObject "ack" ["task_id", "lease_id", "result", "attachments"] $
  \object -> do
    identText <- requiredText "task_id" object
    leaseText <- requiredText "lease_id" object
    result <- required "ack is missing result" "result" object
    attachments <- optionalAttachments object
    reference <- leaseRef identText leaseText
    pure (Ack reference result attachments)

-- | An attachments field that may be left out, and is then empty.
optionalAttachments :: Object -> Either String [SA.Attachment]
optionalAttachments object = case KM.lookup "attachments" object of
  Nothing -> Right []
  Just value -> case A.fromJSON value of
    A.Error message -> Left message
    A.Success declarations -> SA.validateAttachments declarations

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

parseSendRequest :: BL.ByteString -> Either String SendRequest
parseSendRequest = strictObject "send request"
  ["task_id", "lease_id", "sha256", "size"] $ \object -> do
    identText <- requiredText "task_id" object
    leaseText <- requiredText "lease_id" object
    digestText <- requiredText "sha256" object
    size <- case KM.lookup "size" object of
      Nothing -> Left "missing size"
      Just value -> case A.fromJSON value of
        A.Error message -> Left message
        A.Success declared -> Right declared
    reference <- leaseRef identText leaseText
    digest <- SA.mkSha256 digestText
    attachment <- case SA.validateAttachments [SA.Attachment digest size] of
      Right [declared] -> Right declared
      Right _ -> Left "send request must declare one attachment"
      Left message -> Left message
    pure (SendRequest reference attachment)

parseTakeRequest :: BL.ByteString -> Either String TakeRequest
parseTakeRequest = strictObject "take request" ["task_id", "sha256"] $ \object -> do
  identText <- requiredText "task_id" object
  digestText <- requiredText "sha256" object
  ident <- mkTaskId identText
  digest <- SA.mkSha256 digestText
  pure (TakeRequest ident digest)

-- | A task a caller has read what came of, and is done with.
parseCollectRequest :: BL.ByteString -> Either String TaskId
parseCollectRequest = strictObject "collect request" ["task_id"] $ \object ->
  mkTaskId =<< requiredText "task_id" object

-- | The two identifiers of a request, checked only once every field of the
-- request is known to be there, so that a missing field is what is reported
-- when a field is missing.
leaseRef :: T.Text -> T.Text -> Either String LeaseRef
leaseRef identText leaseText = LeaseRef <$> mkTaskId identText <*> mkLeaseId leaseText

parseResultRecord :: BL.ByteString -> Either String ResultRecord
parseResultRecord = strictObject "result record"
  [ "task_id", "lease_id", "capability", "worker", "finished_at", "result"
  , "attachments" ] $
  \object -> do
    (ident, lease, capability, worker) <- recordIdentity object
    finishedAt <- requiredText "finished_at" object
    result <- required "missing result" "result" object
    attachments <- optionalAttachments object
    pure ResultRecord
      { resultTask = ident
      , resultLease = lease
      , resultCapability = capability
      , resultWorker = worker
      , resultFinishedAt = storedTimestamp finishedAt
      , resultValue = result
      , resultAttachments = attachments
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
  workerText <- requiredText "worker" object
  ident <- mkTaskId identText
  lease <- mkLeaseId leaseText
  capability <- mkCapability capabilityText
  worker <- mkWorkerName workerText
  pure (ident, lease, capability, worker)

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

encodeAckResult :: LeaseRef -> AckStatus -> BL.ByteString
encodeAckResult reference result = answer reference $ case result of
  Acked -> "acked"
  AlreadyDone -> "already_done"

encodeRenewResult :: LeaseRef -> BL.ByteString
encodeRenewResult reference = answer reference "renewed"

encodeFailResult :: LeaseRef -> Retry -> BL.ByteString
encodeFailResult reference retry = answer reference $ case retry of
  Retry -> "failed_retry"
  NoRetry -> "failed"

-- | A result attachment is staged under its lease, for its ack to file.
encodeSendResult :: LeaseRef -> BL.ByteString
encodeSendResult reference = answer reference "staged"

-- | The answer to a line whose lease is stale, unknown, another task's, or
-- another worker's.  It does not say which.
encodeStaleResult :: LeaseRef -> BL.ByteString
encodeStaleResult reference = answer reference "stale"

-- | What reclaim did with a task: returned it to pending, or, when the task
-- had used its retries, left it failed.
encodeReclaimResult :: TaskId -> Retry -> BL.ByteString
encodeReclaimResult ident retry = reply ident $ case retry of
  Retry -> "reclaimed"
  NoRetry -> "failed"

encodeCollectResult :: TaskId -> CollectStatus -> BL.ByteString
encodeCollectResult ident status = reply ident $ case status of
  Collected -> "collected"
  NotFinished -> "not_finished"
  Unknown -> "unknown"

encodeExpiredResult :: TaskId -> BL.ByteString
encodeExpiredResult ident = reply ident "expired"

-- | What a transition on a lease answers: the lease, and what became of it.
answer :: LeaseRef -> T.Text -> BL.ByteString
answer (LeaseRef ident leaseIdent) status = canonical (A.object
  ["task_id" .= ident, "lease_id" .= leaseIdent, "status" .= status])

-- | What a transition on a task answers: the task, and what became of it.
reply :: TaskId -> T.Text -> BL.ByteString
reply ident status = canonical (A.object ["task_id" .= ident, "status" .= status])

readInteger :: T.Text -> Maybe Integer
readInteger value = case reads (T.unpack value) of
  [(number, "")] -> Just number
  _ -> Nothing
