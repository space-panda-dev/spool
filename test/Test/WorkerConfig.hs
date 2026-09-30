{-# LANGUAGE OverloadedStrings #-}

-- | The worker's configuration: defaults, required fields, and the rule that
-- a number is used as written or refused, never wrapped.
module Test.WorkerConfig (tests) where

import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.Either (isLeft)
import Data.Int (Int64)
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
      wcRenewSeconds config @?= 30
      wcEnv config @?= []
  , testCase "a capability reads as written" $ do
      config <- parsed (document "" capabilityBody)
      KM.lookup (K.fromText "classify@1") (wcCapabilities config)
        @?= Just (CapabilityConfig "/bin/cat" ["-u"] 5 1024 65536)
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
      ]
  , testGroup "each limit is refused one above it"
      [ refused "max_concurrent" (document (field "max_concurrent" (intMax + 1)) capabilityBody)
      , refused "renew_seconds" (document (field "renew_seconds" (secondsMax + 1)) capabilityBody)
      , refused "timeout_seconds" (document "" (capability (secondsMax + 1) 1 1))
      , refused "max_payload_bytes" (document "" (capability 1 (int64Max + 1) 1))
      , refused "max_output_bytes" (document "" (capability 1 1 (int64Max + 1)))
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

capabilityField :: Integral a => (CapabilityConfig -> a) -> WorkConfig -> Integer
capabilityField get config =
  maybe (-1) (toInteger . get) (KM.lookup (K.fromText "classify@1") (wcCapabilities config))

atLimit :: String -> Integer -> BL.ByteString -> (WorkConfig -> Integer) -> TestTree
atLimit label limit bytes get = testCase label $ do
  config <- parsed bytes
  get config @?= limit

refused :: String -> BL.ByteString -> TestTree
refused label bytes = testCase label $
  assertBool "refused" (isLeft (parseWorkConfig bytes))
