{-# LANGUAGE OverloadedStrings #-}

-- | The retry cap of ADR 0017: how many attempts a task has had, counted
-- from its failure records, and the lease names those records are found by.
module Test.Store (tests) where

import qualified Data.Text as T
import Spool.Store (attemptsBefore, retryCap)
import Spool.Types
  ( Retry (..)
  , leaseSerialAndTask
  , mkLeaseId
  , mkTaskId
  , newLeaseId
  )
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
tests = testGroup "retry cap"
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
