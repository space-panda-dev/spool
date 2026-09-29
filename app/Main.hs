-- | The executable is the library's entry point and nothing else.
module Main (main) where

import qualified Spool

main :: IO ()
main = Spool.main
