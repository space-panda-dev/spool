{-# LANGUAGE OverloadedStrings #-}

-- | The envelopes and the canonical encoding.
module Test.Wire (tests) where

import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.Either (isLeft)
import Data.List (nub)
import qualified Data.Text as T
import Spool.Attachments (Attachment (..), Sha256, mkSha256)
import Spool.Types
  ( Capability
  , LeaseId
  , Retry (..)
  , TaskId
  , mkCapability
  , mkLeaseId
  , mkTaskId
  , mkWorkerName
  , storedTimestamp
  )
import Spool.Wire
  ( Ack (..)
  , Counts (..)
  , FailRequest (..)
  , FailureRecord (..)
  , FetchRequest (..)
  , Lease (..)
  , LeaseRef (..)
  , ResultRecord (..)
  , SendRequest (..)
  , TakeRequest (..)
  , Task (..)
  , TaskLine (..)
  , WithdrawalRecord (..)
  , canonical
  , encode
  , encodeCollectResult
  , encodeExpiredResult
  , encodeFailResult
  , encodeSendResult
  , encodeStaleResult
  , encodeWithdrawResult
  , encodeWithdrawnResult
  , newTask
  , parseAck
  , parseCollectRequest
  , parseFail
  , parseFailureRecord
  , parseFetchRequest
  , parseLeaseRef
  , parseResultRecord
  , parseSendRequest
  , parseTakeRequest
  , parseStoredTask
  , parseTask
  , parseWithdrawalRecord
  , sameTask
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))
import Test.Tasty.QuickCheck
  ( Gen
  , arbitrary
  , elements
  , forAll
  , listOf
  , listOf1
  , oneof
  , sized
  , resize
  , suchThat
  , testProperty
  , (===)
  , (==>)
  )

tests :: TestTree
tests = testGroup "wire"
  [ testGroup "task" taskTests
  , testGroup "requests" requestTests
  , testGroup "records" recordTests
  , testGroup "canonical encoding" canonicalTests
  ]

-- | JSON values built here rather than taken from a library instance, so the
-- suite does not depend on which versions provide one.
value :: Gen A.Value
value = sized go
  where
    go size
      | size <= 1 = leaf
      | otherwise = oneof
          [ leaf
          , A.toJSON <$> resize 4 (listOf (go (size `div` 4)))
          , A.Object . KM.fromList <$> resize 4 (listOf (pair (size `div` 4)))
          ]
    pair size = (,) <$> (K.fromText <$> text) <*> go size
    leaf = oneof
      [ pure A.Null
      , A.Bool <$> arbitrary
      , A.toJSON <$> (arbitrary :: Gen Integer)
      , A.toJSON <$> (arbitrary :: Gen Double)
      , A.String <$> text
      ]
    text = T.pack <$> listOf (elements ("ab\"\\/ \n\233\321\128512" :: String))

-- | A non-empty word of the alphabet, no longer than a name may be.
token :: String -> Gen T.Text
token alphabet = T.take 60 . T.pack <$> listOf1 (elements alphabet)

-- | Made through the checking functions, as every identifier is.  A text
-- the grammar refuses would stop the suite here, not pass for an identifier.
made :: (T.Text -> Either String a) -> T.Text -> a
made make = either error id . make

taskIdentifier :: Gen TaskId
taskIdentifier = made mkTaskId <$>
  token (['a' .. 'z'] <> ['A' .. 'Z'] <> ['0' .. '9'] <> "._-")
    `suchThat` (not . T.isInfixOf "--")

capability :: Gen Capability
capability = do
  name <- token (['a' .. 'z'] <> ['0' .. '9'] <> "._-")
  version <- token (['0' .. '9'] <> ".")
  pure (made mkCapability (name <> "@" <> version))

sha :: Char -> Sha256
sha = made mkSha256 . T.replicate 64 . T.singleton

