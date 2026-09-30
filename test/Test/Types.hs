{-# LANGUAGE OverloadedStrings #-}

-- | The identifiers: what each grammar admits, and that a value made here is
-- one its own grammar admits.
module Test.Types (tests) where

import Data.Either (isLeft, isRight)
import qualified Data.Text as T
import Spool.Types
  ( leaseIdText
  , leaseStarted
  , mkCapability
  , mkLeaseId
  , mkTaskId
  , newLeaseId
  , taskIdText
  , workerNameFromArgument
  , workerNameFromGrant
  , workerNameText
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))
import Test.Tasty.QuickCheck
  ( Gen
  , NonNegative (..)
  , Positive (..)
  , elements
  , forAll
  , listOf1
  , suchThat
  , testProperty
  , (.&&.)
  , (===)
  )

tests :: TestTree
tests = testGroup "identifiers"
  [ testGroup "task_id accepts" (map (good mkTaskId) ["a", "task-one", "A.b_c-9"])
  , testGroup "task_id rejects"
      (map (bad mkTaskId) ["", "a--b", "a/b", "../escape", "a b", "caf\233", "a\nb"])
  , testCase "a task_id reads back as the text it was made from" $
      fmap taskIdText (mkTaskId "task-one") @?= Right "task-one"
  , testGroup "capability accepts"
      (map (good mkCapability) ["classify@1", "opaque.name@1.2", "a-b_c@0"])
  , testGroup "capability rejects"
      (map (bad mkCapability)
        ["", "onlyname", "@1", "classify@", "bad name@1", "bad/name@1", "name@1-2", "a@b@c"])
  , testGroup "lease_id accepts"
      (map (good mkLeaseId) ["lease_1790717360482536_1_task-one", "lease_x"])
  , testGroup "lease_id rejects"
      (map (bad mkLeaseId) ["", "lease", "task_1_1_t", "lease_1--2", "lease_../x", "lease_a b"])
  , testCase "a lease's time is read from its identifier" $
      fmap leaseStarted (mkLeaseId "lease_1790717360482536_1_task-one")
        @?= Right (Just 1790717360482536)
  , testCase "a lease identifier without digits has no time" $
      fmap leaseStarted (mkLeaseId "lease_x") @?= Right Nothing
  , testProperty "a lease made here fits the grammar and keeps its time" $
      forAll taskText $ \text (NonNegative micros) (Positive serial) ->
        case mkTaskId text of
          Left _ -> False === True
          Right task ->
            let made = newLeaseId micros serial task
            in (mkLeaseId (leaseIdText made) === Right made)
                 .&&. (leaseStarted made === Just micros)
  , testGroup "a worker named as an argument"
      [ testCase "is kept as given" $
          fmap workerNameText (workerNameFromArgument "worker-one") @?= Right "worker-one"
      , testCase "may be outside ASCII" $
          fmap workerNameText (workerNameFromArgument "\321") @?= Right "\321"
      , testGroup "is refused when it is"
          [ testCase label (assertBool "refused" (isLeft (workerNameFromArgument name)))
          | (label, name) <-
              [ ("empty", ""), ("two words", "two words"), ("tabbed", "a\tb")
              , ("two lines", "a\nb"), ("ended by a return", "a\r") ]
          ]
      ]
  , testGroup "a worker named in a grant"
      [ testCase "is kept as given" $
          fmap workerNameText (workerNameFromGrant "worker-one") @?= Right "worker-one"
      , testCase "may hold a space, which an argument may not" $ do
          assertBool "the grant rule accepts" (isRight (workerNameFromGrant "two words"))
          assertBool "the argument rule refuses" (isLeft (workerNameFromArgument "two words"))
      , testGroup "is refused when it is"
          [ testCase label (assertBool "refused" (isLeft (workerNameFromGrant name)))
          | (label, name) <-
              [ ("empty", ""), ("two lines", "a\nb"), ("tabbed", "a\tb")
              , ("holding a delete", "a\DELb"), ("holding a NUL", "a\NULb") ]
          ]
      ]
  ]
  where
    good make input = testCase (show input) $
      assertBool "accepted" (isRight (make input))
    bad make input = testCase (show input) $
      assertBool "refused" (isLeft (make input))

taskText :: Gen T.Text
taskText = (T.pack <$> listOf1 (elements (['a' .. 'z'] <> ['0' .. '9'] <> "._-")))
  `suchThat` (not . T.isInfixOf "--")
