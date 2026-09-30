{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The envelopes and records of the protocol: their shapes, their grammars,
-- and the one canonical encoding. Everything here is pure.
module Spool.Wire
  ( Object
  , Task (..)
  , Lease (..)
  , PutStatus (..)
  , AckStatus (..)
  , validateCapability
  , parseTask
  , parseAck
  , parseFail
  , parseFetchRequest
  , rejectUnknown
  , validateTaskId
  , validateLeaseId
  , encodeTask
  , encodePutResult
  , encodeLease
  , encodeAckResult
  , encodeRenewResult
  , encodeFailResult
  , encodeReclaimResult
  , encodeFailedRecord
  , encodeResultRecord
  , encodeStatus
  , canonical
  , parseLeaseRef
  , parseFailureRecord
  , parseResultRecord
  , extractTextField
  , leaseMicros
  , readInteger
  ) where

import Data.Aeson ((.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.List (sortOn)
import qualified Data.Text as T
import qualified Spool.Attachments as SA

type Object = KM.KeyMap A.Value

data Task = Task
  { taskId :: T.Text
  , taskCapability :: T.Text
  , taskPayload :: A.Value
  , taskAttachments :: [SA.Attachment]
  } deriving (Eq, Show)

data Lease = Lease
  { leaseTask :: Task
  , leaseId :: T.Text
  , leaseWorker :: T.Text
  , leaseTime :: T.Text
  } deriving (Eq, Show)

data PutStatus = PutInserted | PutExisting deriving (Eq, Show)

data AckStatus = Acked | AlreadyDone deriving (Eq, Show)

objectKeys :: Object -> [T.Text]
objectKeys = map K.toText . KM.keys

validateCapability :: T.Text -> Either String ()
validateCapability value = case T.breakOn "@" value of
  (name, rest)
    | T.null rest -> Left "capability must be of the form name@version"
    | T.null name -> Left "capability name must be non-empty"
    | T.null version -> Left "capability version must be non-empty"
    | not (T.all validNameChar name) ->
        Left "capability name must match [A-Za-z0-9._-]+"
    | not (T.all validVersionChar version) ->
        Left "capability version must match [A-Za-z0-9.]+"
    | otherwise -> Right ()
    where
      version = T.drop 1 rest
      validNameChar character = asciiAlphaNum character || character `elem` ("._-" :: String)
      validVersionChar character = asciiAlphaNum character || character == '.'

asciiAlphaNum :: Char -> Bool
asciiAlphaNum character =
  ('a' <= character && character <= 'z') ||
  ('A' <= character && character <= 'Z') ||
  ('0' <= character && character <= '9')

parseTask :: BL.ByteString -> Either String Task
parseTask bytes = do
  value <- A.eitherDecode bytes
  case value of
    A.Object object -> do
      rejectUnknown ["task_id", "capability", "payload", "attachments"] object
      ident <- requiredText "task_id" object
      validateTaskId ident
      capability <- requiredText "capability" object
      validateCapability capability
      payload <- case KM.lookup "payload" object of
        Nothing -> Left "task is missing payload"
        Just value' -> Right value'
      attachments <- case KM.lookup "attachments" object of
        Nothing -> Right []
        Just value' -> case A.fromJSON value' of
          A.Error message -> Left message
          A.Success declarations -> SA.validateAttachments declarations
      pure (Task ident capability payload attachments)
    _ -> Left "task must be a JSON object"

parseAck :: BL.ByteString -> Either String (T.Text, T.Text, A.Value)
parseAck bytes = do
  value <- A.eitherDecode bytes
  case value of
    A.Object object -> do
      rejectUnknown ["task_id", "lease_id", "result"] object
      ident <- requiredText "task_id" object
      lease <- requiredText "lease_id" object
      result <- case KM.lookup "result" object of
        Nothing -> Left "ack is missing result"
        Just value' -> Right value'
      validateTaskId ident
      validateLeaseId lease
      pure (ident, lease, result)
    _ -> Left "ack must be a JSON object"

parseFail :: BL.ByteString -> Either String (T.Text, T.Text, T.Text)
parseFail bytes = do
  value <- A.eitherDecode bytes
  case value of
    A.Object object -> do
      rejectUnknown ["task_id", "lease_id", "reason"] object
      ident <- requiredText "task_id" object
      lease <- requiredText "lease_id" object
      reason <- requiredText "reason" object
      validateTaskId ident
      validateLeaseId lease
      pure (ident, lease, reason)
    _ -> Left "fail must be a JSON object"

parseFetchRequest :: BL.ByteString -> Either String (T.Text, T.Text, T.Text)
parseFetchRequest bytes = do
  value <- A.eitherDecode bytes
  case value of
    A.Object object -> do
      rejectUnknown ["task_id", "lease_id", "sha256"] object
      ident <- requiredText "task_id" object
      lease <- requiredText "lease_id" object
      digest <- requiredText "sha256" object
      validateTaskId ident
      validateLeaseId lease
      _ <- SA.validateAttachments [SA.Attachment digest 0]
      pure (ident, lease, digest)
    _ -> Left "fetch request must be a JSON object"

requiredText :: T.Text -> Object -> Either String T.Text
requiredText key object = case KM.lookup (K.fromText key) object of
  Nothing -> Left ("missing " <> T.unpack key)
  Just (A.String value)
    | T.null value -> Left (T.unpack key <> " must be non-empty")
    | otherwise -> Right value
  Just _ -> Left (T.unpack key <> " must be a string")

rejectUnknown :: [T.Text] -> Object -> Either String ()
rejectUnknown allowed object =
  case filter (`notElem` allowed) (objectKeys object) of
    [] -> Right ()
    extras -> Left ("unknown fields: " <> T.unpack (T.intercalate ", " extras))

validateTaskId :: T.Text -> Either String ()
validateTaskId value
  | T.null value = Left "task_id must be non-empty"
  | T.isInfixOf "--" value = Left "task_id cannot contain --"
  | T.all valid value = Right ()
  | otherwise = Left "task_id must contain only ASCII letters, digits, '.', '_' or '-'"
  where
    valid character = asciiAlphaNum character || character `elem` ("._-" :: String)

validateLeaseId :: T.Text -> Either String ()
validateLeaseId value
  | T.null value = Left "lease_id must be non-empty"
  | T.isInfixOf "--" value = Left "lease_id cannot contain --"
  | T.isPrefixOf "lease_" value && T.all valid (T.drop 6 value) = Right ()
  | otherwise = Left "lease_id is invalid"
  where
    valid character = asciiAlphaNum character || character `elem` ("._-" :: String)

encodeTask :: Task -> BL.ByteString
encodeTask task = canonical (A.object
  [ "task_id" .= taskId task
  , "capability" .= taskCapability task
  , "payload" .= taskPayload task
  , "attachments" .= taskAttachments task
  ])

encodePutResult :: Task -> PutStatus -> BL.ByteString
encodePutResult task result = canonical (A.object
  [ "task_id" .= taskId task
  , "status" .= case result of
      PutInserted -> ("inserted" :: T.Text)
      PutExisting -> "existing"
  ])

encodeLease :: Lease -> BL.ByteString
encodeLease lease = canonical (A.object
  [ "task_id" .= taskId (leaseTask lease)
  , "capability" .= taskCapability (leaseTask lease)
  , "lease_id" .= leaseId lease
  , "worker" .= leaseWorker lease
  , "leased_at" .= leaseTime lease
  , "payload" .= taskPayload (leaseTask lease)
  , "attachments" .= taskAttachments (leaseTask lease)
  ])

encodeAckResult :: T.Text -> AckStatus -> BL.ByteString
encodeAckResult ident result = canonical (A.object
  [ "task_id" .= ident
  , "status" .= case result of
      Acked -> ("acked" :: T.Text)
      AlreadyDone -> "already_done"
  ])

encodeRenewResult :: T.Text -> BL.ByteString
encodeRenewResult ident = canonical (A.object
  [ "task_id" .= ident
  , "status" .= ("renewed" :: T.Text)
  ])

encodeFailResult :: T.Text -> Bool -> BL.ByteString
encodeFailResult ident retried = canonical (A.object
  [ "task_id" .= ident
  , "status" .= (if retried then "failed_retry" else "failed" :: T.Text)
  ])

encodeReclaimResult :: T.Text -> BL.ByteString
encodeReclaimResult ident = canonical (A.object
  [ "task_id" .= ident
  , "status" .= ("reclaimed" :: T.Text)
  ])

encodeFailedRecord :: Task -> T.Text -> T.Text -> T.Text -> T.Text -> Bool -> BL.ByteString
encodeFailedRecord task leaseIdent worker failedAt reason retried = canonical (A.object
  [ "task_id" .= taskId task
  , "lease_id" .= leaseIdent
  , "capability" .= taskCapability task
  , "worker" .= worker
  , "failed_at" .= failedAt
  , "reason" .= reason
  , "retried" .= retried
  ])

encodeResultRecord :: Task -> T.Text -> T.Text -> T.Text -> A.Value -> BL.ByteString
encodeResultRecord task leaseIdent worker finishedAt output = canonical (A.object
  [ "task_id" .= taskId task
  , "lease_id" .= leaseIdent
  , "capability" .= taskCapability task
  , "worker" .= worker
  , "finished_at" .= finishedAt
  , "result" .= output
  ])

encodeStatus :: Int -> Int -> Int -> Int -> BL.ByteString
encodeStatus pending leased done failed = canonical (A.object
  [ "pending" .= pending
  , "leased" .= leased
  , "done" .= done
  , "failed" .= failed
  ])

canonical :: A.Value -> BL.ByteString
canonical value = case value of
  A.Null -> "null"
  A.Bool True -> "true"
  A.Bool False -> "false"
  A.Number number -> A.encode number
  A.String text -> A.encode text
  A.Array values -> "[" <> joinComma (map canonical (foldr (:) [] values)) <> "]"
  A.Object object -> "{" <> joinComma (map encodePair ordered) <> "}"
    where
      ordered = sortOn (K.toText . fst) (KM.toList object)
      encodePair (key, child) = A.encode (K.toText key) <> ":" <> canonical child

joinComma :: [BL.ByteString] -> BL.ByteString
joinComma [] = ""
joinComma (firstValue : rest) = firstValue <> foldMap ("," <>) rest

parseLeaseRef :: BL.ByteString -> Either String (T.Text, T.Text)
parseLeaseRef bytes = do
  value <- A.eitherDecode bytes
  case value of
    A.Object object -> do
      rejectUnknown ["task_id", "lease_id"] object
      ident <- requiredText "task_id" object
      lease <- requiredText "lease_id" object
      validateTaskId ident
      validateLeaseId lease
      pure (ident, lease)
    _ -> Left "lease reference must be a JSON object"

parseFailureRecord :: BL.ByteString -> Either String A.Value
parseFailureRecord bytes = do
  value <- A.eitherDecode bytes
  case value of
    A.Object object -> do
      rejectUnknown
        [ "task_id", "lease_id", "capability", "worker", "failed_at"
        , "reason", "retried"
        ] object
      validateRecordIdentity object
      _ <- requiredText "failed_at" object
      _ <- requiredText "reason" object
      case KM.lookup "retried" object of
        Just (A.Bool _) -> Right value
        Just _ -> Left "retried must be a boolean"
        Nothing -> Left "missing retried"
    _ -> Left "failure record must be a JSON object"

parseResultRecord :: BL.ByteString -> Either String (A.Value, A.Value)
parseResultRecord bytes = do
  value <- A.eitherDecode bytes
  case value of
    A.Object object -> do
      rejectUnknown
        [ "task_id", "lease_id", "capability", "worker", "finished_at"
        , "result"
        ] object
      validateRecordIdentity object
      _ <- requiredText "finished_at" object
      result <- case KM.lookup "result" object of
        Just resultValue -> Right resultValue
        Nothing -> Left "missing result"
      pure (value, result)
    _ -> Left "result record must be a JSON object"

validateRecordIdentity :: Object -> Either String ()
validateRecordIdentity object = do
  ident <- requiredText "task_id" object
  lease <- requiredText "lease_id" object
  capability <- requiredText "capability" object
  _ <- requiredText "worker" object
  validateTaskId ident
  validateLeaseId lease
  validateCapability capability

extractTextField :: T.Text -> A.Value -> T.Text
extractTextField key (A.Object object) = case KM.lookup (K.fromText key) object of
  Just (A.String value) -> value
  _ -> ""
extractTextField _ _ = ""

leaseMicros :: T.Text -> Maybe Integer
leaseMicros value = case T.stripPrefix "lease_" value of
  Nothing -> Nothing
  Just rest -> readInteger (T.takeWhile isAsciiDigit rest)

isAsciiDigit :: Char -> Bool
isAsciiDigit character = '0' <= character && character <= '9'

readInteger :: T.Text -> Maybe Integer
readInteger value = case reads (T.unpack value) of
  [(number, "")] -> Just number
  _ -> Nothing
