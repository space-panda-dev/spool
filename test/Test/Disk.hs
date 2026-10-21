-- | The floor a fetch must leave on the worker's disk (ADR 0025): reading
-- what @df -P -k@ says, and when a fetch may begin.
module Test.Disk (tests) where

import Data.Either (isLeft)
import Spool.Worker.Disk (mayFetch, parseDfOutput)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests = testGroup "disk floor"
  [ testCase "the available blocks of Linux's df are read in bytes" $
      parseDfOutput (unlines
        [ "Filesystem     1024-blocks      Used Available Capacity Mounted on"
        , "/dev/nvme1n1p1   976284600 613281132 363003468      63% /home" ])
        @?= Right (363003468 * 1024)
  , testCase "and macOS's, whose device name has no spaces either" $
      parseDfOutput (unlines
        [ "Filesystem   1024-blocks      Used Available Capacity  Mounted on"
        , "/dev/disk3s5   239362496 189779200   4089408    98%    /System/Volumes/Data" ])
        @?= Right (4089408 * 1024)
  , testCase "output with no file system is refused" $
      assertBool "refused" (isLeft (parseDfOutput "Filesystem 1024-blocks Used Available\n"))
  , testCase "an available size that is not a count is refused" $
      assertBool "refused" (isLeft (parseDfOutput "h\n/dev/x 1 2 lots 3% /\n"))
  , testCase "with no floor a fetch always begins" $
      mayFetch Nothing 3 0 (10 ^ (12 :: Int)) @?= True
  , testCase "with nothing else held a fetch begins whatever the disk holds" $
      mayFetch (Just 100) 0 0 50 @?= True
  , testCase "beside another task, a fetch must leave the floor free" $
      (mayFetch (Just 100) 1 150 50, mayFetch (Just 100) 1 149 50) @?= (True, False)
  ]
