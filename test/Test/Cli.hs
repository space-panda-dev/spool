{-# LANGUAGE OverloadedStrings #-}

-- | The command line: each documented form names its command, and nothing
-- else does.
module Test.Cli (tests) where

import Data.Either (isLeft)
import Spool.Cli
  ( Command (..)
  , GrantOptions (..)
  , StoreCommand (..)
  , Transfer (..)
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
            @?= Right (WorkVia ["ssh", "-i", "key", "spool@host"] "c.json" Nothing Nothing)
      , testCase "takes --max-tasks and its options in any order" $
          parseWorkVia ["--max-tasks", "3", "--config", "c.json", "--via", "fake-ssh"]
            @?= Right (WorkVia ["fake-ssh"] "c.json" (Just 3) Nothing)
      , testCase "refuses an empty command" $
          assertBool "refused" (isLeft (parseWorkVia ["--via", "  ", "--config", "c.json"]))
      , testCase "refuses a missing config" $
          assertBool "refused" (isLeft (parseWorkVia ["--via", "ssh host"]))
      , testCase "refuses a worker name: the grant names the worker" $
          assertBool "refused" $ isLeft $
            parseWorkVia ["--via", "ssh host", "--config", "c.json", "--worker", "w"]
      , testCase "follows, waiting up to 30 s unless told otherwise" $
          parseWorkVia ["--via", "fake-ssh", "--follow", "--config", "c.json"]
            @?= Right (WorkVia ["fake-ssh"] "c.json" Nothing (Just 30))
      , testCase "follows with the longest wait it is given" $
          parseWorkVia ["--idle-seconds", "5", "--via", "fake-ssh", "--config", "c.json", "--follow"]
            @?= Right (WorkVia ["fake-ssh"] "c.json" Nothing (Just 5))
      , testCase "refuses --idle-seconds without --follow" $
          assertBool "refused" $ isLeft $
            parseWorkVia ["--via", "fake-ssh", "--config", "c.json", "--idle-seconds", "5"]
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
  , (["fetch"], Moving Fetch)
  , (["send"], Moving Send)
  , (["take"], Moving Take)
  , (["reclaim", "--older-than", "0"], Store (Reclaim 0))
  , (["reclaim", "--older-than", "90"], Store (Reclaim 90))
  , (["collect"], Store Collect)
  , (["withdraw"], Store Withdraw)
  , (["gc", "--older-than", "0"], Store (Gc 0))
  , (["gc", "--older-than", "86400"], Store (Gc 86400))
  , (["status"], Store (Status StatusText))
  , (["status", "--json"], Store (Status StatusJson))
  , (["status", "--json", "--tasks"], Store (Status StatusTasks))
  , (["status", "--tasks", "--json"], Store (Status StatusTasks))
  , (["work", "--worker", "w", "--config", "c.json"], Work w "c.json" Nothing Nothing)
  , ( ["work", "--config", "c.json", "--worker", "w", "--max-tasks", "2"]
    , Work w "c.json" (Just 2) Nothing )
  , (["work", "--worker", "w", "--config", "c.json", "--follow"], Work w "c.json" Nothing (Just 30))
  , ( ["work", "--follow", "--idle-seconds", "7", "--worker", "w", "--config", "c.json"]
    , Work w "c.json" Nothing (Just 7) )
  , ( ["work", "--worker", "w", "--config", "--follow"]
    , Work w "--follow" Nothing Nothing )
  , ( ["work", "--worker", "w", "--config", "c.json", "--follow", "--idle-seconds", "9223372036854"]
    , Work w "c.json" Nothing (Just 9223372036854) )
  , (["work", "--config", "c.json", "--show"], WorkShow "c.json")
  , ( ["grant", "--peer", "p", "--worker", "w", "--key", "k.pub"]
    , Store (GrantCommand "p" w "k.pub" (GrantOptions False Nothing Nothing 0)) )
  , ( ["grant", "--peer", "p", "--worker", "w", "--key", "k.pub"
      , "--expires-at", "2026-10-01T00:00:00Z"]
    , Store (GrantCommand "p" w "k.pub" (GrantOptions False (Just "2026-10-01T00:00:00Z") Nothing 0)) )
  , ( ["grant", "--peer", "p", "--worker", "w", "--key", "k.pub", "--put"]
    , Store (GrantCommand "p" w "k.pub" (GrantOptions True Nothing Nothing 0)) )
  , ( ["grant", "--peer", "p", "--worker", "w", "--key", "k.pub"
      , "--put", "--expires-at", "2026-10-01T00:00:00Z"]
    , Store (GrantCommand "p" w "k.pub" (GrantOptions True (Just "2026-10-01T00:00:00Z") Nothing 0)) )
  , ( ["grant", "--peer", "p", "--worker", "w", "--key", "k.pub"
      , "--expires-at", "2026-10-01T00:00:00Z", "--put"]
    , Store (GrantCommand "p" w "k.pub" (GrantOptions True (Just "2026-10-01T00:00:00Z") Nothing 0)) )
  , ( ["grant", "--peer", "p", "--worker", "w", "--key", "k.pub"
      , "--executable", "/usr/local/bin/spool", "--put"]
    , Store (GrantCommand "p" w "k.pub" (GrantOptions True Nothing (Just "/usr/local/bin/spool") 0)) )
  , ( ["grant", "--peer", "p", "--worker", "w", "--key", "k.pub", "--max-result-bytes", "1"]
    , Store (GrantCommand "p" w "k.pub" (GrantOptions False Nothing Nothing 1)) )
  , ( ["grant", "--peer", "p", "--worker", "w", "--key", "k.pub"
      , "--max-result-bytes", "9223372036854775807", "--put"]
    , Store (GrantCommand "p" w "k.pub" (GrantOptions True Nothing Nothing 9223372036854775807)) )
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
  , ("collect with a word", ["collect", "all"])
  , ("withdraw with a word", ["withdraw", "all"])
  , ("tasks without json", ["status", "--tasks"])
  , ("gc without an age", ["gc"])
  , ("gc with a negative age", ["gc", "--older-than", "-1"])
  , ("gc with a fractional age", ["gc", "--older-than", "1.5"])
  , ("work without a worker", ["work", "--config", "c.json"])
  , ("work without a config", ["work", "--worker", "w"])
  , ("zero max-tasks", ["work", "--worker", "w", "--config", "c", "--max-tasks", "0"])
  , ("idle seconds without --follow", ["work", "--worker", "w", "--config", "c", "--idle-seconds", "5"])
  , ("zero idle seconds", ["work", "--worker", "w", "--config", "c", "--follow", "--idle-seconds", "0"])
  , ("idle seconds past the largest wait", ["work", "--worker", "w", "--config", "c", "--follow", "--idle-seconds", "9223372036855"])
  , ("idle seconds that would wrap", ["work", "--worker", "w", "--config", "c", "--follow", "--idle-seconds", "18446744073709551617"])
  , ("--follow twice", ["work", "--worker", "w", "--config", "c", "--follow", "--follow"])
  , ("grant without a peer", ["grant", "--peer", "", "--worker", "w", "--key", "k"])
  , ("grant with --put twice", ["grant", "--peer", "p", "--worker", "w", "--key", "k", "--put", "--put"])
  , ("grant with --executable twice", ["grant", "--peer", "p", "--worker", "w", "--key", "k", "--executable", "/a", "--executable", "/b"])
  , ("grant with an empty executable", ["grant", "--peer", "p", "--worker", "w", "--key", "k", "--executable", ""])
  , ("send with a word", ["send", "file"])
  , ("take with a word", ["take", "file"])
  , ("grant with no result bytes", ["grant", "--peer", "p", "--worker", "w", "--key", "k", "--max-result-bytes", "0"])
  , ("grant with negative result bytes", ["grant", "--peer", "p", "--worker", "w", "--key", "k", "--max-result-bytes", "-1"])
  , ("grant with result bytes that would wrap", ["grant", "--peer", "p", "--worker", "w", "--key", "k", "--max-result-bytes", "9223372036854775808"])
  , ("grant with result bytes twice", ["grant", "--peer", "p", "--worker", "w", "--key", "k", "--max-result-bytes", "1", "--max-result-bytes", "2"])
  , ("grant with an unknown option", ["grant", "--peer", "p", "--worker", "w", "--key", "k", "--pull"])
  ]

accepted :: ([String], Command) -> TestTree
accepted (words', expected) = testCase (unwords words') $
  parseCommand ("--dir" : "spool-dir" : words') @?= Right ("spool-dir", expected)

rejected :: (String, [String]) -> TestTree
rejected (label, words') = testCase label $
  assertBool "refused" (isLeft (parseCommand ("--dir" : "spool-dir" : words')))
