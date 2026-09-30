{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The worker: runs leased tasks with the configured executables under
-- Spool's own declared limits: concurrency, timeout, payload size, and
-- captured output size. These bound what Spool itself does, not what the
-- executable can do to the machine it runs on -- there is no
-- CPU/memory/file-size containment or sandbox. A capability owner who needs
-- that wraps their executable (rlimits, a container, a VM) themselves.
module Spool.Worker.Run
  ( runWork
  ) where

import Control.Concurrent (forkFinally, forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, newMVar, putMVar,
                                readMVar, modifyMVar_, takeMVar, tryPutMVar,
                                tryReadMVar)
import Control.Concurrent.QSem (newQSem, signalQSem, waitQSem)
import Control.Exception (IOException, SomeException, bracket, catch,
                          displayException, finally, fromException, throwIO,
                          toException, try)
import Control.Monad (forM_, void)
import qualified Data.Aeson as A
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import Data.Unique (hashUnique, newUnique)
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (Handle, IOMode (ReadMode), hClose, openBinaryFile)
import System.Posix.Signals (Signal, sigKILL, sigTERM, signalProcess)
import System.Process (CreateProcess (..), ProcessHandle, StdStream (CreatePipe),
                       createProcess, getPid, proc, waitForProcess)
import qualified Spool.Attachments as SA
import Spool.Error
  ( SpoolError
  , corrupt
  , exitStatus
  , report
  , withContext
  )
import Spool.Files (Paths (..), withLock, epochMicros)
import Spool.Store (leaseUpTo, ackOne, renewOne, failLease)
import Spool.Types
  ( LeaseId
  , Retry (..)
  , TaskId
  , WorkerName
  , capabilityText
  , taskIdText
  )
import Spool.Wire (Lease (..), LeaseRef (..), Task (..), canonical)
import Spool.Worker.Config
  ( CapabilityConfig (..)
  , WorkConfig (..)
  , loadWorkConfig
  )

-- | The outcome of running a capability's executable to completion.
data RunOutcome = RunSuccess BL.ByteString | RunFailure T.Text

ignoreProcessRace :: IO () -> IO ()
ignoreProcessRace action = action `catch` ignore
  where
    ignore :: IOException -> IO ()
    ignore _ = pure ()

runWork :: Paths -> WorkerName -> FilePath -> Maybe Int -> IO ()
runWork paths worker configPath maxTasks = do
  config <- loadWorkConfig configPath
  slots <- newQSem (wcMaxConcurrent config)
  completions <- newQSem 0
  workerFailures <- newMVar ([] :: [SomeException])
  launchedRef <- newIORef (0 :: Int)
  let loop = do
        launched <- readIORef launchedRef
        if maybe False (launched >=) maxTasks
          then pure ()
          else do
            waitQSem slots
            leased <- withLock paths (leaseUpTo paths worker 1)
            case leased of
              [] -> signalQSem slots
              (lease : _) -> do
                writeIORef launchedRef (launched + 1)
                _ <- forkFinally (runOneLease paths config lease) $ \outcome -> do
                  case outcome of
                    Left exception -> do
                      held <- reported exception
                      modifyMVar_ workerFailures (pure . (held :))
                    Right () -> pure ()
                  signalQSem slots
                  signalQSem completions
                loop
  loop
  final <- readIORef launchedRef
  waitAll completions final
  failures <- readMVar workerFailures
  case reverse failures of
    [] -> pure ()
    exception : _ -> throwIO exception
  where
    waitAll _ 0 = pure ()
    waitAll sem n = waitQSem sem >> waitAll sem (n - 1 :: Int)
    -- A task's failure is said when it happens, while the others run on.
    -- What is kept for the end is only its exit status, so the entry point
    -- does not say it a second time.
    reported exception = case fromException exception of
      Just failure -> do
        report (failure :: SpoolError)
        pure (toException (ExitFailure (exitStatus failure)))
      Nothing -> pure exception

-- | Run one already-leased task to completion: refuse it outright if its
-- capability or payload size fails the configuration's rules, otherwise
-- run the mapped executable and ack or fail the lease with the result.
runOneLease :: Paths -> WorkConfig -> Lease -> IO ()
runOneLease paths config lease = do
  let task = leaseTask lease
      leaseIdent = leaseId lease
      capability = taskCapability task
  case Map.lookup capability (wcCapabilities config) of
    Nothing -> completeFailure paths (taskId task) leaseIdent
      ("capability " <> capabilityText capability
        <> " is not in the worker configuration") NoRetry
    Just capConfig -> do
      let payloadBytes = canonical (taskPayload task)
      if BL.length payloadBytes > capMaxPayloadBytes capConfig
        then completeFailure paths (taskId task) leaseIdent
          ("payload of " <> T.pack (show (BL.length payloadBytes))
            <> " bytes exceeds max_payload_bytes " <> T.pack (show (capMaxPayloadBytes capConfig)))
          NoRetry
        else runExecutable paths config task leaseIdent capConfig payloadBytes

runExecutable
  :: Paths -> WorkConfig -> Task -> LeaseId -> CapabilityConfig -> BL.ByteString -> IO ()
runExecutable paths config task leaseIdent capConfig payloadBytes = do
  tempDir <- freshTempDir
  renewalFailure <- newEmptyMVar
  renewalThreadId <- forkIO
    (renewalLoop paths (taskId task) leaseIdent (wcRenewSeconds config)
      renewalFailure)
  outcome <- (do
      receiveTaskAttachments paths task tempDir
      runCapability capConfig (wcEnv config) tempDir payloadBytes)
    `finally` (killThread renewalThreadId >> removeWorkerDirectory tempDir)
  renewalError <- tryReadMVar renewalFailure
  case renewalError of
    Just failure -> throwIO (withContext "work: renewal failed: " failure)
    Nothing -> case outcome of
      RunFailure reason -> completeFailure paths (taskId task) leaseIdent reason Retry
      RunSuccess stdoutBytes -> case A.eitherDecode stdoutBytes of
        Left _ -> completeFailure paths (taskId task) leaseIdent "output is not JSON" Retry
        Right outputValue -> completeSuccess paths task leaseIdent outputValue

receiveTaskAttachments :: Paths -> Task -> FilePath -> IO ()
receiveTaskAttachments paths task tempDir = do
  let workerAttachmentRoot = tempDir </> "attachments"
  forM_ (taskAttachments task) $ \attachment -> do
    let source = SA.attachmentPath (attachmentsDir paths) (taskId task) attachment
    bracket (openBinaryFile source ReadMode) hClose $ \handle -> do
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

renewalLoop :: Paths -> TaskId -> LeaseId -> Int -> MVar SpoolError -> IO ()
renewalLoop paths taskIdent leaseIdent renewSeconds failure = do
  threadDelay (renewSeconds * 1000000)
  result <- withLock paths (renewOne paths (LeaseRef taskIdent leaseIdent))
  case result of
    Right () -> renewalLoop paths taskIdent leaseIdent renewSeconds failure
    Left refusal -> putMVar failure refusal

completeSuccess :: Paths -> Task -> LeaseId -> A.Value -> IO ()
completeSuccess paths task leaseIdent output = withLock paths $ do
  result <- ackOne paths (LeaseRef (taskId task) leaseIdent) output
  case result of
    Left refusal -> throwIO (withContext "work: " refusal)
    Right _ -> pure ()

completeFailure :: Paths -> TaskId -> LeaseId -> T.Text -> Retry -> IO ()
completeFailure paths taskIdent leaseIdent reason retry = withLock paths $ do
  result <- failLease paths (LeaseRef taskIdent leaseIdent) reason retry
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

-- | How long a run that has been sent SIGTERM may keep going before it is
-- sent SIGKILL.
terminationGraceSeconds :: Int
terminationGraceSeconds = 5

-- | Run one capability executable with the given environment, cwd, and
-- stdin payload. It runs in its own process group (`create_group`), killed
-- (and reporting a timeout) if it outlives `capTimeoutSeconds`, or (and
-- reporting an overrun) if either stream's captured output outlives
-- `capMaxOutputBytes`. Killing the group, not just the immediate process,
-- reaches a descendant that would otherwise survive and keep the pipes
-- open. The kill is SIGTERM first; a program may ignore that, so one still
-- running `terminationGraceSeconds` later is sent SIGKILL, which it cannot.
runCapability :: CapabilityConfig -> [(String, String)] -> FilePath -> BL.ByteString -> IO RunOutcome
runCapability capConfig envPairs cwdPath payload = do
  (Just hin, Just hout, Just herr, ph) <- createProcess (proc (capExec capConfig) (capArgs capConfig))
    { cwd = Just cwdPath
    , env = Just envPairs
    , std_in = CreatePipe
    , std_out = CreatePipe
    , std_err = CreatePipe
    , create_group = True
    }
  inputResult <- try (BL.hPut hin payload >> hClose hin)
    :: IO (Either IOException ())
  -- The watchdog and both readers can each ask for the kill; the first
  -- request wins and the terminator carries it out once. The child may exit
  -- between a limit firing and a signal. That process race is the only
  -- error intentionally ignored here.
  killRequested <- newEmptyMVar
  terminator <- forkIO $ do
    takeMVar killRequested
    ignoreProcessRace (signalGroup sigTERM ph)
    threadDelay (terminationGraceSeconds * 1000000)
    ignoreProcessRace (signalGroup sigKILL ph)
  let limit = capMaxOutputBytes capConfig
      kill = void (tryPutMVar killRequested ())
  outVar <- newEmptyMVar
  errVar <- newEmptyMVar
  outputExceeded <- newIORef False
  _ <- forkIO (readerThread limit outputExceeded kill hout outVar)
  _ <- forkIO (readerThread limit outputExceeded kill herr errVar)
  timedOut <- newIORef False
  watchdog <- forkIO $ do
    threadDelay (capTimeoutSeconds capConfig * 1000000)
    writeIORef timedOut True
    kill
  exitCode <- waitForProcess ph
  killThread watchdog
  killThread terminator
  outResult <- readMVar outVar
  errResult <- readMVar errVar
  outBytes <- either ioError pure outResult
  errBytes <- either ioError pure errResult
  isTimeout <- readIORef timedOut
  isOutputExceeded <- readIORef outputExceeded
  pure $ case inputResult of
    Left exception -> RunFailure
      ("could not write payload: " <> T.pack (displayException exception))
    Right () | isTimeout ->
      RunFailure ("timeout after " <> T.pack (show (capTimeoutSeconds capConfig)) <> " s")
    Right () | isOutputExceeded ->
      RunFailure ("output exceeds max_output_bytes " <> T.pack (show limit))
    Right () -> case exitCode of
      ExitSuccess -> RunSuccess (BL.fromStrict outBytes)
      ExitFailure n -> RunFailure
        ("exit " <> T.pack (show n) <> ": " <> decodeLenient (tailBytes 1000 errBytes))

-- | Send a signal to the negative of the child's pid, i.e. every process in
-- its group, not just the one Spool exec'd. `getPid` returns Nothing once
-- the process handle has already been reaped, which this treats as nothing
-- left to signal.
signalGroup :: Signal -> ProcessHandle -> IO ()
signalGroup signal ph = do
  running <- getPid ph
  case running of
    Nothing -> pure ()
    Just pid -> signalProcess signal (negate pid)

readerThread
  :: Int64 -> IORef Bool -> IO () -> Handle -> MVar (Either IOException BS.ByteString) -> IO ()
readerThread limit exceededRef kill handle var = do
  result <- try (readCapped limit exceededRef kill handle) :: IO (Either IOException BS.ByteString)
  putMVar var result

-- | Read a handle to EOF in chunks, stopping (and killing the process) the
-- moment the total exceeds `limit`, so a capability that writes without
-- bound cannot grow the worker's memory without bound either.
readCapped :: Int64 -> IORef Bool -> IO () -> Handle -> IO BS.ByteString
readCapped limit exceededRef kill handle = go [] 0
  where
    chunkSize = 65536
    go chunks total = do
      chunk <- BS.hGetSome handle chunkSize
      if BS.null chunk
        then pure (BS.concat (reverse chunks))
        else do
          let total' = total + fromIntegral (BS.length chunk)
              chunks' = chunk : chunks
          if total' > limit
            then do
              writeIORef exceededRef True
              kill
              pure (BS.concat (reverse chunks'))
            else go chunks' total'

tailBytes :: Int -> BS.ByteString -> BS.ByteString
tailBytes n bytes = BS.drop (max 0 (BS.length bytes - n)) bytes

decodeLenient :: BS.ByteString -> T.Text
decodeLenient = TE.decodeUtf8With TEE.lenientDecode
