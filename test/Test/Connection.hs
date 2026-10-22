{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | A worker's connection to a spool on another machine, through a
-- transport that fails the way ssh does: it ends without reading the
-- request, as ssh does when it cannot connect (ADR 0027).
module Test.Connection (tests) where

import Control.Exception (SomeException, fromException, try)
import qualified Data.Aeson as A
import qualified Data.Text as T
import Spool.Error (ErrorClass (..), SpoolError (..))
import Spool.Types (mkLeaseId, mkTaskId)
import Spool.Wire (LeaseRef (..))
import Spool.Worker.Connection (Connection (..), remoteConnection)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase)

tests :: TestTree
tests = testGroup "a remote connection"
  [ testCase "a transport that ends without reading the request could not reach the spool" $
      -- The result is larger than a pipe holds, so the write is still
      -- waiting when the transport closes its input: the pipe breaks at
      -- that exact moment, every time.
      couldNotReach $ do
        reference <- lease
        ackLease (cutTransport 255) reference (A.String (T.replicate 200000 "x")) []
  , testCase "a renewal whose transport ends without reading it could not reach the spool" $
      couldNotReach (lease >>= renewLease (cutTransport 255))
  , testCase "a broken pipe from a spool that named its failure is that failure" $ do
      ended <- try (lease >>= \reference ->
        ackLease (cutTransport 5) reference (A.String (T.replicate 200000 "x")) [])
      case ended of
        Left (SpoolError GrantRefused _) -> pure ()
        other -> assertFailure ("expected the spool's exit 5, got " <> show other)
  ]

-- | A transport that closes its input unread, says why on stderr, and
-- exits with this status.
cutTransport :: Int -> Connection
cutTransport status = remoteConnection "/bin/sh"
  [ "-c"
  , "exec 0<&-; echo 'ssh: connect to host spool-host: Connection refused' >&2; exit "
      <> show status
  , "transport"
  ]

lease :: IO LeaseRef
lease = either assertFailure pure
  (LeaseRef <$> mkTaskId "t-one" <*> mkLeaseId "lease_1_1_t-one")

-- | The request ended as one the transport could not carry, to be made
-- again, and not as any other exception.
couldNotReach :: IO (Either SpoolError ()) -> Assertion
couldNotReach request = do
  ended <- try request
  case ended of
    Left (exception :: SomeException) -> case fromException exception of
      Just (SpoolError Retryable _) -> pure ()
      _ -> assertFailure ("expected a transport failure to retry, got " <> show exception)
    Right answer -> assertFailure ("expected a transport failure, got " <> show answer)
