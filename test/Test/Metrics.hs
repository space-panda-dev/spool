{-# LANGUAGE OverloadedStrings #-}

-- | What @spool metrics@ writes (ADR 0028): reason classes, the window,
-- the spool label, and the exposition text a textfile reader takes.
module Test.Metrics (tests) where

import Data.Either (isLeft)
import qualified Data.Text as T
import Spool.Metrics
  ( Reading (..)
  , TaskState (..)
  , ageSeconds
  , emptyReading
  , reasonClass
  , recent
  , render
  , spoolLabels
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests = testGroup "metrics (ADR 0028)"
  [ reasonTests, windowTests, labelTests, renderTests ]

reasonTests :: TestTree
reasonTests = testGroup "reason classes"
  [ testCase "the spool's own reclaim and revoke" $ do
      reasonClass "reclaimed: not renewed within 600 s" @?= "reclaimed"
      reasonClass "reclaimed: grant revoked" @?= "revoked"
  , testCase "the reference worker's reasons" $ do
      reasonClass "exit 3: boom" @?= "exit"
      reasonClass "exit 65: hopeless" @?= "exit"
      reasonClass "timeout after 30 s" @?= "timeout"
      reasonClass "output exceeds max_output_bytes 4096" @?= "output_limit"
      reasonClass "output is not JSON" @?= "output_not_json"
      reasonClass "output still open 5 s after exit: the program left a process running"
        @?= "left_running"
  , testCase "the cap's suffix does not change the class" $
      reasonClass "exit 3: boom; retries exhausted after 3 attempts" @?= "exit"
  , testCase "anything else is other, however close" $ do
      reasonClass "" @?= "other"
      reasonClass "exited badly" @?= "other"
      reasonClass "exit: no status" @?= "other"
      reasonClass "kept" @?= "other"
      reasonClass "Reclaimed: grant revoked" @?= "other"
  ]

windowTests :: TestTree
windowTests = testGroup "the window"
  [ testCase "counts what is within the window, its edge included" $
      recent now 60 [(ago 0, 'a'), (ago 60, 'b'), (ago 61, 'c'), (ago 3600, 'd')]
        @?= "ab"
  , testCase "counts a record from a clock ahead of this one" $
      recent now 60 [(now + 5, 'a')] @?= "a"
  , testCase "an age is never below 0" $ do
      ageSeconds now (ago 90) @?= 90
      ageSeconds now (now + 10) @?= 0
  ]

labelTests :: TestTree
labelTests = testGroup "the spool label"
  [ testCase "is the directory's base name" $
      spoolLabels ["/var/lib/spool/spools/stems", "relative/mix/"] @?= Right ["stems", "mix"]
  , testCase "two directories with one base name are refused" $
      assertBool "refused" (isLeft (spoolLabels ["/a/stems", "/b/stems"]))
  , testCase "a directory with no base name is refused" $ do
      assertBool "root" (isLeft (spoolLabels ["/"]))
      assertBool "dot" (isLeft (spoolLabels ["."]))
      assertBool "dot dot" (isLeft (spoolLabels ["a/.."]))
  ]

renderTests :: TestTree
renderTests = testGroup "the exposition"
  [ testCase "an empty spool writes every state and zeros, and nothing by capability" $
      render [emptyReading "idle" 3600] @?= T.unlines
        [ "# HELP spool_tasks Tasks in each state; failed is failed for good and not yet collected."
        , "# TYPE spool_tasks gauge"
        , "spool_tasks{spool=\"idle\",state=\"pending\"} 0"
        , "spool_tasks{spool=\"idle\",state=\"leased\"} 0"
        , "spool_tasks{spool=\"idle\",state=\"done\"} 0"
        , "spool_tasks{spool=\"idle\",state=\"failed\"} 0"
        , "# HELP spool_capability_tasks Tasks in each state, by capability."
        , "# TYPE spool_capability_tasks gauge"
        , "# HELP spool_leases Leased tasks, by the worker holding each."
        , "# TYPE spool_leases gauge"
        , "# HELP spool_oldest_pending_age_seconds Seconds since the longest-waiting pending task became pending; 0 with none."
        , "# TYPE spool_oldest_pending_age_seconds gauge"
        , "spool_oldest_pending_age_seconds{spool=\"idle\"} 0"
        , "# HELP spool_oldest_lease_renewal_age_seconds Seconds since the stalest lease was taken or renewed; 0 with none."
        , "# TYPE spool_oldest_lease_renewal_age_seconds gauge"
        , "spool_oldest_lease_renewal_age_seconds{spool=\"idle\"} 0"
        , "# HELP spool_recent_window_seconds The window spool_recent_results and spool_recent_failures count over."
        , "# TYPE spool_recent_window_seconds gauge"
        , "spool_recent_window_seconds{spool=\"idle\"} 3600"
        , "# HELP spool_recent_results Results finished within the window."
        , "# TYPE spool_recent_results gauge"
        , "# HELP spool_recent_failures Failure records within the window, by reason class."
        , "# TYPE spool_recent_failures gauge"
        ]
  , testCase "counts group by their labels, in a fixed order" $ do
      let reading = (emptyReading "stems" 60)
            { readingTasks =
                [ (Pending, "split@1"), (Pending, "split@1"), (Pending, "age@2")
                , (Leased, "split@1"), (Failed, "age@2") ]
            , readingLeases = ["mac", "mac", ""]
            , readingOldestPending = 42
            , readingOldestRenewal = 7
            , readingResults = [("split@1", "mac"), ("split@1", "mac"), ("age@2", "laptop")]
            , readingFailures =
                [ ("split@1", "mac", "exit 3: boom", True)
                , ("split@1", "mac", "exit 4: bang", True)
                , ("split@1", "mac", "reclaimed: not renewed within 60 s; retries exhausted after 3 attempts", False)
                ]
            }
          series = filter (not . T.isPrefixOf "#") (T.lines (render [reading]))
      series @?=
        [ "spool_tasks{spool=\"stems\",state=\"pending\"} 3"
        , "spool_tasks{spool=\"stems\",state=\"leased\"} 1"
        , "spool_tasks{spool=\"stems\",state=\"done\"} 0"
        , "spool_tasks{spool=\"stems\",state=\"failed\"} 1"
        , "spool_capability_tasks{spool=\"stems\",state=\"pending\",capability=\"age@2\"} 1"
        , "spool_capability_tasks{spool=\"stems\",state=\"pending\",capability=\"split@1\"} 2"
        , "spool_capability_tasks{spool=\"stems\",state=\"leased\",capability=\"split@1\"} 1"
        , "spool_capability_tasks{spool=\"stems\",state=\"failed\",capability=\"age@2\"} 1"
        , "spool_leases{spool=\"stems\",worker=\"\"} 1"
        , "spool_leases{spool=\"stems\",worker=\"mac\"} 2"
        , "spool_oldest_pending_age_seconds{spool=\"stems\"} 42"
        , "spool_oldest_lease_renewal_age_seconds{spool=\"stems\"} 7"
        , "spool_recent_window_seconds{spool=\"stems\"} 60"
        , "spool_recent_results{spool=\"stems\",capability=\"age@2\",worker=\"laptop\"} 1"
        , "spool_recent_results{spool=\"stems\",capability=\"split@1\",worker=\"mac\"} 2"
        , "spool_recent_failures{spool=\"stems\",capability=\"split@1\",worker=\"mac\",reason=\"exit\",retried=\"true\"} 2"
        , "spool_recent_failures{spool=\"stems\",capability=\"split@1\",worker=\"mac\",reason=\"reclaimed\",retried=\"false\"} 1"
        ]
  , testCase "two spools share one HELP and TYPE for each series" $ do
      let text = render [emptyReading "a" 60, emptyReading "b" 60]
          helps = filter (T.isPrefixOf "# HELP spool_tasks ") (T.lines text)
          types = filter (T.isPrefixOf "# TYPE ") (T.lines text)
      length helps @?= 1
      length types @?= 8
      assertBool "both spools" (all (`T.isInfixOf` text)
        ["spool_tasks{spool=\"a\",state=\"failed\"} 0", "spool_tasks{spool=\"b\",state=\"failed\"} 0"])
  , testCase "a label value is escaped" $
      assertBool "escaped" ("spool_recent_window_seconds{spool=\"a\\\"b\\\\c\\nd\"} 60"
        `T.isInfixOf` render [emptyReading "a\"b\\c\nd" 60])
  ]

-- | Times are whole seconds since the epoch.
now :: Integer
now = 1800000000

ago :: Integer -> Integer
ago seconds = now - seconds
