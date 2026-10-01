{-# LANGUAGE OverloadedStrings #-}

-- | The worker: runs leased tasks with the configured executables under
-- Spool's own declared limits: concurrency, timeout, payload size, and
-- captured output size. These bound what Spool itself does, not what the
-- executable can do to the machine it runs on -- there is no
-- CPU/memory/file-size containment or sandbox. A capability owner who needs
-- that wraps their executable (rlimits, a container, a VM) themselves.
--
-- Everything the worker starts, it holds in a scope that ends it: a task in
-- the worker's, a program and the threads that feed and read it in the
-- task's. However a scope is left, by finishing, by failing, or by the
-- worker being told to stop, what it started is stopped first.
module Spool.Worker.Run
  ( runWork
  ) where

import Control.Concurrent (myThreadId, threadDelay, throwTo)
import Control.Concurrent.Async
  ( Async
  , AsyncCancelled (..)
  , asyncWithUnmask
  , cancel
  , poll
  , wait
  , waitSTM
  , withAsync
  )
import Control.Concurrent.MVar (modifyMVar_, newMVar, readMVar)
import Control.Concurrent.QSem (newQSem, signalQSem, waitQSem)
import Control.Concurrent.STM
  ( STM
  , atomically
  , check
  , orElse
  , readTVar
  , registerDelay
  )
import Control.Exception
  ( IOException
  , SomeException
  , bracket
  , bracketOnError
  , catch
  , displayException
  , finally
  , fromException
  , mask_
  , throwIO
  , toException
  , try
  )
import Control.Monad (forM_, unless, void, when)
import qualified Data.Aeson as A
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import Data.Unique (hashUnique, newUnique)
import GHC.IO.Exception (IOErrorType (ResourceVanished))
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (Handle, hClose)
import System.IO.Error (ioeGetErrorType)
import System.Posix.Signals
  ( Handler (Catch)
  , Signal
  , installHandler
  , sigKILL
  , sigTERM
  , signalProcessGroup
  )
import System.Posix.Types (ProcessGroupID)
import System.Process
  ( CreateProcess (..)
  , ProcessHandle
  , StdStream (CreatePipe)
  , createProcess
  , getPid
  , getProcessExitCode
  , proc
  , waitForProcess
  )
import System.Timeout (timeout)
import qualified Spool.Attachments as SA
import Spool.Error
  ( SpoolError
  , corrupt
  , exitStatus
  , report
  , withContext
  )
import Spool.Files (epochMicros)
import Spool.Types
  ( LeaseId
  , Retry (..)
  , TaskId
  , capabilityText
  , taskIdText
  )
import Spool.Wire (Lease (..), LeaseRef (..), Task (..), canonical)
import Spool.Worker.Config
  ( CapabilityConfig (..)
  , WorkConfig (..)
  , loadWorkConfig
  )
import Spool.Worker.Connection (Connection (..))

-- | The outcome of running a capability's executable to completion.
data RunOutcome = RunSuccess BL.ByteString | RunFailure T.Text

-- | Lease tasks one at a time and run each in its own thread, as many at
-- once as the configuration allows, until nothing is pending or the count
-- asked for has been started. Then wait for what is running.
runWork :: Connection -> FilePath -> Maybe Int -> IO ()
runWork spool configPath maxTasks = do
  config <- loadWorkConfig configPath
  slots <- newQSem (wcMaxConcurrent config)
  failures <- newMVar ([] :: [SomeException])
  stoppedBySignal $ bracket (newIORef []) stopAll $ \running -> do
    let -- A task's failure is said when it happens, while the others run
        -- on. What is kept for the end is only its exit status, so the
        -- entry point does not say it a second time. A task that is being
        -- stopped has not failed.
        record exception = case fromException exception of
          Just AsyncCancelled -> throwIO exception
          Nothing -> do
            held <- case fromException exception of
              Just failure -> do
                report (failure :: SpoolError)
                pure (toException (ExitFailure (exitStatus failure)))
              Nothing -> pure exception
            modifyMVar_ failures (pure . (held :))
        start lease = mask_ $ do
          task <- asyncWithUnmask $ \unmask ->
            (unmask (runOneLease spool config lease) `catch` record)
              `finally` signalQSem slots
          atomicModifyIORef' running (\tasks -> (task : tasks, ()))
        loop launched = unless (maybe False (launched >=) maxTasks) $ do
          leased <- bracketOnError (waitQSem slots) (const (signalQSem slots)) $
            \() -> do
              leased <- leaseOne spool
              case leased of
                Just lease -> start lease >> pure True
                Nothing -> signalQSem slots >> pure False
          when leased (loop (launched + 1 :: Int))
    loop 0
    readIORef running >>= mapM_ wait
  failed <- readMVar failures
  case reverse failed of
    [] -> pure ()
    first : _ -> throwIO first
  where
    stopAll running = readIORef running >>= mapM_ cancel

-- | Run an action so that SIGTERM ends it as an exception does, through
-- every scope it is in, and not as the default does, on the spot and with
-- its programs left running. The status is the one a shell gives a process
-- that SIGTERM ended.
stoppedBySignal :: IO a -> IO a
stoppedBySignal action = do
  self <- myThreadId
  let stop = Catch (throwTo self (ExitFailure 143))
  bracket (installHandler sigTERM stop Nothing)
    (\previous -> installHandler sigTERM previous Nothing)
    (const action)

-- | Run one already-leased task to completion: refuse it outright if its
-- capability or payload size fails the configuration's rules, otherwise
-- run the mapped executable and ack or fail the lease with the result.
runOneLease :: Connection -> WorkConfig -> Lease -> IO ()
runOneLease spool config lease = do
  let task = leaseTask lease
      leaseIdent = leaseId lease
      capability = taskCapability task
  case Map.lookup capability (wcCapabilities config) of
    Nothing -> completeFailure spool (taskId task) leaseIdent
      ("capability " <> capabilityText capability
        <> " is not in the worker configuration") NoRetry
    Just capConfig -> do
      let payloadBytes = canonical (taskPayload task)
      if BL.length payloadBytes > capMaxPayloadBytes capConfig
        then completeFailure spool (taskId task) leaseIdent
          ("payload of " <> T.pack (show (BL.length payloadBytes))
            <> " bytes exceeds max_payload_bytes " <> T.pack (show (capMaxPayloadBytes capConfig)))
          NoRetry
        else runExecutable spool config task leaseIdent capConfig payloadBytes

runExecutable
  :: Connection -> WorkConfig -> Task -> LeaseId -> CapabilityConfig -> BL.ByteString -> IO ()
runExecutable spool config task leaseIdent capConfig payloadBytes = do
  (outcome, renewal) <-
    withAsync (renewalLoop spool (taskId task) leaseIdent (wcRenewSeconds config)) $
      \renewing -> do
        outcome <- bracket freshTempDir removeWorkerDirectory $ \tempDir -> do
          receiveTaskAttachments spool task leaseIdent tempDir
          runCapability capConfig (wcEnv config) tempDir payloadBytes
        renewal <- poll renewing
        pure (outcome, renewal)
  case renewal of
    Just (Right refusal) -> throwIO (withContext "work: renewal failed: " refusal)
    Just (Left exception) -> throwIO exception
    Nothing -> case outcome of
      RunFailure reason -> completeFailure spool (taskId task) leaseIdent reason Retry
      RunSuccess stdoutBytes -> case A.eitherDecode stdoutBytes of
        Left _ -> completeFailure spool (taskId task) leaseIdent "output is not JSON" Retry
        Right outputValue -> completeSuccess spool task leaseIdent outputValue

-- | Receive every declared attachment into the working directory, verified.
receiveTaskAttachments :: Connection -> Task -> LeaseId -> FilePath -> IO ()
receiveTaskAttachments spool task leaseIdent tempDir = do
  let workerAttachmentRoot = tempDir </> "attachments"
  forM_ (taskAttachments task) $ \attachment ->
    withAttachment spool (LeaseRef (taskId task) leaseIdent) attachment $ \handle -> do
      received <- SA.receiveAttachment workerAttachmentRoot attachment handle
      case received of
        Left message -> throwIO (corrupt
          ("attachment verification failed for "
            <> T.unpack (taskIdText (taskId task)) <> ": " <> message))
        Right () -> pure ()

removeWorkerDirectory :: FilePath -> IO ()
removeWorkerDirectory directory = do
  removed <- SA.attemptRemoveWorkerDirectory directory
  case removed of
    Left exception -> ioError exception
    Right () -> pure ()

-- | Renew the lease at each interval until a renewal is refused, and answer
-- with the refusal. It ends no other way but by being stopped.
renewalLoop :: Connection -> TaskId -> LeaseId -> Int -> IO SpoolError
renewalLoop spool taskIdent leaseIdent renewSeconds = do
  threadDelay (renewSeconds * 1000000)
  result <- renewLease spool (LeaseRef taskIdent leaseIdent)
  case result of
    Right () -> renewalLoop spool taskIdent leaseIdent renewSeconds
    Left refusal -> pure refusal

completeSuccess :: Connection -> Task -> LeaseId -> A.Value -> IO ()
completeSuccess spool task leaseIdent output = do
  result <- ackLease spool (LeaseRef (taskId task) leaseIdent) output
  case result of
    Left refusal -> throwIO (withContext "work: " refusal)
    Right () -> pure ()

completeFailure :: Connection -> TaskId -> LeaseId -> T.Text -> Retry -> IO ()
completeFailure spool taskIdent leaseIdent reason retry = do
  result <- failLeaseWith spool (LeaseRef taskIdent leaseIdent) reason retry
  case result of
    Left refusal -> throwIO (withContext "work: " refusal)
    Right () -> pure ()

freshTempDir :: IO FilePath
freshTempDir = do
  base <- getTemporaryDirectory
  micros <- epochMicros
  unique <- hashUnique <$> newUnique
  let path = base </> ("spool-work-" <> show micros <> "-" <> show unique)
  createDirectoryIfMissing True path
  pure path

-- | How long a run is given to end once it should have: after SIGTERM,
-- before SIGKILL; and after its program exits, for its output to close.
terminationGraceSeconds :: Int
terminationGraceSeconds = 5

-- | A program that has been started, and what is needed to end it.
data Started = Started
  { startedInput :: Handle
  , startedOutput :: Handle
  , startedErrors :: Handle
  , startedProcess :: ProcessHandle
  , startedGroup :: Maybe ProcessGroupID
    -- ^ The program leads its own group, so the group's identifier is the
    -- program's. It is taken at the start because it outlives the program:
    -- a process the program left behind is still in the group.
  }

startProgram :: CapabilityConfig -> [(String, String)] -> FilePath -> IO Started
startProgram capConfig envPairs cwdPath = do
  started <- createProcess (proc (capExec capConfig) (capArgs capConfig))
    { cwd = Just cwdPath
    , env = Just envPairs
    , std_in = CreatePipe
    , std_out = CreatePipe
    , std_err = CreatePipe
    , create_group = True
    }
  case started of
    (Just input, Just output, Just errors, process) -> do
      group <- getPid process
      pure (Started input output errors process group)
    (_, _, _, process) -> do
      -- Three pipes were asked for. Were one missing, the program would
      -- still have been started, and must not be left running.
      void (waitForProcess process)
      throwIO (userError "a program was started without its three pipes")

-- | End a program however its run was left. One still running, because the
-- run was stopped from outside, is asked to end and given the grace to do
-- it. Then whatever is in its group is killed, the worker's ends of its
-- pipes are closed, and it is reaped.
stopProgram :: Started -> IO ()
stopProgram started = do
  status <- getProcessExitCode (startedProcess started)
  when (status == Nothing) $ do
    signalGroup sigTERM started
    void (timeout (terminationGraceSeconds * 1000000)
      (waitForProcess (startedProcess started)))
  signalGroup sigKILL started
  forM_ [startedInput started, startedOutput started, startedErrors started] $
    \handle -> hClose handle `catch` ignored
  void (waitForProcess (startedProcess started))
  where
    ignored :: IOException -> IO ()
    ignored _ = pure ()

-- | Signal every process in the program's group, not just the one Spool
-- started. A group with nothing left in it cannot be signalled, which is
-- the one error ignored here.
signalGroup :: Signal -> Started -> IO ()
signalGroup signal started = forM_ (startedGroup started) $ \group ->
  signalProcessGroup signal group `catch` gone
  where
    gone :: IOException -> IO ()
    gone _ = pure ()

-- | Why a run was stopped before its program exited.
data Stopped = TimedOut | Overran

-- | How a run ended.
data Ended
  = Exited ExitCode Captured Captured (Either IOException ())
    -- ^ The program exited and its output closed: its status, what it wrote
    -- to stdout and to stderr, and whether its payload could be written.
  | StoppedFor Stopped
  | LeftOpen
    -- ^ The program exited and its output did not close: it left a process
    -- behind.

-- | What was read from a stream, or that it went past the limit.
data Captured = Captured BS.ByteString | PastLimit

-- | Run one capability executable with the given environment, cwd, and
-- stdin payload. It runs in its own process group, and is stopped if it
-- outlives `capTimeoutSeconds` or if either stream of its output goes past
-- `capMaxOutputBytes`. Stopping it is SIGTERM to the group, then SIGKILL to
-- whatever of the group is still running `terminationGraceSeconds` later.
--
-- The payload is written while the output is read and the clock runs, so a
-- program that reads nothing cannot hold the run past its timeout. A program
-- may close its input or exit without reading all of its payload; that is
-- its choice and not a failure, and its status and output say how it did.
runCapability :: CapabilityConfig -> [(String, String)] -> FilePath -> BL.ByteString -> IO RunOutcome
runCapability capConfig envPairs cwdPath payload =
  bracket (startProgram capConfig envPairs cwdPath) stopProgram $ \started ->
    withAsync (try (feed (startedInput started))) $ \feeding ->
    withAsync (readCapped limit (startedOutput started)) $ \readingOutput ->
    withAsync (readCapped limit (startedErrors started)) $ \readingErrors ->
    withAsync (waitForProcess (startedProcess started)) $ \exiting -> do
      deadline <- registerDelay (capTimeoutSeconds capConfig * 1000000)
      let -- The program has exited and nothing holds its pipes.
          settled = do
            status <- waitSTM exiting
            output <- waitSTM readingOutput
            errors <- waitSTM readingErrors
            fed <- waitSTM feeding
            pure (status, output, errors, fed)
          pastLimit = do
            output <- pollCaptured readingOutput
            errors <- pollCaptured readingErrors
            check (any isPastLimit [output, errors])
          stopFor reason = do
            signalGroup sigTERM started
            ended <- within terminationGraceSeconds settled
            unless (isJust ended) $ do
              signalGroup sigKILL started
              void (within terminationGraceSeconds settled)
            pure (StoppedFor reason)
      first <- atomically $
        (Left TimedOut <$ (readTVar deadline >>= check))
          `orElse` (Left Overran <$ pastLimit)
          `orElse` (Right <$> waitSTM exiting)
      ended <- case first of
        Left reason -> stopFor reason
        Right _ -> do
          closed <- within terminationGraceSeconds settled
          case closed of
            Just (status, output, errors, fed) -> pure (Exited status output errors fed)
            Nothing -> do
              signalGroup sigKILL started
              void (within terminationGraceSeconds settled)
              pure LeftOpen
      pure (outcomeOf ended)
  where
    limit = capMaxOutputBytes capConfig
    feed input = (BL.hPut input payload >> hClose input) `catch` closedByProgram input
    closedByProgram input exception
      | ioeGetErrorType exception == ResourceVanished =
          hClose input `catch` (\again -> const (pure ()) (again :: IOException))
      | otherwise = throwIO exception
    outcomeOf ended = case ended of
      Exited _ _ _ (Left exception) -> RunFailure
        ("could not write payload: " <> T.pack (displayException exception))
      StoppedFor TimedOut -> timedOut
      StoppedFor Overran -> overran
      Exited _ output errors _ | any isPastLimit [Just output, Just errors] -> overran
      LeftOpen -> RunFailure
        ("output still open " <> T.pack (show terminationGraceSeconds)
          <> " s after exit: the program left a process running")
      Exited ExitSuccess (Captured output) _ _ -> RunSuccess (BL.fromStrict output)
      Exited (ExitFailure n) _ (Captured errors) _ -> RunFailure
        ("exit " <> T.pack (show n) <> ": " <> decodeLenient (tailBytes 1000 errors))
      -- Every stream past its limit was answered above.
      Exited _ _ _ _ -> overran
    timedOut = RunFailure
      ("timeout after " <> T.pack (show (capTimeoutSeconds capConfig)) <> " s")
    overran = RunFailure
      ("output exceeds max_output_bytes " <> T.pack (show limit))

isPastLimit :: Maybe Captured -> Bool
isPastLimit (Just PastLimit) = True
isPastLimit _ = False

-- | What a reader has captured, if it has finished.
pollCaptured :: Async Captured -> STM (Maybe Captured)
pollCaptured thread = (Just <$> waitSTM thread) `orElse` pure Nothing

-- | Wait for something for so many seconds, and no longer.
within :: Int -> STM a -> IO (Maybe a)
within seconds awaited = do
  expired <- registerDelay (seconds * 1000000)
  atomically $
    (Just <$> awaited) `orElse` (Nothing <$ (readTVar expired >>= check))

-- | Read a handle to its end in chunks, stopping the moment the total goes
-- past `limit`, so a capability that writes without bound cannot grow the
-- worker's memory without bound either.
readCapped :: Int64 -> Handle -> IO Captured
readCapped limit handle = go [] 0
  where
    chunkSize = 65536
    go chunks total = do
      chunk <- BS.hGetSome handle chunkSize
      if BS.null chunk
        then pure (Captured (BS.concat (reverse chunks)))
        else do
          let total' = total + fromIntegral (BS.length chunk)
          if total' > limit
            then pure PastLimit
            else go (chunk : chunks) total'

tailBytes :: Int -> BS.ByteString -> BS.ByteString
tailBytes n bytes = BS.drop (max 0 (BS.length bytes - n)) bytes

decodeLenient :: BS.ByteString -> T.Text
decodeLenient = TE.decodeUtf8With TEE.lenientDecode
