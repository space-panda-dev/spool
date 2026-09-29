{-# LANGUAGE OverloadedStrings #-}

-- The shell cannot carry a NUL in SSH_ORIGINAL_COMMAND.  Keep the raw-byte
-- boundary test beside the implementation so the executable's parser is
-- exercised with the bytes an SSH server can supply.
module Main (main) where

import qualified Data.ByteString as BS
import SpoolAccess (RemoteCommand (..), parseRemoteCommand)

main :: IO ()
main = do
  mapM_ expectAccepted
    [ ("lease", RemoteLease Nothing)
    , ("lease --count 1", RemoteLease (Just 1))
    , ("lease --count 9223372036854775807", RemoteLease (Just 9223372036854775807))
    , ("ack", RemoteAck)
    , ("renew", RemoteRenew)
    , ("fail", RemoteFail True)
    , ("fail --no-retry", RemoteFail False)
    , ("fetch", RemoteFetch)
    ]
  mapM_ expectRejected
    [ ("empty", "")
    , ("nul", BS.cons 0 "lease")
    , ("malformed utf8", BS.pack [0xff])
    , ("control", BS.pack [0x1f])
    , ("delete", BS.pack [0x7f])
    , ("overlong", BS.replicate 65 0x78)
    , ("leading space", " lease")
    , ("trailing space", "lease ")
    , ("repeated space", "lease  --count 1")
    , ("tab", "lease\t--count\t1")
    , ("newline", "lease\n")
    , ("quoted", "'lease'")
    , ("backslash", "lease\\")
    , ("separator", "lease;status")
    , ("and separator", "lease && status")
    , ("pipeline", "lease | status")
    , ("substitution", "$(status)")
    , ("glob", "lease*")
    , ("option injection", "lease --worker other")
    , ("local put", "put")
    , ("local results", "results")
    , ("local failures", "failures")
    , ("local status", "status")
    , ("local reclaim", "reclaim --older-than 0")
    , ("local grant", "grant --worker other")
    , ("local revoke", "revoke --grant grant_deadbeef")
    , ("missing count", "lease --count")
    , ("zero count", "lease --count 0")
    , ("leading zero", "lease --count 01")
    , ("signed count", "lease --count +1")
    , ("negative count", "lease --count -1")
    , ("fractional count", "lease --count 1.0")
    , ("count newline", "lease --count 1\n")
    , ("count over maximum", "lease --count 9223372036854775808")
    , ("count too long", "lease --count 111111111111111111111")
    , ("extra word", "lease extra")
    , ("unknown option", "--count 1")
    ]

expectAccepted :: (BS.ByteString, RemoteCommand) -> IO ()
expectAccepted (input, expected) = case parseRemoteCommand input of
  Right actual | actual == expected -> pure ()
  other -> fail ("accepted parser case failed: " <> show input <> " -> " <> show other)

expectRejected :: (String, BS.ByteString) -> IO ()
expectRejected (label, input) = case parseRemoteCommand input of
  Left _ -> pure ()
  Right actual -> fail (label <> " escaped parser as " <> show actual)
