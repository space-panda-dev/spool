-- | The failures: each has the exit status the protocol gives it, and says
-- what the protocol says it says.
module Test.Error (tests) where

import Control.Exception (try)
import Data.List (nub)
import Spool.Error
  ( ErrorClass (..)
  , SpoolError (..)
  , exitStatus
  , malformed
  , orThrow
  , render
  , stale
  , withContext
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests = testGroup "failures"
  [ testGroup "each kind has the exit status of the protocol's table"
      [ testCase (show kind) (exitStatus (SpoolError kind "x") @?= status)
      | (kind, status) <- table
      ]
  , testCase "the table names every kind there is" $
      map fst table @?= [minBound .. maxBound]
  , testCase "no two kinds share an exit status" $ do
      let statuses = map snd table <> [exitStatus NothingPending]
      statuses @?= nub statuses
  , testCase "a command line that names no command is malformed input" $
      exitStatus (Usage "usage: spool ...") @?= 2
  , testCase "a lease that finds nothing pending exits 1 and says nothing" $ do
      exitStatus NothingPending @?= 1
      render NothingPending @?= Nothing
  , testCase "a failure is said under the program's name" $
      render (stale "lease is unknown or stale")
        @?= Just "spool: lease is unknown or stale"
  , testCase "the usage text is printed as it stands" $
      render (Usage "usage: spool --dir DIR init") @?= Just "usage: spool --dir DIR init"
  , testCase "context is added in front and changes nothing else" $ do
      let failure = withContext "work: " (stale "lease is stale")
      failure @?= stale "work: lease is stale"
      exitStatus failure @?= 4
  , testCase "a refusal is thrown as what its source makes it" $ do
      thrown <- try (orThrow malformed (Left "task is missing payload" :: Either String ()))
      thrown @?= Left (malformed "task is missing payload")
  , testCase "a value is handed on untouched" $ do
      kept <- orThrow malformed (Right 'x')
      assertBool "kept" (kept == 'x')
  ]

-- | The exit codes of spec/protocol.md, for the failures that carry a message.
table :: [(ErrorClass, Int)]
table =
  [ (Malformed, 2)
  , (Conflict, 3)
  , (Stale, 4)
  , (GrantRefused, 5)
  , (Corrupt, 70)
  , (Retryable, 75)
  ]
