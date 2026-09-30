{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The worker's configuration: which executable each capability maps to, and
-- the limits its owner set.
module Spool.Worker.Config
  ( CapabilityConfig (..)
  , WorkConfig (..)
  , runWorkShow
  , loadWorkConfig
  , parseWorkConfig
  , maxDelaySeconds
  , encodeWorkConfig
  ) where

import Control.Monad (unless)
import Data.Aeson ((.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.Int (Int64)
import qualified Data.Text as T
import System.Directory (executable, getPermissions)
import System.Exit (exitSuccess)
import System.FilePath (isAbsolute)
import Spool.Failure (failWith)
import Spool.Files (fileExists)
import Spool.Wire (Object, validateCapability, rejectUnknown, canonical)

data CapabilityConfig = CapabilityConfig
  { capExec :: FilePath
  , capArgs :: [String]
  , capTimeoutSeconds :: Int
  , capMaxPayloadBytes :: Int64
  , capMaxOutputBytes :: Int64
  } deriving (Eq, Show)

data WorkConfig = WorkConfig
  { wcMaxConcurrent :: Int
  , wcRenewSeconds :: Int
  , wcEnv :: [(String, String)]
  , wcCapabilities :: KM.KeyMap CapabilityConfig
  } deriving (Eq, Show)

runWorkShow :: FilePath -> IO ()
runWorkShow configPath = do
  config <- loadWorkConfig configPath
  BLC.putStrLn (encodeWorkConfig config)
  exitSuccess

loadWorkConfig :: FilePath -> IO WorkConfig
loadWorkConfig configPath = do
  exists <- fileExists configPath
  unless exists (failWith 2 ("spool: config file not found: " <> configPath))
  bytes <- BL.readFile configPath
  case parseWorkConfig bytes of
    Left message -> failWith 2 ("spool: " <> message)
    Right config -> do
      checked <- checkExecutables config
      case checked of
        Left message -> failWith 2 ("spool: " <> message)
        Right () -> pure config

parseWorkConfig :: BL.ByteString -> Either String WorkConfig
parseWorkConfig bytes = do
  value <- A.eitherDecode bytes
  case value of
    A.Object object -> do
      rejectUnknown ["max_concurrent", "renew_seconds", "env", "capabilities"] object
      maxConcurrent <- positiveField maxBound "max_concurrent" (Just 1) object
      renewSeconds <- positiveField maxDelaySeconds "renew_seconds" (Just 30) object
      envPairs <- optionalEnvMap object
      capsObject <- requiredObject "capabilities" object
      caps <- traverse (uncurry parseCapabilityEntry) (KM.toList capsObject)
      pure WorkConfig
        { wcMaxConcurrent = maxConcurrent
        , wcRenewSeconds = renewSeconds
        , wcEnv = envPairs
        , wcCapabilities = KM.fromList caps
        }
    _ -> Left "config must be a JSON object"

requiredObject :: T.Text -> Object -> Either String Object
requiredObject key object = case KM.lookup (K.fromText key) object of
  Just (A.Object inner) -> Right inner
  Just _ -> Left (T.unpack key <> " must be an object")
  Nothing -> Left ("config is missing " <> T.unpack key)

-- | A whole number from 1 through `limit`. aeson's bounded decoder does the
-- conversion: it refuses a fraction or a value outside the target type where
-- rounding through Integer would wrap it, and it never expands a huge
-- exponent to find out.
positiveField
  :: (A.FromJSON a, Integral a, Show a)
  => a -> T.Text -> Maybe a -> Object -> Either String a
positiveField limit key def object = case KM.lookup (K.fromText key) object of
  Nothing -> maybe (Left ("missing " <> T.unpack key)) Right def
  Just value@(A.Number _) -> case A.fromJSON value of
    A.Success number | number > 0 && number <= limit -> Right number
    _ -> Left outOfRange
  Just _ -> Left outOfRange
  where
    outOfRange = T.unpack key <> " must be a positive integer no greater than "
      <> show limit

-- | The largest number of seconds whose microseconds still fit the Int that
-- `threadDelay` takes.
maxDelaySeconds :: Int
maxDelaySeconds = maxBound `div` 1000000

optionalEnvMap :: Object -> Either String [(String, String)]
optionalEnvMap object = case KM.lookup "env" object of
  Nothing -> Right []
  Just (A.Object inner) -> traverse envPair (KM.toList inner)
  Just _ -> Left "env must be an object"
  where
    envPair (key, A.String value) = Right (T.unpack (K.toText key), T.unpack value)
    envPair (key, _) = Left ("env." <> T.unpack (K.toText key) <> " must be a string")

optionalArgList :: Object -> Either String [String]
optionalArgList object = case KM.lookup "args" object of
  Nothing -> Right []
  Just (A.Array values) -> traverse asArgString (foldr (:) [] values)
  Just _ -> Left "args must be an array of strings"
  where
    asArgString (A.String value) = Right (T.unpack value)
    asArgString _ = Left "args must be an array of strings"

requiredCapText :: T.Text -> Object -> Either String T.Text
requiredCapText key object = case KM.lookup (K.fromText key) object of
  Just (A.String value) | not (T.null value) -> Right value
  Just (A.String _) -> Left (T.unpack key <> " must be non-empty")
  Just _ -> Left (T.unpack key <> " must be a string")
  Nothing -> Left ("missing " <> T.unpack key)

parseCapabilityEntry :: K.Key -> A.Value -> Either String (K.Key, CapabilityConfig)
parseCapabilityEntry key value = do
  let capText = K.toText key
  validateCapability capText
  case value of
    A.Object object -> do
      rejectUnknown
        ["exec", "args", "timeout_seconds", "max_payload_bytes", "max_output_bytes"]
        object
      execPath <- requiredCapText "exec" object
      unless (isAbsolute (T.unpack execPath))
        (Left (T.unpack capText <> ": exec must be an absolute path"))
      args <- optionalArgList object
      timeoutSeconds <- positiveField maxDelaySeconds "timeout_seconds" Nothing object
      maxPayload <- positiveField maxBound "max_payload_bytes" Nothing object
      maxOutput <- positiveField maxBound "max_output_bytes" Nothing object
      pure (key, CapabilityConfig (T.unpack execPath) args timeoutSeconds maxPayload maxOutput)
    _ -> Left (T.unpack capText <> " must be an object")

checkExecutables :: WorkConfig -> IO (Either String ())
checkExecutables config = go (KM.toList (wcCapabilities config))
  where
    go [] = pure (Right ())
    go ((key, capConfig) : rest) = do
      result <- checkOneExecutable (K.toText key) capConfig
      case result of
        Left message -> pure (Left message)
        Right () -> go rest

checkOneExecutable :: T.Text -> CapabilityConfig -> IO (Either String ())
checkOneExecutable capText capConfig
  | not (isAbsolute (capExec capConfig)) =
      pure (Left (T.unpack capText <> ": exec must be an absolute path"))
  | otherwise = do
      exists <- fileExists (capExec capConfig)
      if not exists
        then pure (Left (T.unpack capText <> ": exec does not exist: " <> capExec capConfig))
        else do
          permissions <- getPermissions (capExec capConfig)
          if executable permissions
            then pure (Right ())
            else pure (Left (T.unpack capText <> ": exec is not executable: " <> capExec capConfig))

encodeWorkConfig :: WorkConfig -> BL.ByteString
encodeWorkConfig config = canonical (A.object
  [ "max_concurrent" .= wcMaxConcurrent config
  , "renew_seconds" .= wcRenewSeconds config
  , "env" .= KM.fromList [ (K.fromText (T.pack k), A.toJSON v) | (k, v) <- wcEnv config ]
  , "capabilities" .= KM.fromList
      [ (key, encodeCapabilityConfig capConfig) | (key, capConfig) <- KM.toList (wcCapabilities config) ]
  ])

encodeCapabilityConfig :: CapabilityConfig -> A.Value
encodeCapabilityConfig capConfig = A.object
  [ "exec" .= capExec capConfig
  , "args" .= capArgs capConfig
  , "timeout_seconds" .= capTimeoutSeconds capConfig
  , "max_payload_bytes" .= capMaxPayloadBytes capConfig
  , "max_output_bytes" .= capMaxOutputBytes capConfig
  ]
