{-# LANGUAGE OverloadedStrings #-}

-- | The command line: each documented form names its command, and nothing
-- else does.
module Test.Cli (tests) where

import Data.Either (isLeft)
import Spool.Cli
  ( Command (..)
  , StoreCommand (..)
  , parseCommand
  , parseWorkShow
  , parseWorkVia
  )
import Spool.Types
  ( Retry (..)
  , StatusFormat (..)
  , WorkerName
  , mkWorkerName
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests = testGroup "command line"
  [ testGroup "accepts" (map accepted acceptedForms)
  , testGroup "rejects" (map rejected rejectedForms)
  , testCase "work --show needs no spool directory" $
      parseWorkShow ["--config", "c.json", "--show"] @?= Right "c.json"
  , testGroup "work --via"
      [ testCase "splits the transport command into a program and its arguments" $
          parseWorkVia ["--via", "ssh -i key spool@host", "--config", "c.json"]
            @?= Right (WorkVia ["ssh", "-i", "key", "spool@host"] "c.json" Nothing)
      , testCase "takes --max-tasks and its options in any order" $
          parseWorkVia ["--max-tasks", "3", "--config", "c.json", "--via", "fake-ssh"]
            @?= Right (WorkVia ["fake-ssh"] "c.json" (Just 3))
      , testCase "refuses an empty command" $
          assertBool "refused" (isLeft (parseWorkVia ["--via", "  ", "--config", "c.json"]))
      , testCase "refuses a missing config" $
          assertBool "refused" (isLeft (parseWorkVia ["--via", "ssh host"]))
      , testCase "refuses a worker name: the grant names the worker" $
          assertBool "refused" $ isLeft $
            parseWorkVia ["--via", "ssh host", "--config", "c.json", "--worker", "w"]
      ]
  ]

w :: WorkerName
w = either error id (mkWorkerName "w")

acceptedForms :: [([String], Command)]
acceptedForms =
  [ (["init"], Store Init)
  , (["put"], Store (Put Nothing))
  , (["put", "--attachments", "files"], Store (Put (Just "files")))
  , (["lease", "--worker", "w"], Store (LeaseCommand w 1))
  , (["lease", "--worker", "w", "--count", "3"], Store (LeaseCommand w 3))
  , (["lease", "--count", "3", "--worker", "w"], Store (LeaseCommand w 3))
  , (["ack"], Store Ack)
  , (["renew"], Store Renew)
  , (["fail"], Store (Fail Retry))
  , (["fail", "--no-retry"], Store (Fail NoRetry))
  , (["failures"], Store Failures)
  , (["results"], Store Results)
  , (["fetch"], Store Fetch)
  , (["reclaim", "--older-than", "0"], Store (Reclaim 0))
  , (["reclaim", "--older-than", "90"], Store (Reclaim 90))
  , (["status"], Store (Status StatusText))
  , (["status", "--json"], Store (Status StatusJson))
  , (["work", "--worker", "w", "--config", "c.json"], Work w "c.json" Nothing)
  , ( ["work", "--config", "c.json", "--worker", "w", "--max-tasks", "2"]
    , Work w "c.json" (Just 2) )
  , (["work", "--config", "c.json", "--show"], WorkShow "c.json")
  , ( ["grant", "--peer", "p", "--worker", "w", "--key", "k.pub"]
    , Store (GrantCommand "p" w "k.pub" False Nothing) )
  , ( ["grant", "--peer", "p", "--worker", "w", "--key", "k.pub"
      , "--expires-at", "2026-10-01T00:00:00Z"]
    , Store (GrantCommand "p" w "k.pub" False (Just "2026-10-01T00:00:00Z")) )
  , ( ["grant", "--peer", "p", "--worker", "w", "--key", "k.pub", "--put"]
    , Store (GrantCommand "p" w "k.pub" True Nothing) )
  , ( ["grant", "--peer", "p", "--worker", "w", "--key", "k.pub"
      , "--put", "--expires-at", "2026-10-01T00:00:00Z"]
    , Store (GrantCommand "p" w "k.pub" True (Just "2026-10-01T00:00:00Z")) )
  , ( ["grant", "--peer", "p", "--worker", "w", "--key", "k.pub"
      , "--expires-at", "2026-10-01T00:00:00Z", "--put"]
    , Store (GrantCommand "p" w "k.pub" True (Just "2026-10-01T00:00:00Z")) )
  , (["revoke", "--grant", "g"], Store (RevokeCommand "g"))
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
  , ("grant with --put twice", ["grant", "--peer", "p", "--worker", "w", "--key", "k", "--put", "--put"])
  , ("grant with an unknown option", ["grant", "--peer", "p", "--worker", "w", "--key", "k", "--pull"])
  ]

accepted :: ([String], Command) -> TestTree
accepted (words', expected) = testCase (unwords words') $
  parseCommand ("--dir" : "spool-dir" : words') @?= Right ("spool-dir", expected)

rejected :: (String, [String]) -> TestTree
rejected (label, words') = testCase label $
  assertBool "refused" (isLeft (parseCommand ("--dir" : "spool-dir" : words')))
