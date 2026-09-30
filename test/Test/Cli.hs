{-# LANGUAGE OverloadedStrings #-}

-- | The command line: each documented form names its command, and nothing
-- else does.
module Test.Cli (tests) where

import Data.Either (isLeft)
import Spool.Cli (Command (..), parseCommand, parseWorkShow)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests = testGroup "command line"
  [ testGroup "accepts" (map accepted acceptedForms)
  , testGroup "rejects" (map rejected rejectedForms)
  , testCase "work --show needs no spool directory" $
      parseWorkShow ["--config", "c.json", "--show"] @?= Right "c.json"
  ]

acceptedForms :: [([String], Command)]
acceptedForms =
  [ (["init"], Init)
  , (["put"], Put Nothing)
  , (["put", "--attachments", "files"], Put (Just "files"))
  , (["lease", "--worker", "w"], LeaseCommand "w" 1)
  , (["lease", "--worker", "w", "--count", "3"], LeaseCommand "w" 3)
  , (["lease", "--count", "3", "--worker", "w"], LeaseCommand "w" 3)
  , (["ack"], Ack)
  , (["renew"], Renew)
  , (["fail"], Fail True)
  , (["fail", "--no-retry"], Fail False)
  , (["failures"], Failures)
  , (["results"], Results)
  , (["fetch"], Fetch)
  , (["reclaim", "--older-than", "0"], Reclaim 0)
  , (["reclaim", "--older-than", "90"], Reclaim 90)
  , (["status"], Status False)
  , (["status", "--json"], Status True)
  , (["work", "--worker", "w", "--config", "c.json"], Work "w" "c.json" Nothing)
  , ( ["work", "--config", "c.json", "--worker", "w", "--max-tasks", "2"]
    , Work "w" "c.json" (Just 2) )
  , (["work", "--config", "c.json", "--show"], WorkShow "c.json")
  , ( ["grant", "--peer", "p", "--worker", "w", "--key", "k.pub"]
    , GrantCommand "p" "w" "k.pub" Nothing )
  , ( ["grant", "--peer", "p", "--worker", "w", "--key", "k.pub"
      , "--expires-at", "2026-10-01T00:00:00Z"]
    , GrantCommand "p" "w" "k.pub" (Just "2026-10-01T00:00:00Z") )
  , (["revoke", "--grant", "g"], RevokeCommand "g")
  ]

rejectedForms :: [(String, [String])]
rejectedForms =
  [ ("no subcommand", [])
  , ("unknown subcommand", ["destroy"])
  , ("extra word", ["init", "now"])
  , ("empty attachment directory", ["put", "--attachments", ""])
  , ("empty worker", ["lease", "--worker", ""])
  , ("worker with a space", ["lease", "--worker", "two words"])
  , ("worker with a newline", ["lease", "--worker", "one\ntwo"])
  , ("zero count", ["lease", "--worker", "w", "--count", "0"])
  , ("negative count", ["lease", "--worker", "w", "--count", "-1"])
  , ("fractional count", ["lease", "--worker", "w", "--count", "1.5"])
  , ("negative age", ["reclaim", "--older-than", "-1"])
  , ("missing age", ["reclaim"])
  , ("work without a worker", ["work", "--config", "c.json"])
  , ("work without a config", ["work", "--worker", "w"])
  , ("zero max-tasks", ["work", "--worker", "w", "--config", "c", "--max-tasks", "0"])
  , ("grant without a peer", ["grant", "--peer", "", "--worker", "w", "--key", "k"])
  ]

accepted :: ([String], Command) -> TestTree
accepted (words', expected) = testCase (unwords words') $
  parseCommand ("--dir" : "spool-dir" : words') @?= Right ("spool-dir", expected)

rejected :: (String, [String]) -> TestTree
rejected (label, words') = testCase label $
  assertBool "refused" (isLeft (parseCommand ("--dir" : "spool-dir" : words')))
