-- | JSONL from stdin, and the point where a malformed line becomes exit 2.
module Spool.Input
  ( parseTaskLine
  , parseAckLine
  , parseLeaseRefLine
  , parseFailLine
  , inputLines
  ) where

import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import Spool.Error (malformed, orThrow)
import Spool.Wire
  ( Ack
  , FailRequest
  , LeaseRef
  , Task
  , parseAck
  , parseFail
  , parseLeaseRef
  , parseTask
  )

parseTaskLine :: BL.ByteString -> IO Task
parseTaskLine = orThrow malformed . parseTask

parseAckLine :: BL.ByteString -> IO Ack
parseAckLine = orThrow malformed . parseAck

parseLeaseRefLine :: BL.ByteString -> IO LeaseRef
parseLeaseRefLine = orThrow malformed . parseLeaseRef

parseFailLine :: BL.ByteString -> IO FailRequest
parseFailLine = orThrow malformed . parseFail

isBlank :: BL.ByteString -> Bool
isBlank = all (`elem` [' ', '\t', '\r', '\n']) . BLC.unpack

inputLines :: IO [BL.ByteString]
inputLines = filter (not . isBlank) . BLC.lines <$> BL.getContents
