-- | How much room a worker's disk has, for the floor a fetch must leave
-- (ADR 0025). The boring way: POSIX @df -P@, whose output has one line for
-- each file system and its fields in a fixed order, on every system the
-- worker runs on. Nothing here is asked unless the configuration sets a
-- floor.
module Spool.Worker.Disk
  ( freeBytes
  , parseDfOutput
  , mayFetch
  ) where

import Control.Exception (throwIO)
import System.Exit (ExitCode (..))
import System.Process (proc, readCreateProcessWithExitCode)
import Spool.Error (retryable)

-- | The bytes free to an unprivileged writer on the file system that holds
-- this directory.
freeBytes :: FilePath -> IO Integer
freeBytes directory = do
  (status, output, errors) <-
    readCreateProcessWithExitCode (proc "df" ["-P", "-k", directory]) ""
  case status of
    ExitFailure code -> throwIO (retryable
      ("df " <> directory <> " exited " <> show code <> ": " <> errors))
    ExitSuccess -> either (throwIO . retryable) pure (parseDfOutput output)

-- | The available bytes @df -P -k@ reports: the fourth field of its last
-- line, in 1024-byte blocks.
parseDfOutput :: String -> Either String Integer
parseDfOutput output = case reverse (lines output) of
  final : _ : _ -> case words final of
    _ : _ : _ : available : _ -> case reads available of
      [(blocks, "")] | blocks >= 0 -> Right (blocks * 1024)
      _ -> Left ("df reported an available size that is not a count: " <> available)
    _ -> Left ("df reported a line with too few fields: " <> final)
  _ -> Left "df reported no file system"

-- | Whether a fetch of this many bytes may begin, given how many tasks the
-- worker leased before it still holds: always when no floor is set or
-- there are none, so the first task held never waits; otherwise only if
-- the bytes free leave the floor once they are written.
mayFetch :: Maybe Integer -> Int -> Integer -> Integer -> Bool
mayFetch Nothing _ _ _ = True
mayFetch (Just floorBytes) others free size = others == 0 || free - size >= floorBytes
