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
  , mkWorkerName
  , taskIdText
  , validatePeer
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
  , testCase "a task_id may be 128 characters and not 129" $ do
      assertBool "128 accepted" (isRight (mkTaskId (T.replicate 128 "n")))
      assertBool "129 refused" (isLeft (mkTaskId (T.replicate 129 "n")))
  , testCase "a capability may be 128 characters and not 129" $ do
      assertBool "128 accepted" (isRight (mkCapability (T.replicate 126 "c" <> "@1")))
      assertBool "129 refused" (isLeft (mkCapability (T.replicate 127 "c" <> "@1")))
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
  , testGroup "a worker"
      [ testCase "is kept as given" $
          fmap workerNameText (mkWorkerName "worker-one") @?= Right "worker-one"
      , testCase "may be 64 characters and not 65" $ do
          assertBool "64 accepted" (isRight (mkWorkerName (T.replicate 64 "w")))
          assertBool "65 refused" (isLeft (mkWorkerName (T.replicate 65 "w")))
      , testGroup "is refused when it is"
          [ testCase label (assertBool "refused" (isLeft (mkWorkerName name)))
          | (label, name) <-
              [ ("empty", ""), ("two words", "two words"), ("tabbed", "a\tb")
              , ("two lines", "a\nb"), ("outside ASCII", "\321")
              , ("holding a slash", "a/b"), ("holding a NUL", "a\NULb") ]
          ]
      ]
  , testGroup "a peer"
      [ testCase "may hold spaces and any printable character" $
          validatePeer "Alice's laptop, 2nd floor \233" @?= Right ()
      , testCase "may be 128 characters and not 129" $ do
          assertBool "128 accepted" (isRight (validatePeer (T.replicate 128 "p")))
          assertBool "129 refused" (isLeft (validatePeer (T.replicate 129 "p")))
      , testGroup "is refused when it is"
          [ testCase label (assertBool "refused" (isLeft (validatePeer name)))
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
