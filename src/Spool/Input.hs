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
import Spool.Error (malformed, orThrow)
import Spool.Types (LeaseId, TaskId)
import Spool.Wire (Task, parseAck, parseFail, parseLeaseRef, parseTask)

parseTaskLine :: BL.ByteString -> IO Task
parseTaskLine = orThrow malformed . parseTask

parseAckLine :: BL.ByteString -> IO (TaskId, LeaseId, A.Value)
parseAckLine = orThrow malformed . parseAck

parseLeaseRefLine :: BL.ByteString -> IO (TaskId, LeaseId)
parseLeaseRefLine = orThrow malformed . parseLeaseRef

parseFailLine :: BL.ByteString -> IO (TaskId, LeaseId, T.Text)
parseFailLine = orThrow malformed . parseFail

isBlank :: BL.ByteString -> Bool
isBlank = all (`elem` [' ', '\t', '\r', '\n']) . BLC.unpack

inputLines :: IO [BL.ByteString]
inputLines = filter (not . isBlank) . BLC.lines <$> BL.getContents
