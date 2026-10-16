{-# LANGUAGE OverloadedStrings #-}

-- | A worker that follows its spool: when nothing is pending it waits and
-- asks again, instead of stopping. It waits 1 second, then 2, 4, and so on
-- up to its cap, so an idle worker asks at most once per cap; over a
-- transport, that is one process per wait. A request the transport could not
-- carry is said on stderr and asked again on the same schedule. A spool that
-- refuses the request is not asked again.
--
-- Nothing here starts a thread or holds a lock: the wait is the caller's,
-- and SIGTERM ends it as it ends anything else the worker is doing.
module Spool.Worker.Follow
  ( awaitLease
  , defaultIdleSeconds
  , nextWait
  ) where

import Control.Exception (throwIO, try)
import Spool.Error (ErrorClass (Retryable), SpoolError (SpoolError), withContext)
import Spool.Wire (Lease)

-- | The longest wait between two leases when none is given.
defaultIdleSeconds :: Int
defaultIdleSeconds = 30

-- | The wait after one of so many seconds: twice as long, up to the cap.
nextWait :: Int -> Int -> Int
nextWait capSeconds waited = min capSeconds (waited * 2)

-- | Lease one task, waiting for one to be put. Given how to wait so many
-- seconds, how to say a failure, the cap on a wait, and the lease request.
-- Each call starts again from the shortest wait, so the waits grow only
-- while the spool stays empty.
awaitLease
  :: (Int -> IO ()) -> (SpoolError -> IO ()) -> Int -> IO (Maybe Lease) -> IO Lease
awaitLease sleep say capSeconds leaseOne = go (min 1 capSeconds)
  where
    go waiting = do
      leased <- try leaseOne
      case leased of
        Right (Just lease) -> pure lease
        Right Nothing -> again waiting
        Left failure
          | transient failure -> do
              say (withContext
                ("work: lease failed, asking again in " <> show waiting <> " s: ") failure)
              again waiting
          | otherwise -> throwIO failure
    again waiting = sleep waiting >> go (nextWait capSeconds waiting)
    -- A transport that failed, or a spool that could not answer, may do
    -- better later. A grant refused, a malformed exchange, or corrupt state
    -- will not.
    transient (SpoolError Retryable _) = True
    transient _ = False
