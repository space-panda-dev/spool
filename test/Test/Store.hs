{-# LANGUAGE OverloadedStrings #-}

-- | The retry cap of ADR 0017: how many attempts a task has had, counted
-- from its failure records, and the lease names those records are found by;
-- and the room a grant's limit leaves for result attachments (ADR 0020).
module Test.Store (tests) where

import Data.Int (Int64)
import Data.List (sortOn)
import qualified Data.Text as T
import qualified Data.Aeson as A
import Spool.Store
  ( Room (..)
  , attemptsBefore
  , fitsLimit
  , isReclaimReason
  , leaseOrder
  , retryCap
  , roomFor
  )
import Spool.Types
  ( Retry (..)
  , leaseSerialAndTask
  , mkLeaseId
  , mkCapability
  , mkTaskId
  , newLeaseId
  , taskIdText
  )
import Spool.Wire (Task (..), newTask)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Test.Tasty.QuickCheck
  ( NonNegative (..)
  , elements
  , forAll
  , listOf1
  , testProperty
  , (===)
  )

tests :: TestTree
tests = testGroup "store" [retryCapTests, limitTests, orderTests]

orderTests :: TestTree
orderTests = testGroup "lease order (ADR 0024)"
  [ testCase "the first put is leased first, whatever its ID" $
      order [("zz", 0, Just 1), ("aa", 0, Just 2), ("mm", 0, Just 3)] @?= ["zz", "aa", "mm"]
  , testCase "a higher priority goes first, then the first put" $
      order [("a", 0, Just 1), ("b", 5, Just 4), ("c", 5, Just 2), ("d", -1, Just 0)]
        @?= ["c", "b", "a", "d"]
  , testCase "a task put before order was kept goes before those put after" $
      order [("new", 0, Just 1), ("old-b", 0, Nothing), ("old-a", 0, Nothing)]
        @?= ["old-a", "old-b", "new"]
  , testCase "priority outranks age, even for a task put before order was kept" $
      order [("old", 0, Nothing), ("urgent", 1, Just 99)] @?= ["urgent", "old"]
  , testCase "only a reclaim for want of renewal can be taken back (ADR 0026)" $
      map isReclaimReason
        [ "reclaimed: not renewed within 300 s"
        , "reclaimed: grant revoked"
        , "exit 3: failed"
        ] @?= [True, False, False]
  ]
  where
    order entries = map (taskIdText . taskId) (sortOn leaseOrder
      [ (newTask (named name) capability A.Null []) { taskPriority = priority, taskPutSerial = serial }
      | (name, priority, serial) <- entries ])
    named name = either error id (mkTaskId name)
    capability = either error id (mkCapability "c@1")

limitTests :: TestTree
limitTests = testGroup "a grant's limit on result attachments"
  [ testCase "a limit of 0 holds nothing, not even an empty file" $
      fitsLimit 0 0 0 @?= False
  , testCase "a file may fill the limit exactly" $
      fitsLimit 10 4 6 @?= True
  , testCase "one byte past the limit is refused" $
      fitsLimit 10 5 6 @?= False
  , testCase "what is held counts" $
      (fitsLimit 10 10 0, fitsLimit 10 11 0) @?= (True, False)
  , testCase "the largest sizes do not wrap" $
      fitsLimit maxBound (toInteger (maxBound :: Int64)) maxBound @?= False
  , testGroup "the room for a file (ADR 0021)"
      [ testCase "none, ever, under a limit of 0, as every 0.0.3 grant holds" $
          roomFor 0 0 0 0 @?= NoRoomEver
      , testCase "none, ever, for a file larger than the limit" $
          roomFor 10 0 0 11 @?= NoRoomEver
      , testCase "none, ever, beside what its own lease staged" $
          (roomFor 10 4 4 6, roomFor 10 5 5 6) @?= (HasRoom, NoRoomEver)
      , testCase "none now, while others hold it" $
          roomFor 10 2 8 6 @?= NoRoomNow
      , testCase "the largest sizes do not wrap" $
          roomFor maxBound big big maxBound @?= NoRoomEver
      ]
  ]
  where
    big = toInteger (maxBound :: Int64)

retryCapTests :: TestTree
retryCapTests = testGroup "retry cap"
  [ testCase "three attempts in all" (retryCap @?= 2)
  , testCase "a task with no records has had no attempt"
      (attemptsBefore [] @?= 0)
  , testCase "every retried record is an attempt"
      (attemptsBefore [(1, Retry), (2, Retry)] @?= 2)
  , testCase "the order the records are read in does not matter"
      (attemptsBefore [(5, Retry), (2, NoRetry), (3, Retry)] @?= 2)
  , testCase "retries before a final failure do not count"
      (attemptsBefore [(1, Retry), (2, Retry), (3, NoRetry), (4, Retry)] @?= 1)
  , testCase "a task that failed for good starts afresh"
      (attemptsBefore [(1, Retry), (2, Retry), (3, NoRetry)] @?= 0)
  , testCase "only the latest final failure resets the count"
      (attemptsBefore [(1, NoRetry), (2, Retry), (3, NoRetry), (4, Retry), (5, Retry)]
        @?= 2)
  , testCase "a lease's name gives its serial and task" $ do
      task <- either assertFailure pure (mkTaskId "task_with_7_parts")
      leaseSerialAndTask (newLeaseId 1700000000000000 42 task) @?= Just (42, task)
  , testProperty "a lease made here is read back" $
      forAll (listOf1 (elements "abcXYZ019._-")) $ \name ->
        \(NonNegative micros) (NonNegative serial) ->
          case mkTaskId (T.pack name) of
            Left _ -> True === True
            Right task ->
              leaseSerialAndTask (newLeaseId micros serial task) === Just (serial, task)
  , testCase "a lease without a serial names no task" $ do
      lease <- either assertFailure pure (mkLeaseId "lease_123_task-one")
      leaseSerialAndTask lease @?= Nothing
  ]
