-- | How a command ends when it cannot go on.
--
-- Every failure the protocol names is one value of one type, thrown where it
-- is found and caught once, at the entry point, which alone turns it into a
-- message and an exit status.  Nothing below the entry point exits.
module Spool.Error
  ( ErrorClass (..)
  , SpoolError (..)
  , malformed
  , conflict
  , stale
  , grantRefused
  , corrupt
  , retryable
  , orThrow
  , withContext
  , exitStatus
  , fromExitStatus
  , render
  , report
  ) where

import Control.Exception (Exception, throwIO)
import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.IO (stderr)

-- | The protocol's failures, one for each exit status that carries a message.
data ErrorClass
  = Malformed     -- ^ 2: malformed input
  | Conflict      -- ^ 3: task conflict
  | Stale         -- ^ 4: stale or unknown lease
  | GrantRefused  -- ^ 5: grant missing, revoked, or expired
  | Corrupt       -- ^ 70: corrupt durable state
  | Retryable     -- ^ 75: retryable filesystem failure
  deriving (Bounded, Enum, Eq, Show)

data SpoolError
  = SpoolError ErrorClass String
  -- | A command line that names no command.  Exit 2; the message is printed
  -- as it stands, because the usage text is not a sentence about a failure.
  | Usage String
  -- | @lease@ found no pending task.  Exit 1, and nothing to say.
  | NothingPending
  deriving (Eq, Show)

instance Exception SpoolError

malformed, conflict, stale, grantRefused, corrupt, retryable :: String -> SpoolError
malformed = SpoolError Malformed
conflict = SpoolError Conflict
stale = SpoolError Stale
grantRefused = SpoolError GrantRefused
corrupt = SpoolError Corrupt
retryable = SpoolError Retryable

-- | Take the value, or throw what the refusal means here.  The same refusal
-- is malformed input when it comes from a caller and corrupt state when it
-- comes from the spool's own files, so the place that knows the source says
-- which.
orThrow :: (String -> SpoolError) -> Either String a -> IO a
orThrow classify = either (throwIO . classify) pure

-- | Say where a failure happened without changing what it is.
withContext :: String -> SpoolError -> SpoolError
withContext context failure = case failure of
  SpoolError kind message -> SpoolError kind (context <> message)
  Usage message -> Usage (context <> message)
  NothingPending -> NothingPending

exitStatus :: SpoolError -> Int
exitStatus failure = case failure of
  NothingPending -> 1
  Usage _ -> 2
  SpoolError Malformed _ -> 2
  SpoolError Conflict _ -> 3
  SpoolError Stale _ -> 4
  SpoolError GrantRefused _ -> 5
  SpoolError Corrupt _ -> 70
  SpoolError Retryable _ -> 75

-- | The failure a spool reports with this exit status, for a worker that
-- reaches its spool through a transport and gets the status back. The
-- message is what the spool said on stderr.
fromExitStatus :: Int -> String -> Maybe SpoolError
fromExitStatus status message = case status of
  2 -> Just (malformed message)
  3 -> Just (conflict message)
  4 -> Just (stale message)
  5 -> Just (grantRefused message)
  70 -> Just (corrupt message)
  75 -> Just (retryable message)
  _ -> Nothing

-- | The line for stderr, or nothing when there is nothing to say.
render :: SpoolError -> Maybe String
render failure = case failure of
  SpoolError _ message -> Just ("spool: " <> message)
  Usage message -> Just message
  NothingPending -> Nothing

-- | Write a failure to stderr, as UTF-8 whatever the locale.
report :: SpoolError -> IO ()
report failure = case render failure of
  Nothing -> pure ()
  Just line -> BS.hPut stderr (TE.encodeUtf8 (T.pack line) <> BS.singleton 10)