task :: Gen Task
task = Task <$> taskIdentifier <*> capability <*> value <*> attachments
  <*> elements [0, 7, -3, minBound, maxBound] <*> pure Nothing
  where
    attachments = elements
      [ []
      , [Attachment (sha 'a') 0]
      , [Attachment (sha 'a') 12, Attachment (sha 'b') 9223372036854775807]
      ]

taskOne :: TaskId
taskOne = made mkTaskId "t"

leaseOne :: LeaseId
leaseOne = made mkLeaseId "lease_1_1_t"

taskTests :: [TestTree]
taskTests =
  [ testCase "the protocol's example is a task" $
      parseTask "{\"task_id\":\"task-one\",\"capability\":\"classify@1\",\"payload\":{\"anything\":\"opaque\"},\"attachments\":[]}"
        @?= Right (newTask (made mkTaskId "task-one") (made mkCapability "classify@1")
              (A.object ["anything" A..= ("opaque" :: T.Text)]) [])
  , testCase "a task written before attachments existed still reads" $
      fmap taskAttachments
        (parseTask "{\"task_id\":\"t\",\"capability\":\"c@1\",\"payload\":null}")
        @?= Right []
  , testCase "a null payload is a payload" $
      fmap taskPayload
        (parseTask "{\"task_id\":\"t\",\"capability\":\"c@1\",\"payload\":null}")
        @?= Right A.Null
  , refused "a missing payload" "{\"task_id\":\"t\",\"capability\":\"c@1\"}"
  , refused "a missing capability" "{\"task_id\":\"t\",\"payload\":1}"
  , refused "an unknown field"
      "{\"task_id\":\"t\",\"capability\":\"c@1\",\"payload\":1,\"rank\":9}"
  , testCase "a task may give a priority (ADR 0024)" $
      fmap taskPriority
        (parseTask "{\"task_id\":\"t\",\"capability\":\"c@1\",\"payload\":1,\"priority\":-9}")
        @?= Right (-9)
  , testCase "a task that gives none has priority 0" $
      fmap taskPriority (parseTask "{\"task_id\":\"t\",\"capability\":\"c@1\",\"payload\":1}")
        @?= Right 0
  , refused "a fractional priority"
      "{\"task_id\":\"t\",\"capability\":\"c@1\",\"payload\":1,\"priority\":1.5}"
  , refused "a priority past the largest"
      "{\"task_id\":\"t\",\"capability\":\"c@1\",\"payload\":1,\"priority\":9223372036854775808}"
  , refused "a priority given as a string"
      "{\"task_id\":\"t\",\"capability\":\"c@1\",\"payload\":1,\"priority\":\"high\"}"
  , refused "a place in the queue, which is the spool's to give,"
      "{\"task_id\":\"t\",\"capability\":\"c@1\",\"payload\":1,\"put_serial\":1}"
  , testCase "a stored task keeps its place in the queue" $
      fmap taskPutSerial
        (parseStoredTask "{\"task_id\":\"t\",\"capability\":\"c@1\",\"payload\":1,\"put_serial\":42}")
        @?= Right (Just 42)
  , testCase "a task stored before 0.0.5 has no place in the queue" $
      fmap taskPutSerial
        (parseStoredTask "{\"task_id\":\"t\",\"capability\":\"c@1\",\"payload\":1,\"attachments\":[]}")
        @?= Right Nothing
  , testCase "a negative place is corrupt" $
      assertBool "refused" (isLeft (parseStoredTask
        "{\"task_id\":\"t\",\"capability\":\"c@1\",\"payload\":1,\"put_serial\":-1}"))
  , testProperty "a stored task reads back as the task it was written from" $
      forAll task $ \original -> forAll (elements [Nothing, Just 0, Just 12345678901234567890]) $
        \serial -> let stored = original { taskPutSerial = serial }
                   in parseStoredTask (encode stored) === Right stored
  , testCase "a task with neither a priority nor a place is written as 0.0.4 wrote it" $
      encode (newTask (made mkTaskId "t") (made mkCapability "c@1") A.Null [])
        @?= "{\"attachments\":[],\"capability\":\"c@1\",\"payload\":null,\"task_id\":\"t\"}"
  , testProperty "neither priority nor place makes a task another task" $
      forAll task $ \original ->
        sameTask original original { taskPriority = taskPriority original + 1, taskPutSerial = Just 3 }
          === True
  , testProperty "a lease carries neither a priority nor a place, so a 0.0.4 worker reads it" $
      forAll task $ \original ->
        let lease = Lease original { taskPutSerial = Just 9 } leaseOne
              (made mkWorkerName "worker-one") (storedTimestamp "2026-09-29T12:00:00Z")
        in fmap KM.keys (A.decode (encode lease) >>= asObject)
             === Just (map K.fromText
               ["attachments", "capability", "lease_id", "leased_at", "payload", "task_id", "worker"])
  , refused "an empty task_id" "{\"task_id\":\"\",\"capability\":\"c@1\",\"payload\":1}"
  , refused "a numeric task_id" "{\"task_id\":7,\"capability\":\"c@1\",\"payload\":1}"
  , refused "an array" "[]"
  , refused "bytes that are not JSON" "{not-json}"
  , refused "attachments out of order"
      ( "{\"task_id\":\"t\",\"capability\":\"c@1\",\"payload\":1,\"attachments\":["
          <> "{\"sha256\":\"" <> hex 'b' <> "\",\"size\":1},"
          <> "{\"sha256\":\"" <> hex 'a' <> "\",\"size\":1}]}" )
  , refused "an attachment with a filename"
      ( "{\"task_id\":\"t\",\"capability\":\"c@1\",\"payload\":1,\"attachments\":["
          <> "{\"sha256\":\"" <> hex 'a' <> "\",\"size\":1,\"name\":\"x\"}]}" )
  , testProperty "a written task reads back as the task it was written from" $
      forAll task $ \original -> parseTask (encode original) === Right original
  , testProperty "a lease carries its task's fields unchanged" $
      forAll task $ \original ->
        let lease = Lease original leaseOne (made mkWorkerName "worker-one")
              (storedTimestamp "2026-09-29T12:00:00Z")
            carried = do
              A.Object object <- A.decode (encode lease)
              pure ( KM.lookup "task_id" object, KM.lookup "capability" object
                   , KM.lookup "payload" object, KM.lookup "attachments" object )
        in carried === Just
             ( Just (A.toJSON (taskId original))
             , Just (A.toJSON (taskCapability original))
             , Just (taskPayload original)
             , Just (A.toJSON (taskAttachments original)) )
  ]
  where
    refused label bytes = testCase (label <> " is refused") $
      assertBool "refused" (isLeft (parseTask bytes))
    hex = BLC.pack . replicate 64
    asObject (A.Object object) = Just object
    asObject _ = Nothing

