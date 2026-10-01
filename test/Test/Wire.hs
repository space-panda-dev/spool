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
  , Task (..)
  , canonical
  , encode
  , encodeFailResult
  , parseAck
  , parseFail
  , parseFailureRecord
  , parseFetchRequest
  , parseLeaseRef
  , parseResultRecord
  , parseTask
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
        @?= Right (Task (made mkTaskId "task-one") (made mkCapability "classify@1")
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
      "{\"task_id\":\"t\",\"capability\":\"c@1\",\"payload\":1,\"priority\":9}"
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

requestTests :: [TestTree]
requestTests =
  [ testCase "ack carries its result whatever it is" $
      parseAck "{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\",\"result\":null}"
        @?= Right (Ack reference A.Null)
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
        @?= Right (FetchRequest reference (sha 'a'))
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
  , testCase "fail answers with what became of the task" $ do
      encodeFailResult taskOne Retry @?= "{\"status\":\"failed_retry\",\"task_id\":\"t\"}"
      encodeFailResult taskOne NoRetry @?= "{\"status\":\"failed\",\"task_id\":\"t\"}"
  ]
  where
    digest = BL.pack (replicate 64 0x61)
    reference = LeaseRef taskOne leaseOne

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
