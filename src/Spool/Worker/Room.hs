{-# LANGUAGE OverloadedStrings #-}

-- | Sending a run's outputs under a grant's limit (ADR 0021). A file the
-- grant has no room for now is sent again after a wait, keeping the lease
-- and what is already staged; the waits start at 1 second and double up to
-- the renewal interval, and together come to the capability's timeout. A
-- file the grant could never hold is not waited for.
--
-- Nothing here starts a thread: the wait is the caller's, and it answers
-- whether the lease still stands.
module Spool.Worker.Room
  ( Sent (..)
  , roomWaits
  , sendOutputs
  ) where

import Control.Exception (throwIO)
import Control.Monad (unless, when)
import qualified Data.Text as T
import qualified Spool.Attachments as SA
import Spool.Error (ErrorClass (..), SpoolError (..), withContext)
import Spool.Types (Retry (..))
import Spool.Worker.Follow (nextWait)

-- | What came of sending a run's outputs.
data Sent
  = AllSent [SA.Attachment]
    -- ^ Every file, in the order sent.
  | NotSent Retry T.Text
  | LeaseGone
    -- ^ The lease was lost in a wait for room.
  deriving (Eq, Show)

-- | The waits a run may make for room, given the renewal interval and the
-- capability's timeout: 1 second, doubling up to the interval, until they
-- add up to the timeout. The last is cut short to come to it exactly.
roomWaits :: Int -> Int -> [Int]
roomWaits renewSeconds timeoutSeconds = go 0 (min 1 renewSeconds)
  where
    go waited step
      | waited >= timeoutSeconds = []
      | otherwise =
          let this = min step (timeoutSeconds - waited)
          in this : go (waited + this) (nextWait renewSeconds step)

-- | Send each file, given how to send one, how to wait so many seconds
-- (false when the lease was lost meanwhile), how to say a line, and the
-- waits allowed. A file refused for room now is sent again after the next
-- wait; with none left, the run fails with retry. One the grant could
-- never hold fails it for good. Any other refusal is thrown.
sendOutputs
  :: (SA.Attachment -> FilePath -> IO (Either SpoolError ()))
  -> (Int -> IO Bool)
  -> (String -> IO ())
  -> [Int]
  -> [(SA.Attachment, FilePath)]
  -> IO Sent
sendOutputs send pause say = go 0 False []
  where
    go _ _ sent _ [] = pure (AllSent (reverse sent))
    go waited waiting sent waits files@((attachment, path) : rest) = do
      result <- send attachment path
      case result of
        Right () -> do
          when waiting $ say ("room for result attachment " <> digest
            <> " after " <> show waited <> " s, sending on")
          go waited False (attachment : sent) waits rest
        Left (SpoolError OverLimit message) -> case waits of
          [] -> pure (NotSent Retry (T.pack ("result attachment " <> digest
            <> " waited " <> show waited <> " s for room under max_result_bytes: "
            <> message)))
          this : later -> do
            unless waiting $ say ("result attachment " <> digest
              <> " waits for room: " <> message)
            kept <- pause this
            if kept
              then go (waited + this) True sent later files
              else pure LeaseGone
        Left (SpoolError NeverFits message) -> pure (NotSent NoRetry
          (T.pack ("result attachment " <> digest <> " refused: " <> message)))
        Left refusal -> throwIO (withContext "work: send: " refusal)
      where
        digest = T.unpack (SA.sha256Text (SA.attachmentSha256 attachment))