requestTests :: [TestTree]
requestTests =
  [ testCase "ack carries its result whatever it is" $
      parseAck "{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\",\"result\":null}"
        @?= Right (Ack reference A.Null [])
  , testCase "ack carries the result attachments it names" $
      parseAck ("{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\",\"result\":1,\"attachments\":["
        <> declared 'a' 3 <> "," <> declared 'b' 0 <> "]}")
        @?= Right (Ack reference (A.toJSON (1 :: Int)) [Attachment (sha 'a') 3, Attachment (sha 'b') 0])
  , testCase "ack with no result attachments is written as 0.0.3 wrote it" $
      encode (Ack reference A.Null [])
        @?= "{\"lease_id\":\"lease_1_1_t\",\"result\":null,\"task_id\":\"t\"}"
  , testCase "ack with an empty list of result attachments has none" $
      parseAck "{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\",\"result\":null,\"attachments\":[]}"
        @?= Right (Ack reference A.Null [])
  , testCase "ack with result attachments reads back as written" $ do
      let ack = Ack reference A.Null [Attachment (sha 'a') 3, Attachment (sha 'c') 7]
      parseAck (encode ack) @?= Right ack
  , testGroup "ack result attachments are refused when they"
      [ testCase label (assertBool "refused" (isLeft (parseAck
          ("{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\",\"result\":1,\"attachments\":"
            <> list <> "}"))))
      | (label, list) <-
          [ ("are out of order", "[" <> declared 'b' 1 <> "," <> declared 'a' 1 <> "]")
          , ("repeat a digest", "[" <> declared 'a' 1 <> "," <> declared 'a' 2 <> "]")
          , ("have a negative size", "[" <> declared 'a' (-1) <> "]")
          , ("name a path", "[{\"sha256\":\"../x\",\"size\":1}]")
          , ("carry a name", "[{\"sha256\":\"" <> digest <> "\",\"size\":1,\"name\":\"x\"}]")
          , ("are not a list", declared 'a' 1)
          ]
      ]
  , testCase "a send request names one digest and its size" $
      parseSendRequest
        ("{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\",\"sha256\":\"" <> digest <> "\",\"size\":5}")
        @?= Right (SendRequest reference (Attachment (sha 'a') 5))
  , testCase "a send request reads back as written" $ do
      let request = SendRequest reference (Attachment (sha 'a') 9223372036854775807)
      parseSendRequest (encode request) @?= Right request
  , testGroup "a send request is refused when it"
      [ testCase label (assertBool "refused" (isLeft (parseSendRequest bytes)))
      | (label, bytes) <-
          [ ("has no size", "{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\",\"sha256\":\"" <> digest <> "\"}")
          , ("has a negative size", sendWith "-1")
          , ("has a fractional size", sendWith "1.5")
          , ("has a size past 64 bits", sendWith "9223372036854775808")
          , ("has a size as a string", sendWith "\"1\"")
          , ("names a path", "{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\",\"sha256\":\"../x\",\"size\":1}")
          , ("names a file", "{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\",\"sha256\":\"" <> digest <> "\",\"size\":1,\"name\":\"x\"}")
          ]
      ]
  , testCase "a take request names a task and a digest" $
      parseTakeRequest ("{\"task_id\":\"t\",\"sha256\":\"" <> digest <> "\"}")
        @?= Right (TakeRequest taskOne (sha 'a'))
  , testGroup "a take request is refused when it"
      [ testCase label (assertBool "refused" (isLeft (parseTakeRequest bytes)))
      | (label, bytes) <-
          [ ("has no digest", "{\"task_id\":\"t\"}")
          , ("names a lease", "{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\",\"sha256\":\"" <> digest <> "\"}")
          , ("names a path", "{\"task_id\":\"t\",\"sha256\":\"../x\"}")
          , ("names a task outside the grammar", "{\"task_id\":\"../t\",\"sha256\":\"" <> digest <> "\"}")
          ]
      ]
  , testCase "a send is answered staged" $
      encodeSendResult reference
        @?= "{\"lease_id\":\"lease_1_1_t\",\"status\":\"staged\",\"task_id\":\"t\"}"
  , testCase "ack without a result is refused" $
      assertBool "refused" $ isLeft $
        parseAck "{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\"}"
  , testCase "fail carries its reason" $
      parseFail "{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\",\"reason\":\"exit 3\"}"
        @?= Right (FailRequest reference "exit 3")
  , testCase "fail with an empty reason is refused" $
      assertBool "refused" $ isLeft $
        parseFail "{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\",\"reason\":\"\"}"
  , testCase "a lease reference is a task and a lease" $
      parseLeaseRef "{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\"}"
        @?= Right reference
  , testCase "a lease reference with a result is refused" $
      assertBool "refused" $ isLeft $
        parseLeaseRef "{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\",\"result\":1}"
  , testCase "a fetch request names one digest" $
      parseFetchRequest
        ("{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\",\"sha256\":\"" <> digest <> "\"}")
        @?= Right (FetchRequest reference (sha 'a') 0)
  , testCase "a fetch request may ask from an offset (ADR 0026)" $
      parseFetchRequest
        ("{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\",\"sha256\":\"" <> digest <> "\",\"offset\":5}")
        @?= Right (FetchRequest reference (sha 'a') 5)
  , testCase "a fetch request with a negative offset is refused" $
      assertBool "refused" $ isLeft $ parseFetchRequest
        ("{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\",\"sha256\":\"" <> digest <> "\",\"offset\":-1}")
  , testCase "a fetch from the start is written as 0.0.4 wrote it" $
      encode (FetchRequest reference (sha 'a') 0)
        @?= "{\"lease_id\":\"lease_1_1_t\",\"sha256\":\"" <> digest <> "\",\"task_id\":\"t\"}"
  , testCase "a fetch from an offset says where" $
      parseFetchRequest (encode (FetchRequest reference (sha 'a') 7))
        @?= Right (FetchRequest reference (sha 'a') 7)
  , testCase "withdraw answers name the task (ADR 0022)" $
      map (encodeWithdrawResult taskOne) [minBound .. maxBound]
        @?= [ "{\"status\":\"withdrawn\",\"task_id\":\"t\"}"
            , "{\"status\":\"finished\",\"task_id\":\"t\"}"
            , "{\"status\":\"unknown\",\"task_id\":\"t\"}" ]
  , testCase "a lease whose task was withdrawn is answered so" $
      encodeWithdrawnResult reference
        @?= "{\"lease_id\":\"lease_1_1_t\",\"status\":\"withdrawn\",\"task_id\":\"t\"}"
  , testCase "a pending task is listed with its priority (ADR 0023)" $
      encode (PendingLine taskOne 3)
        @?= "{\"priority\":3,\"state\":\"pending\",\"task_id\":\"t\"}"
  , testCase "a leased task is listed with its lease, worker, and times" $
      encode (LeasedLine taskOne 0 leaseOne (Just (made mkWorkerName "w"))
          (storedTimestamp "2026-10-21T00:00:00Z") (storedTimestamp "2026-10-21T00:01:00Z"))
        @?= "{\"lease_id\":\"lease_1_1_t\",\"leased_at\":\"2026-10-21T00:00:00Z\",\"priority\":0,\"renewed_at\":\"2026-10-21T00:01:00Z\",\"state\":\"leased\",\"task_id\":\"t\",\"worker\":\"w\"}"
  , testCase "a lease never handed to a worker is listed with none" $
      fmap (KM.lookup "worker") (A.decode (encode (LeasedLine taskOne 0 leaseOne Nothing
          (storedTimestamp "2026-10-21T00:00:00Z") (storedTimestamp "2026-10-21T00:00:00Z")))
        >>= \found -> case found of A.Object object -> Just object; _ -> Nothing)
        @?= Just (Just A.Null)
  , testCase "a withdrawal record reads back" $ do
      let record = WithdrawalRecord taskOne leaseOne (storedTimestamp "2026-10-21T00:00:00Z")
      parseWithdrawalRecord (encode record) @?= Right record
  , testCase "a withdrawal record with another field is corrupt" $
      assertBool "refused" $ isLeft $ parseWithdrawalRecord
        "{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\",\"withdrawn_at\":\"2026-10-21T00:00:00Z\",\"by\":\"x\"}"
  , testCase "a fetch request with a path for a digest is refused" $
      assertBool "refused" $ isLeft $ parseFetchRequest
        "{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\",\"sha256\":\"../../etc/passwd\"}"
  , testCase "a request whose lease is outside the grammar is refused" $
      assertBool "refused" $ isLeft $
        parseLeaseRef "{\"task_id\":\"t\",\"lease_id\":\"../x\"}"
  , testCase "a missing field is what is reported when a field is missing" $
      -- The task_id here is outside its grammar too; the absent lease_id is
      -- found first, because no identifier is checked until every field is
      -- known to be there.
      parseLeaseRef "{\"task_id\":\"a--b\"}" @?= Left "missing lease_id"
  , testCase "a collect request names one task" $
      parseCollectRequest "{\"task_id\":\"t\"}" @?= Right taskOne
  , testGroup "a collect request is refused when it"
      [ testCase label (assertBool "refused" (isLeft (parseCollectRequest bytes)))
      | (label, bytes) <-
          [ ("has no task", "{}")
          , ("names a lease too", "{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\"}")
          , ("names a task outside the grammar", "{\"task_id\":\"../t\"}")
          , ("is not an object", "[\"t\"]")
          ]
      ]
  , testCase "collect and gc answer the task and what became of it" $ do
      map (encodeCollectResult taskOne) [minBound .. maxBound]
        @?= [ "{\"status\":\"collected\",\"task_id\":\"t\"}"
            , "{\"status\":\"not_finished\",\"task_id\":\"t\"}"
            , "{\"status\":\"unknown\",\"task_id\":\"t\"}" ]
      encodeExpiredResult taskOne @?= "{\"status\":\"expired\",\"task_id\":\"t\"}"
  , testCase "an answer names the lease and what became of it" $ do
      encodeFailResult reference Retry
        @?= "{\"lease_id\":\"lease_1_1_t\",\"status\":\"failed_retry\",\"task_id\":\"t\"}"
      encodeFailResult reference NoRetry
        @?= "{\"lease_id\":\"lease_1_1_t\",\"status\":\"failed\",\"task_id\":\"t\"}"
      encodeStaleResult reference
        @?= "{\"lease_id\":\"lease_1_1_t\",\"status\":\"stale\",\"task_id\":\"t\"}"
  ]
  where
    digest = BL.pack (replicate 64 0x61)
    reference = LeaseRef taskOne leaseOne
    declared character size = "{\"sha256\":\"" <> BLC.pack (replicate 64 character)
      <> "\",\"size\":" <> BLC.pack (show (size :: Int)) <> "}"
    sendWith size = "{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\",\"sha256\":\""
      <> digest <> "\",\"size\":" <> size <> "}"

