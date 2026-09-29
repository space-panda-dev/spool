{-# LANGUAGE OverloadedStrings #-}

-- | The envelopes and the canonical encoding.
module Test.Wire (tests) where

import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.Either (isLeft, isRight)
import Data.List (nub)
import qualified Data.Text as T
import Spool.Attachments (Attachment (..))
import Spool.Wire
  ( Lease (..)
  , Task (..)
  , canonical
  , encodeLease
  , encodeTask
  , leaseMicros
  , parseAck
  , parseFail
  , parseFailureRecord
  , parseFetchRequest
  , parseLeaseRef
  , parseResultRecord
  , parseTask
  , validateCapability
  , validateLeaseId
  , validateTaskId
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
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
  , testProperty
  , (===)
  , (==>)
  )

tests :: TestTree
tests = testGroup "wire"
  [ testGroup "task" taskTests
  , testGroup "identifiers" identifierTests
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

token :: String -> Gen T.Text
token alphabet = T.pack <$> listOf1 (elements alphabet)

taskIdentifier :: Gen T.Text
taskIdentifier = token (['a' .. 'z'] <> ['A' .. 'Z'] <> ['0' .. '9'] <> "._")

capability :: Gen T.Text
capability = do
  name <- token (['a' .. 'z'] <> ['0' .. '9'] <> "._-")
  version <- token (['0' .. '9'] <> ".")
  pure (name <> "@" <> version)

task :: Gen Task
task = Task <$> taskIdentifier <*> capability <*> value <*> attachments
  where
    attachments = elements
      [ []
      , [Attachment (T.replicate 64 "a") 0]
      , [Attachment (T.replicate 64 "a") 12, Attachment (T.replicate 64 "b") 9223372036854775807]
      ]

taskTests :: [TestTree]
taskTests =
  [ testCase "the protocol's example is a task" $
      parseTask "{\"task_id\":\"task-one\",\"capability\":\"classify@1\",\"payload\":{\"anything\":\"opaque\"},\"attachments\":[]}"
        @?= Right (Task "task-one" "classify@1"
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
      forAll task $ \original -> parseTask (encodeTask original) === Right original
  , testProperty "a lease carries its task's fields unchanged" $
      forAll task $ \original ->
        let lease = Lease original "lease_1_1_t" "worker-one" "2026-09-29T12:00:00Z"
            carried = do
              A.Object object <- A.decode (encodeLease lease)
              pure ( KM.lookup "task_id" object, KM.lookup "capability" object
                   , KM.lookup "payload" object, KM.lookup "attachments" object )
        in carried === Just
             ( Just (A.String (taskId original))
             , Just (A.String (taskCapability original))
             , Just (taskPayload original)
             , Just (A.toJSON (taskAttachments original)) )
  ]
  where
    refused label bytes = testCase (label <> " is refused") $
      assertBool "refused" (isLeft (parseTask bytes))
    hex = BLC.pack . replicate 64

identifierTests :: [TestTree]
identifierTests =
  [ testGroup "task_id accepts" (map (good validateTaskId) ["a", "task-one", "A.b_c-9"])
  , testGroup "task_id rejects"
      (map (bad validateTaskId) ["", "a--b", "a/b", "../escape", "a b", "caf\233", "a\nb"])
  , testGroup "capability accepts"
      (map (good validateCapability) ["classify@1", "opaque.name@1.2", "a-b_c@0"])
  , testGroup "capability rejects"
      (map (bad validateCapability)
        ["", "onlyname", "@1", "classify@", "bad name@1", "bad/name@1", "name@1-2", "a@b@c"])
  , testGroup "lease_id accepts"
      (map (good validateLeaseId) ["lease_1790717360482536_1_task-one"])
  , testGroup "lease_id rejects"
      (map (bad validateLeaseId) ["", "lease", "task_1_1_t", "lease_1--2", "lease_../x", "lease_a b"])
  , testCase "a lease's time is read from its identifier" $
      leaseMicros "lease_1790717360482536_1_task-one" @?= Just 1790717360482536
  , testCase "a name that is not a lease has no time" $
      leaseMicros "task-one" @?= Nothing
  , testCase "a lease identifier without digits has no time" $
      leaseMicros "lease_x" @?= Nothing
  , testProperty "every generated task_id is one the grammar accepts" $
      forAll taskIdentifier $ \ident ->
        not ("--" `T.isInfixOf` ident) ==> isRight (validateTaskId ident)
  ]
  where
    good check input = testCase (show input) $
      assertBool "accepted" (isRight (check input))
    bad check input = testCase (show input) $
      assertBool "refused" (isLeft (check input))

requestTests :: [TestTree]
requestTests =
  [ testCase "ack carries its result whatever it is" $
      parseAck "{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\",\"result\":null}"
        @?= Right ("t", "lease_1_1_t", A.Null)
  , testCase "ack without a result is refused" $
      assertBool "refused" $ isLeft $
        parseAck "{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\"}"
  , testCase "fail carries its reason" $
      parseFail "{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\",\"reason\":\"exit 3\"}"
        @?= Right ("t", "lease_1_1_t", "exit 3")
  , testCase "fail with an empty reason is refused" $
      assertBool "refused" $ isLeft $
        parseFail "{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\",\"reason\":\"\"}"
  , testCase "a lease reference is a task and a lease" $
      parseLeaseRef "{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\"}"
        @?= Right ("t", "lease_1_1_t")
  , testCase "a lease reference with a result is refused" $
      assertBool "refused" $ isLeft $
        parseLeaseRef "{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\",\"result\":1}"
  , testCase "a fetch request names one digest" $
      parseFetchRequest
        ("{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\",\"sha256\":\"" <> digest <> "\"}")
        @?= Right ("t", "lease_1_1_t", T.replicate 64 "a")
  , testCase "a fetch request with a path for a digest is refused" $
      assertBool "refused" $ isLeft $ parseFetchRequest
        "{\"task_id\":\"t\",\"lease_id\":\"lease_1_1_t\",\"sha256\":\"../../etc/passwd\"}"
  ]
  where
    digest = BL.pack (replicate 64 0x61)

recordTests :: [TestTree]
recordTests =
  [ testCase "the protocol's result record reads, and yields its result" $
      case parseResultRecord resultRecord of
        Right (_, result) -> result @?= A.object ["anything" A..= ("opaque" :: T.Text)]
        Left message -> assertFailure message
  , testCase "the protocol's failure record reads" $
      assertBool "accepted" (isRight (parseFailureRecord failureRecord))
  , testCase "a result record without its worker is corrupt" $
      assertBool "refused" (isLeft (parseResultRecord (without "worker" resultRecord)))
  , testCase "a failure record without its reason is corrupt" $
      assertBool "refused" (isLeft (parseFailureRecord (without "reason" failureRecord)))
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
