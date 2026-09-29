{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | How a command ends when it cannot go on: a message on stderr and one of
-- the protocol's exit codes.
module Spool.Failure
  ( SpoolFailure (..)
  , failWith
  , throwFailure
  ) where

import qualified Data.ByteString.Lazy.Char8 as BLC
import System.Exit (ExitCode (..), exitWith)
import System.IO (stderr)

data SpoolFailure = SpoolFailure Int String

failWith :: Int -> String -> IO a
failWith code message = do
  BLC.hPutStrLn stderr (BLC.pack message)
  exitWith (ExitFailure code)

throwFailure :: SpoolFailure -> IO a
throwFailure (SpoolFailure code message) = failWith code ("spool: " <> message)
