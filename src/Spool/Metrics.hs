{-# LANGUAGE OverloadedStrings #-}

-- | A host's spools as Prometheus text exposition (ADR 0028). This module is
-- pure: what one spool holds, read by 'Spool.Store.readMetrics', becomes a
-- 'Reading', and the readings of every spool asked for become one text.
-- Nothing here is part of the protocol; docs/metrics.md is the contract.
module Spool.Metrics
  ( Reading (..)
  , TaskState (..)
  , emptyReading
  , reasonClass
  , recent
  , ageSeconds
  , spoolLabels
  , render
  ) where

import Data.Char (isDigit)
import Data.List (nub)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import System.FilePath (dropTrailingPathSeparator, takeFileName)

-- | A task's state, as the four are counted: a partition of tasks, where
-- 'Failed' is a task failed for good and not yet collected (ADR 0028).
data TaskState = Pending | Leased | Done | Failed
  deriving (Bounded, Enum, Eq, Ord, Show)

stateText :: TaskState -> T.Text
stateText state = case state of
  Pending -> "pending"
  Leased -> "leased"
  Done -> "done"
  Failed -> "failed"

-- | What one spool holds, as the series are made from it.
data Reading = Reading
  { readingSpool :: T.Text
  , readingWindow :: Integer
  , readingTasks :: [(TaskState, T.Text)]
    -- ^ One for each task: its state and its capability.
  , readingLeases :: [T.Text]
    -- ^ One for each lease: its worker, or empty for one never handed out.
  , readingOldestPending :: Integer
  , readingOldestRenewal :: Integer
  , readingResults :: [(T.Text, T.Text)]
    -- ^ One for each result within the window: its capability and worker.
  , readingFailures :: [(T.Text, T.Text, T.Text, Bool)]
    -- ^ One for each failure record within the window: its capability,
    -- worker, reason, and whether it was retried.
  } deriving (Eq, Show)

-- | A spool that holds nothing, read over this window.
emptyReading :: T.Text -> Integer -> Reading
emptyReading spool window = Reading spool window [] [] 0 0 [] []

-- | The class of a failure's reason, from its start: the spool's own
-- reclaim and revoke, the reference worker's reasons, and @other@.
reasonClass :: T.Text -> T.Text
reasonClass reason
  | "reclaimed: not renewed within" `T.isPrefixOf` reason = "reclaimed"
  | "reclaimed: grant revoked" `T.isPrefixOf` reason = "revoked"
  | Just rest <- T.stripPrefix "exit " reason
  , Just (digit, _) <- T.uncons rest
  , isDigit digit = "exit"
  | "timeout after " `T.isPrefixOf` reason = "timeout"
  | "output exceeds max_output_bytes" `T.isPrefixOf` reason = "output_limit"
  | "output is not JSON" `T.isPrefixOf` reason = "output_not_json"
  | "output still open" `T.isPrefixOf` reason = "left_running"
  | otherwise = "other"

-- | What happened within the last @window@ seconds before @now@, edge
-- included; a time ahead of @now@, from another clock, counts. Times are
-- whole seconds since the epoch.
recent :: Integer -> Integer -> [(Integer, a)] -> [a]
recent now window entries = [value | (at, value) <- entries, now - at <= window]

-- | Seconds from @at@ to @now@, never below 0.
ageSeconds :: Integer -> Integer -> Integer
ageSeconds now at = max 0 (now - at)

-- | The label of each spool: its directory's base name. Two of one name,
-- or a directory with none, would make series that cannot be told apart.
spoolLabels :: [FilePath] -> Either String [T.Text]
spoolLabels directories = do
  names <- mapM label directories
  if length (nub names) == length names
    then Right (map T.pack names)
    else Left "spool: metrics: two spool directories have one base name"
  where
    label directory = case takeFileName (dropTrailingPathSeparator directory) of
      name | name `notElem` ["", ".", ".."] -> Right name
      _ -> Left ("spool: metrics: " <> directory <> " has no base name to label it by")

-- | One series family: its name, help, and the series of every reading.
data Family = Family T.Text T.Text (Reading -> [([(T.Text, T.Text)], Integer)])

families :: [Family]
families =
  [ Family "spool_tasks"
      "Tasks in each state; failed is failed for good and not yet collected."
      (\r -> [ ([("state", stateText s)], count s (map fst (readingTasks r)))
             | s <- [minBound .. maxBound] ])
  , Family "spool_capability_tasks" "Tasks in each state, by capability."
      (\r -> [ ([("state", stateText s), ("capability", c)], n)
             | ((s, c), n) <- tally (readingTasks r) ])
  , Family "spool_leases" "Leased tasks, by the worker holding each."
      (\r -> [ ([("actor", w)], n) | (w, n) <- tally (readingLeases r) ])
  , Family "spool_oldest_pending_age_seconds"
      "Seconds since the longest-waiting pending task became pending; 0 with none."
      (\r -> [([], readingOldestPending r)])
  , Family "spool_oldest_lease_renewal_age_seconds"
      "Seconds since the stalest lease was taken or renewed; 0 with none."
      (\r -> [([], readingOldestRenewal r)])
  , Family "spool_recent_window_seconds"
      "The window spool_recent_results and spool_recent_failures count over."
      (\r -> [([], readingWindow r)])
  , Family "spool_recent_results" "Results finished within the window."
      (\r -> [ ([("capability", c), ("actor", w)], n)
             | ((c, w), n) <- tally (readingResults r) ])
  , Family "spool_recent_failures" "Failure records within the window, by reason class."
      (\r -> [ ([("capability", c), ("actor", w), ("reason", k), ("retried", flag t)], n)
             | ((c, w, k, t), n) <- tally
                 [ (c', w', reasonClass reason, t') | (c', w', reason, t') <- readingFailures r ] ])
  ]
  where
    count s = toInteger . length . filter (== s)
    flag t = if t then "true" else "false"

-- | How many of each, in order.
tally :: Ord a => [a] -> [(a, Integer)]
tally xs = Map.toAscList (Map.fromListWith (+) [(x, 1) | x <- xs])

-- | The exposition of these readings: each family described once, then its
-- series for every spool, in the order the spools were given.
render :: [Reading] -> T.Text
render readings = T.unlines (concatMap family families)
  where
    family (Family name help series) =
      ("# HELP " <> name <> " " <> help)
        : ("# TYPE " <> name <> " gauge")
        : [ line name (("spool", readingSpool r) : labels) value
          | r <- readings, (labels, value) <- series r ]
    line name labels value =
      name <> "{" <> T.intercalate "," [k <> "=\"" <> escape v <> "\"" | (k, v) <- labels]
        <> "} " <> T.pack (show value)

-- | A label value as the text format writes it.
escape :: T.Text -> T.Text
escape = T.concatMap $ \c -> case c of
  '\\' -> "\\\\"
  '"' -> "\\\""
  '\n' -> "\\n"
  _ -> T.singleton c
