{-# LANGUAGE OverloadedStrings #-}

-- | A send refused for room waits (ADR 0021): how long, what it sends
-- again, and what ends the wait.
module Test.Room (tests) where

import Control.Exception (try)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import qualified Data.Text as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.QuickCheck (Positive (..), testProperty, (.&&.), (===))
import Spool.Attachments (Attachment (..), mkSha256)
import Spool.Error (SpoolError, exitStatus, neverFits, overLimit, stale)
import Spool.Types (Retry (..))
import Spool.Worker.Room (Sent (..), roomWaits, sendOutputs)

tests :: TestTree
tests = testGroup "a send refused for room"
  [ testGroup "waits"
      [ testCase "double from 1 s up to the renewal interval" $
          roomWaits 4 20 @?= [1, 2, 4, 4, 4, 4, 1]
      , testCase "come to the timeout exactly, the last cut short" $
          roomWaits 30 10 @?= [1, 2, 4, 3]
      , testCase "a renewal interval of 1 s waits 1 s at a time" $
          roomWaits 1 3 @?= [1, 1, 1]
      , testProperty "add up to the timeout, none past the renewal interval" $
          \(Positive renew) (Positive timeout) ->
            let waits = roomWaits renew timeout
            in sum waits === timeout .&&. all (\w -> w >= 1 && w <= renew) waits
      ]
  , testCase "a file is sent again after each wait until there is room, and nothing is run again" $ do
      (sent, sends, paused, said) <- sending [full, full, Right ()] [one]
      sent @?= AllSent [fst one]
      sends @?= ["one", "one", "one"]
      paused @?= [1, 2]
      length said @?= 2
      assertSaid "waits for room" (said !! 0)
      assertSaid "after 3 s" (said !! 1)
  , testCase "files already sent are not sent again" $ do
      (sent, sends, paused, _) <- sending [Right (), full, Right ()] [one, two]
      sent @?= AllSent [fst one, fst two]
      sends @?= ["one", "two", "two"]
      paused @?= [1]
  , testCase "past the timeout it fails with retry, saying how long it waited" $ do
      (sent, sends, paused, said) <- sending (replicate 5 full) [one]
      paused @?= [1, 2, 4, 3]
      sends @?= replicate 5 "one"
      length said @?= 1
      case sent of
        NotSent Retry reason -> do
          assertSaid "waited 10 s for room under max_result_bytes" (T.unpack reason)
          assertSaid "full" (T.unpack reason)
        other -> assertFailure ("not a retried failure: " <> show other)
  , testCase "a file that could never fit fails without retry, and waits for nothing" $ do
      (sent, sends, paused, said) <-
        sending [Left (neverFits "over the grant's max_result_bytes, ever")] [one]
      paused @?= []
      sends @?= ["one"]
      said @?= []
      case sent of
        NotSent NoRetry reason -> assertSaid "max_result_bytes" (T.unpack reason)
        other -> assertFailure ("not a final failure: " <> show other)
  , testCase "a lease lost in a wait ends it, and nothing more is sent" $ do
      (sent, sends, paused, _) <- sendingWith (const (pure False))
        [full, Right ()] [one]
      sent @?= LeaseGone
      sends @?= ["one"]
      paused @?= [1]
  , testCase "any other refusal is thrown, with its status" $ do
      ended <- try (sending [Left (stale "lease is stale")] [one])
      case ended of
        Left refusal -> exitStatus (refusal :: SpoolError) @?= 4
        Right _ -> assertFailure "a stale send was not thrown"
  ]
  where
    full = Left (overLimit "full")
    one = (attachmentOf 'a', "one")
    two = (attachmentOf 'b', "two")

-- | Send these files against these answers, in turn, with waits for a
-- timeout of 10 s and a renewal interval of 30: what came of it, the files
-- sent in order, the waits, and the lines said.
sending
  :: [Either SpoolError ()] -> [(Attachment, FilePath)]
  -> IO (Sent, [FilePath], [Int], [String])
sending = sendingWith (const (pure True))

sendingWith
  :: (Int -> IO Bool) -> [Either SpoolError ()] -> [(Attachment, FilePath)]
  -> IO (Sent, [FilePath], [Int], [String])
sendingWith kept answers files = do
  script <- newIORef answers
  sends <- newIORef []
  paused <- newIORef []
  said <- newIORef []
  let send _ path = do
        modifyIORef' sends (path :)
        atomicModifyIORef' script $ \s -> case s of
          answer : rest -> (rest, answer)
          [] -> ([], Left (stale "the spool was asked once too often"))
      pause seconds = modifyIORef' paused (seconds :) >> kept seconds
  sent <- sendOutputs send pause (record said) (roomWaits 30 10) files
  (,,,) sent <$> backwards sends <*> backwards paused <*> backwards said
  where
    backwards :: IORef [a] -> IO [a]
    backwards ref = reverse <$> readIORef ref
    record ref line = modifyIORef' ref (line :)

assertSaid :: String -> String -> IO ()
assertSaid part line = assertBool (show line <> " does not say " <> show part) (part `isInfixOf` line)

attachmentOf :: Char -> Attachment
attachmentOf c = either error (`Attachment` 1) (mkSha256 (T.replicate 64 (T.singleton c)))
