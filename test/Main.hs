-- | Unit and property tests for the library.  The integration suite, test.sh,
-- drives the built binary; these reach what it cannot: raw bytes a shell
-- cannot carry, failures that must land at one exact moment, and the pure
-- grammars on inputs no fixture lists.
module Main (main) where

import qualified Test.Access
import qualified Test.Attachments
import qualified Test.Cli
import qualified Test.Error
import qualified Test.Files
import Test.Tasty (defaultMain, testGroup)
import qualified Test.Types
import qualified Test.Wire
import qualified Test.WorkerConfig

main :: IO ()
main = do
  attachments <- Test.Attachments.tests
  defaultMain $ testGroup "spool"
    [ Test.Access.tests
    , attachments
    , Test.Cli.tests
    , Test.Error.tests
    , Test.Files.tests
    , Test.Types.tests
    , Test.Wire.tests
    , Test.WorkerConfig.tests
    ]
