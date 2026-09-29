{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | JSONL from stdin, and the point where a malformed line becomes exit 2.
module Spool.Input
  ( parseTaskLine
  , parseAckLine
  , parseLeaseRefLine
  , parseFailLine
  , inputLines
  ) where

import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import qualified Data.Text as T
import Spool.Failure (SpoolFailure (..), throwFailure)
import Spool.Wire (Task (..), parseTask, parseAck, parseFail, parseLeaseRef)

parseTaskLine :: BL.ByteString -> IO Task
parseTaskLine bytes = case parseTask bytes of
  Left message -> throwFailure (SpoolFailure 2 message)
  Right task -> pure task

parseAckLine :: BL.ByteString -> IO (T.Text, T.Text, A.Value)
parseAckLine bytes = case parseAck bytes of
  Left message -> throwFailure (SpoolFailure 2 message)
  Right ack -> pure ack

parseLeaseRefLine :: BL.ByteString -> IO (T.Text, T.Text)
parseLeaseRefLine bytes = case parseLeaseRef bytes of
  Left message -> throwFailure (SpoolFailure 2 message)
  Right reference -> pure reference

parseFailLine :: BL.ByteString -> IO (T.Text, T.Text, T.Text)
parseFailLine bytes = case parseFail bytes of
  Left message -> throwFailure (SpoolFailure 2 message)
  Right value -> pure value

isBlank :: BL.ByteString -> Bool
isBlank = all (`elem` [' ', '\t', '\r', '\n']) . BLC.unpack

inputLines :: IO [BL.ByteString]
inputLines = filter (not . isBlank) . BLC.lines <$> BL.getContents