recordTests :: [TestTree]
recordTests =
  [ testCase "the protocol's result record reads as its fields" $
      parseResultRecord resultRecord @?= Right ResultRecord
        { resultTask = made mkTaskId "task-one"
        , resultLease = made mkLeaseId "lease_1_1_task-one"
        , resultCapability = made mkCapability "classify@1"
        , resultWorker = made mkWorkerName "worker-one"
        , resultFinishedAt = storedTimestamp "2026-09-29T12:00:00Z"
        , resultValue = A.object ["anything" A..= ("opaque" :: T.Text)]
        , resultAttachments = []
        }
  , testCase "the protocol's failure record reads as its fields" $
      parseFailureRecord failureRecord @?= Right FailureRecord
        { failureTask = made mkTaskId "task-one"
        , failureLease = made mkLeaseId "lease_1_1_task-one"
        , failureCapability = made mkCapability "classify@1"
        , failureWorker = made mkWorkerName "worker-one"
        , failureFailedAt = storedTimestamp "2026-09-29T12:00:00Z"
        , failureReason = "exit 3: failed"
        , failureRetried = Retry
        }
  , testCase "a result record is written back as the bytes it was read from" $
      fmap encode (parseResultRecord resultRecord) @?= Right (recanonical resultRecord)
  , testCase "a result record with attachments is written back as the bytes it was read from" $ do
      let withAttachments = replacing "attachments"
            (A.toJSON [Attachment (sha 'a') 3, Attachment (sha 'b') 4]) resultRecord
      fmap resultAttachments (parseResultRecord withAttachments)
        @?= Right [Attachment (sha 'a') 3, Attachment (sha 'b') 4]
      fmap encode (parseResultRecord withAttachments) @?= Right (recanonical withAttachments)
  , testCase "a result record with no attachments is written without the field" $
      fmap encode (parseResultRecord (replacing "attachments" (A.toJSON ([] :: [Attachment])) resultRecord))
        @?= Right (recanonical resultRecord)
  , testCase "a result record whose attachments are out of order is corrupt" $
      assertBool "refused" $ isLeft $ parseResultRecord
        (replacing "attachments" (A.toJSON [Attachment (sha 'b') 3, Attachment (sha 'a') 4]) resultRecord)
  , testCase "a failure record is written back as the bytes it was read from" $
      fmap encode (parseFailureRecord failureRecord) @?= Right (recanonical failureRecord)
  , testCase "a failure that was not retried reads as not retried" $
      fmap failureRetried
        (parseFailureRecord (replacing "retried" (A.Bool False) failureRecord))
        @?= Right NoRetry
  , testCase "the counters are written under their names" $
      encode (Counts 1 0 3 2) @?= "{\"done\":3,\"failed\":2,\"leased\":0,\"pending\":1}"
  , testCase "a result record without its worker is corrupt" $
      assertBool "refused" (isLeft (parseResultRecord (without "worker" resultRecord)))
  , testCase "a failure record without its reason is corrupt" $
      assertBool "refused" (isLeft (parseFailureRecord (without "reason" failureRecord)))
  , testCase "a record whose worker is outside the grammar is corrupt" $
      assertBool "refused" $ isLeft $ parseResultRecord
        (replacing "worker" (A.String "two words") resultRecord)
  , testCase "a failure record whose retried is not a boolean is corrupt" $
      assertBool "refused" $ isLeft $ parseFailureRecord
        (replacing "retried" (A.String "yes") failureRecord)
  , testCase "a record with a field it does not define is corrupt" $
      assertBool "refused" $ isLeft $ parseResultRecord
        (replacing "extra" (A.Bool True) resultRecord)
  ]
  where
    resultRecord =
      "{\"task_id\":\"task-one\",\"lease_id\":\"lease_1_1_task-one\",\"capability\":\"classify@1\",\"worker\":\"worker-one\",\"finished_at\":\"2026-09-29T12:00:00Z\",\"result\":{\"anything\":\"opaque\"}}"
    failureRecord =
      "{\"task_id\":\"task-one\",\"lease_id\":\"lease_1_1_task-one\",\"capability\":\"classify@1\",\"worker\":\"worker-one\",\"failed_at\":\"2026-09-29T12:00:00Z\",\"reason\":\"exit 3: failed\",\"retried\":true}"
    edit change bytes = case A.decode bytes of
      Just (A.Object object) -> A.encode (A.Object (change object))
      _ -> error "the fixture is not a JSON object"
    without key = edit (KM.delete key)
    replacing key new = edit (KM.insert key new)
    recanonical bytes = maybe (error "the fixture is not JSON") canonical (A.decode bytes)

canonicalTests :: [TestTree]
canonicalTests =
  [ testCase "keys are written in order, without spaces" $
      canonical (A.object ["b" A..= (1 :: Int), "a" A..= A.Null, "c" A..= [True, False]])
        @?= "{\"a\":null,\"b\":1,\"c\":[true,false]}"
  , testCase "nested objects are ordered too" $
      canonical (A.object ["z" A..= A.object ["y" A..= (1 :: Int), "x" A..= (2 :: Int)]])
        @?= "{\"z\":{\"x\":2,\"y\":1}}"
  , testProperty "what is written reads back as the same value" $
      forAll value $ \original -> A.decode (canonical original) === Just original
  , testProperty "the order keys were given in does not change the bytes" $
      forAll (listOf ((,) <$> (K.fromText <$> token "abcxyz") <*> value)) $ \pairs ->
        let keys = map fst pairs
        in keys == nub keys ==>
             canonical (A.Object (KM.fromList pairs))
               === canonical (A.Object (KM.fromList (reverse pairs)))
  , testProperty "the encoding is one line" $
      forAll value $ \original -> BL.notElem 0x0a (canonical original)
  ]
