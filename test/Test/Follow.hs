{-# LANGUAGE OverloadedStrings #-}

-- | A worker that follows its spool: how it waits, what it asks again, what
-- ends it, and that the worker given --follow is the one that waits.
module Test.Follow (tests) where

import Control.Exception (ErrorCall (..), throwIO, try)
import System.Exit (ExitCode (..))
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Spool.Error (SpoolError, corrupt, exitStatus, grantRefused, malformed, retryable, stale)
import qualified Data.Text as T
import Spool.Types (Retry (..), taskIdText)
import Spool.Wire (Lease (..), LeaseRef (..), Task (..), parseLease)
import Spool.Worker.Config (WorkConfig (..))
import Spool.Worker.Connection (Connection (..))
import Spool.Worker.Follow (awaitLease, nextWait)
import Spool.Worker.Run (workWith)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests = testGroup "work --follow"
  [ testGroup "waits"
      [ testCase "double from 1 s up to the cap, and stay there" $
          take 8 (iterate (nextWait 30) 1) @?= [1, 2, 4, 8, 16, 30, 30, 30]
      , testCase "a cap of 1 s is a wait of 1 s" $
          take 3 (iterate (nextWait 1) 1) @?= [1, 1, 1]
      , testCase "a cap that is not a power of two is reached, not passed" $
          take 5 (iterate (nextWait 5) 1) @?= [1, 2, 4, 5, 5]
      ]
  , testCase "an empty spool is asked again after each wait, until a task is put" $ do
      (lease, slept, said, asked) <- awaiting 8
        [Empty, Empty, Empty, Empty, Empty, Empty, Gives "after-idle"]
      fmap leaseTaskText lease @?= Right "after-idle"
      slept @?= [1, 2, 4, 8, 8, 8]
      said @?= 0
      asked @?= 7
  , testCase "each lease starts again from the shortest wait" $ do
      (script, slept, said, connection) <- fake [Empty, Empty, Gives "a", Empty, Gives "b"]
      first <- awaitLease (record slept) (const (bump said)) 30 (leaseOne connection)
      second <- awaitLease (record slept) (const (bump said)) 30 (leaseOne connection)
      map leaseTaskText [first, second] @?= ["a", "b"]
      readIORef slept >>= (@?= [1, 2, 1]) . reverse
      readIORef script >>= (@?= 0) . length
  , testCase "a wait that is stopped asks nothing more" $ do
      (script, _, said, connection) <- fake (replicate 10 Empty)
      calls <- newIORef (0 :: Int)
      let stopping seconds = do
            n <- atomicModifyIORef' calls (\c -> (c + 1, c + 1))
            if n == 3 then throwIO (ErrorCall ("stopped in a wait of " <> show seconds)) else pure ()
      ended <- try (awaitLease stopping (const (bump said)) 30 (leaseOne connection))
      case ended of
        Left (ErrorCall message) -> message @?= "stopped in a wait of 4"
        Right _ -> assertFailure "a stopped wait went on to lease"
      readIORef script >>= (@?= 7) . length
  , testCase "a transport that fails is said, waited for, and asked again" $ do
      (lease, slept, said, asked) <- awaiting 30
        [Throws (retryable "transport ssh exited 255"), Throws (retryable "again"), Gives "later"]
      fmap leaseTaskText lease @?= Right "later"
      slept @?= [1, 2]
      said @?= 2
      asked @?= 3
  , testGroup "a refusal ends the wait at once, with its status"
      [ refused "a denied grant" (grantRefused "grant revoked") 5
      , refused "a malformed exchange" (malformed "two lines") 2
      , refused "corrupt state" (corrupt "bad record") 70
      ]
  , testGroup "the worker"
      [ testCase "with --follow, waits for a task and runs it" $ do
          (_, slept, _, connection) <- fake [Empty, Empty, Gives "followed"]
          failed <- newIORef []
          workWith (record slept) connection { failLeaseWith = failing failed }
            noCapabilities (Just 1) (Just 30)
          readIORef slept >>= (@?= [1, 2]) . reverse
          readIORef failed >>= (@?= [("followed", NoRetry)])
      , testCase "keeps going past a task's failure, and ends with the first one's status" $ do
          (_, slept, _, connection) <- fake [Gives "refused-stale", Empty, Gives "refused-corrupt"]
          answers <- newIORef [Left (stale "late"), Left (corrupt "bad")]
          let refusing _ _ _ = atomicModifyIORef' answers $ \a -> case a of
                answer : rest -> (rest, answer)
                [] -> ([], Right ())
          ended <- try (workWith (record slept) connection { failLeaseWith = refusing }
            noCapabilities (Just 2) (Just 30))
          ended @?= Left (ExitFailure 4)
          readIORef answers >>= (@?= 0) . length
      , testCase "without it, stops when nothing is pending, having waited for nothing" $ do
          (script, slept, _, connection) <- fake [Empty, Gives "never"]
          workWith (record slept) connection noCapabilities Nothing Nothing
          readIORef slept >>= (@?= [])
          readIORef script >>= (@?= 1) . length
      ]
  ]

-- | What one lease request answers.
data Step = Empty | Gives String | Throws SpoolError

-- | A connection whose lease request answers each step in turn, and fails
-- the test if it is asked once more.
fake :: [Step] -> IO (IORef [Step], IORef [Int], IORef Int, Connection)
fake steps = do
  script <- newIORef steps
  slept <- newIORef []
  said <- newIORef 0
  let next = do
        step <- atomicModifyIORef' script $ \s -> case s of
          [] -> ([], Nothing)
          x : rest -> (rest, Just x)
        case step of
          Nothing -> throwIO (ErrorCall "the spool was asked once too often")
          Just Empty -> pure Nothing
          Just (Gives task) -> pure (Just (leaseOf task))
          Just (Throws failure) -> throwIO failure
      unused :: String -> a
      unused what = error ("the worker used " <> what)
  pure (script, slept, said, Connection
    { leaseOne = next
    , renewLease = unused "renew"
    , ackLease = unused "ack"
    , failLeaseWith = unused "fail"
    , withAttachment = unused "fetch"
    , sendResultAttachment = unused "send"
    })

-- | Await one lease with this cap and these steps: the lease or the
-- failure, the waits in order, how many failures were said, and how many
-- requests were made.
awaiting :: Int -> [Step] -> IO (Either SpoolError Lease, [Int], Int, Int)
awaiting capSeconds steps = do
  (script, slept, said, connection) <- fake steps
  lease <- try (awaitLease (record slept) (const (bump said)) capSeconds (leaseOne connection))
  left <- length <$> readIORef script
  (,,,) lease <$> (reverse <$> readIORef slept) <*> readIORef said <*> pure (length steps - left)

refused :: String -> SpoolError -> Int -> TestTree
refused label failure status = testCase label $ do
  (lease, slept, said, asked) <- awaiting 30 [Empty, Throws failure, Gives "never"]
  either (Just . exitStatus) (const Nothing) lease @?= Just status
  slept @?= [1]
  said @?= 0
  asked @?= 2

record :: IORef [Int] -> Int -> IO ()
record slept seconds = modifyIORef' slept (seconds :)

bump :: IORef Int -> IO ()
bump said = modifyIORef' said (+ 1)

failing :: IORef [(String, Retry)] -> LeaseRef -> a -> Retry -> IO (Either SpoolError ())
failing failed (LeaseRef ident _) _ retry = do
  modifyIORef' failed ((T.unpack (taskIdText ident), retry) :)
  pure (Right ())

noCapabilities :: WorkConfig
noCapabilities = WorkConfig 1 30 [] Map.empty

leaseOf :: String -> Lease
leaseOf task = either error id $ parseLease $ BLC.pack $
  "{\"task_id\":\"" <> task <> "\",\"capability\":\"missing@1\",\"lease_id\":\"lease_"
    <> task <> "\",\"worker\":\"w\",\"leased_at\":\"2026-10-15T00:00:00Z\","
    <> "\"payload\":{},\"attachments\":[]}"

leaseTaskText :: Lease -> String
leaseTaskText = T.unpack . taskIdText . taskId . leaseTask
