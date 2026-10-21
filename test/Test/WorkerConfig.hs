{-# LANGUAGE OverloadedStrings #-}

-- | The worker's configuration: defaults, required fields, and the rule that
-- a number is used as written or refused, never wrapped.
module Test.WorkerConfig (tests) where

import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.Either (isLeft)
import Data.Int (Int64)
import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import Spool.Types (Capability, mkCapability)
import Spool.Worker.Config
  ( CapabilityConfig (..)
  , WorkConfig (..)
  , encodeWorkConfig
  , maxDelaySeconds
  , parseWorkConfig
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests = testGroup "worker configuration"
  [ testCase "limits left out take their defaults" $ do
      config <- parsed (document "" capabilityBody)
      wcMaxConcurrent config @?= 1
      wcPrefetch config @?= 0
      wcMinFreeBytes config @?= Nothing
      wcRenewSeconds config @?= 30
      wcEnv config @?= []
  , testCase "a worker may lease ahead, above a floor of free space (ADR 0025)" $ do
      config <- parsed (document "\"prefetch\":1,\"min_free_bytes\":6000000000," capabilityBody)
      (wcPrefetch config, wcMinFreeBytes config) @?= (1, Just 6000000000)
      parseWorkConfig (encodeWorkConfig config) @?= Right config
  , testCase "a configuration without them shows as it did" $ do
      config <- parsed (document "" capabilityBody)
      assertBool "no prefetch shown" (not ("prefetch" `isInfixOf` BLC.unpack (encodeWorkConfig config)))
  , testCase "a negative prefetch is refused" $
      assertBool "refused" (isLeft (parseWorkConfig (document "\"prefetch\":-1," capabilityBody)))
  , testCase "a floor of 0 is refused" $
      assertBool "refused" (isLeft (parseWorkConfig (document "\"min_free_bytes\":0," capabilityBody)))
  , testCase "a capability reads as written" $ do
      config <- parsed (document "" capabilityBody)
      Map.toList (wcCapabilities config)
        @?= [(classify, CapabilityConfig "/bin/cat" ["-u"] 5 1024 65536 Nothing)]
  , testCase "a capability may set how many bytes of result attachments it sends" $ do
      config <- parsed (document "" (withResultLimit "4096"))
      capabilityField' capMaxResultAttachmentBytes config @?= Just (Just 4096)
  , testCase "what --show prints keeps a limit on result attachments" $ do
      config <- parsed (document "" (withResultLimit "4096"))
      parseWorkConfig (encodeWorkConfig config) @?= Right config
  , testCase "what --show prints reads back as the same configuration" $ do
      config <- parsed
        (document "\"max_concurrent\":4,\"renew_seconds\":9,\"env\":{\"PATH\":\"/bin\"}," capabilityBody)
      parseWorkConfig (encodeWorkConfig config) @?= Right config
  , testGroup "each limit is accepted at its largest value"
      [ atLimit "max_concurrent" intMax (document (field "max_concurrent" intMax) capabilityBody)
          (toInteger . wcMaxConcurrent)
      , atLimit "renew_seconds" secondsMax (document (field "renew_seconds" secondsMax) capabilityBody)
          (toInteger . wcRenewSeconds)
      , atLimit "timeout_seconds" secondsMax (document "" (capability secondsMax 1 1))
          (capabilityField capTimeoutSeconds)
      , atLimit "max_payload_bytes" int64Max (document "" (capability 1 int64Max 1))
          (capabilityField capMaxPayloadBytes)
      , atLimit "max_output_bytes" int64Max (document "" (capability 1 1 int64Max))
          (capabilityField capMaxOutputBytes)
      , atLimit "max_result_attachment_bytes" int64Max
          (document "" (withResultLimit (BLC.pack (show int64Max))))
          (capabilityField (maybe (-1) id . capMaxResultAttachmentBytes))
      ]
  , testGroup "each limit is refused one above it"
      [ refused "max_concurrent" (document (field "max_concurrent" (intMax + 1)) capabilityBody)
      , refused "renew_seconds" (document (field "renew_seconds" (secondsMax + 1)) capabilityBody)
      , refused "timeout_seconds" (document "" (capability (secondsMax + 1) 1 1))
      , refused "max_payload_bytes" (document "" (capability 1 (int64Max + 1) 1))
      , refused "max_output_bytes" (document "" (capability 1 1 (int64Max + 1)))
      , refused "max_result_attachment_bytes"
          (document "" (withResultLimit (BLC.pack (show (int64Max + 1)))))
      ]
  , testGroup "a limit on result attachments that is not a whole number of at least 1 is refused"
      [ refused label (document "" (withResultLimit value))
      | (label, value) <- [("zero", "0"), ("negative", "-1"), ("a fraction", "1.5"), ("a string", "\"1\""), ("null", "null")]
      ]
  , testGroup "a number that is not a whole number of at least 1 is refused"
      [ refused "zero" (document (field "max_concurrent" 0) capabilityBody)
      , refused "negative" (document (field "max_concurrent" (-1)) capabilityBody)
      , refused "a fraction" (document "\"max_concurrent\":1.5," capabilityBody)
      , refused "a string" (document "\"max_concurrent\":\"1\"," capabilityBody)
      , refused "one that wraps to a small positive number"
          (document "" (capability (2 ^ (64 :: Int) + 1) 1 1))
      , refused "an exponent too large to expand"
          (document "\"max_concurrent\":1e1000000000," capabilityBody)
      ]
  , testGroup "the shape is checked"
      [ refused "no capabilities" "{}"
      , refused "an unknown field" (document "\"priority\":1," capabilityBody)
      , refused "an unknown capability field"
          (document "" "{\"exec\":\"/bin/cat\",\"timeout_seconds\":1,\"max_payload_bytes\":1,\"max_output_bytes\":1,\"nice\":1}")
      , refused "a relative executable"
          (document "" "{\"exec\":\"bin/cat\",\"timeout_seconds\":1,\"max_payload_bytes\":1,\"max_output_bytes\":1}")
      , refused "a capability without a timeout"
          (document "" "{\"exec\":\"/bin/cat\",\"max_payload_bytes\":1,\"max_output_bytes\":1}")
      , refused "a capability name outside the grammar"
          "{\"capabilities\":{\"classify\":{\"exec\":\"/bin/cat\",\"timeout_seconds\":1,\"max_payload_bytes\":1,\"max_output_bytes\":1}}}"
      , refused "an environment value that is not a string"
          (document "\"env\":{\"N\":1}," capabilityBody)
      ]
  , testCase "the largest delay fits the microseconds it becomes" $ do
      let micros = toInteger maxDelaySeconds * 1000000
      assertBool "fits" (micros <= intMax)
      assertBool "one more second would not" (micros + 1000000 > intMax)
  ]
  where
    intMax = toInteger (maxBound :: Int)
    int64Max = toInteger (maxBound :: Int64)
    secondsMax = toInteger maxDelaySeconds

classify :: Capability
classify = either error id (mkCapability "classify@1")

parsed :: BL.ByteString -> IO WorkConfig
parsed = either assertFailure pure . parseWorkConfig

document :: BL.ByteString -> BL.ByteString -> BL.ByteString
document fields body =
  "{" <> fields <> "\"capabilities\":{\"classify@1\":" <> body <> "}}"

field :: BL.ByteString -> Integer -> BL.ByteString
field name number = "\"" <> name <> "\":" <> BLC.pack (show number) <> ","

capabilityBody :: BL.ByteString
capabilityBody =
  "{\"exec\":\"/bin/cat\",\"args\":[\"-u\"],\"timeout_seconds\":5,\"max_payload_bytes\":1024,\"max_output_bytes\":65536}"

capability :: Integer -> Integer -> Integer -> BL.ByteString
capability timeout payload output =
  "{\"exec\":\"/bin/cat\",\"timeout_seconds\":" <> BLC.pack (show timeout)
    <> ",\"max_payload_bytes\":" <> BLC.pack (show payload)
    <> ",\"max_output_bytes\":" <> BLC.pack (show output) <> "}"

withResultLimit :: BL.ByteString -> BL.ByteString
withResultLimit value =
  "{\"exec\":\"/bin/cat\",\"timeout_seconds\":5,\"max_payload_bytes\":1,\"max_output_bytes\":1,\"max_result_attachment_bytes\":"
    <> value <> "}"

capabilityField' :: (CapabilityConfig -> a) -> WorkConfig -> Maybe a
capabilityField' get config = get <$> Map.lookup classify (wcCapabilities config)

capabilityField :: Integral a => (CapabilityConfig -> a) -> WorkConfig -> Integer
capabilityField get config =
  maybe (-1) (toInteger . get) (Map.lookup classify (wcCapabilities config))

atLimit :: String -> Integer -> BL.ByteString -> (WorkConfig -> Integer) -> TestTree
atLimit label limit bytes get = testCase label $ do
  config <- parsed bytes
  get config @?= limit

refused :: String -> BL.ByteString -> TestTree
refused label bytes = testCase label $
  assertBool "refused" (isLeft (parseWorkConfig bytes))
