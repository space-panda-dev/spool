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
  , workWith
  ) where

import Control.Concurrent (myThreadId, threadDelay, throwTo)
import Control.Concurrent.Async
  ( Async
  , AsyncCancelled (..)
  , asyncWithUnmask
  , cancel
  , poll
  , race
  , wait
  , waitCatch
  , waitCatchSTM
  , waitSTM
  , withAsync
  )
import Control.Concurrent.MVar (modifyMVar_, newMVar, readMVar)
import Control.Concurrent.QSem (newQSem, signalQSem, waitQSem)
import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , check
  , modifyTVar'
  , newTVarIO
  , orElse
  , readTVar
  , readTVarIO
  , registerDelay
  , writeTVar
  )
import Control.Exception
  ( IOException
  , SomeException
  , bracket
  , bracketOnError
  , bracket_
  , catch
  , displayException
  , finally
  , fromException
  , mask_
  , throwIO
  , toException
  , try
  )
import Control.Monad (filterM, forM_, forever, unless, void, when)
import qualified Data.Aeson as A
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import qualified Data.Set as Set
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import Data.Unique (hashUnique, newUnique)
import GHC.IO.Exception (IOErrorType (ResourceVanished))
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory, removeFile,
                         renameFile)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (Handle, IOMode (AppendMode), hClose, hFileSize, stderr, withBinaryFile)
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
  ( ErrorClass (..)
  , SpoolError (..)
  , corrupt
  , exitStatus
  , isWithdrawn
  , report
  , stale
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
import Spool.Worker.Disk (freeBytes, mayFetch)
import Spool.Worker.Follow (awaitLease, nextWait)
import Spool.Worker.Outputs (collectOutputs)
import Spool.Worker.Room (Sent (..), roomWaits, sendOutputs)

-- | The outcome of running a capability's executable to completion: a
-- failure says whether the task is to be tried again.
data RunOutcome = RunSuccess BL.ByteString | RunFailure Retry T.Text

-- | What a run comes to once its outputs are sent: a result and the result
-- attachments sent with it, a failure, or a lease lost while it waited.
data Returned = Returned A.Value [SA.Attachment] | Failed Retry T.Text | Lost

-- | Whether a program that exited with this status is to be tried again.
-- Under ADR 0017, exit 65 (EX_DATAERR) says the task can never succeed.
retryAfterExit :: Int -> Retry
retryAfterExit 65 = NoRetry
retryAfterExit _ = Retry

-- | What the tasks a worker holds share (ADR 0026): the slots its programs
-- run in, free and waited for, the tasks it holds, the free space a fetch
-- must leave while a task leased before it is held, and how to measure it.
data Pool = Pool
  { poolSlots :: TVar Int
    -- ^ Slots free for a program to run in, of `max_concurrent`.
  , poolWaiting :: TVar (Set.Set Int)
    -- ^ The tickets, in lease order, of the tasks leased that have not yet
    -- taken a slot or ended.
  , poolHeld :: TVar (Set.Set Int)
    -- ^ The tickets of every task leased and not yet ended.
  , poolFloor :: Maybe Integer
  , poolDiskFree :: IO Integer
  }

-- | Take a slot for the task with this ticket: only while there are more
-- slots free than tasks leased before it still waiting for one, so a task
-- leased ahead never runs before the task leased before it.
takeSlot :: Pool -> Int -> IO ()
takeSlot pool ticket = atomically $ do
  free <- readTVar (poolSlots pool)
  waiting <- readTVar (poolWaiting pool)
  let (earlier, _) = Set.split ticket waiting
  check (free > Set.size earlier)
  writeTVar (poolSlots pool) (free - 1)
  writeTVar (poolWaiting pool) (Set.delete ticket waiting)

releaseSlot :: Pool -> IO ()
releaseSlot pool = atomically (modifyTVar' (poolSlots pool) (+ 1))

-- | A task that has ended waits for nothing and holds nothing.
leaveQueue :: Pool -> Int -> IO ()
leaveQueue pool ticket = atomically $ do
  modifyTVar' (poolWaiting pool) (Set.delete ticket)
  modifyTVar' (poolHeld pool) (Set.delete ticket)

-- | Lease tasks one at a time and run each in its own thread, as many at
-- once as the configuration allows, until nothing is pending or the count
-- asked for has been started. Then wait for what is running.
--
-- A worker that follows its spool, given the longest it waits between two
-- leases, does not stop when nothing is pending: it waits for a task, until
-- the count is started or it is told to stop.
runWork :: Connection -> FilePath -> Maybe Int -> Maybe Int -> IO ()
runWork spool configPath maxTasks follow = do
  config <- loadWorkConfig configPath
  workWith (\seconds -> threadDelay (seconds * 1000000)) spool config maxTasks follow

-- | The worker, given how to wait so many seconds.
--
-- It holds up to `max_concurrent` plus `prefetch` leases at once (ADR 0026).
-- A task fetches its attachments as soon as it is leased, and then waits
-- for one of `max_concurrent` slots to run its program in, so a task leased
-- ahead is fetched while the one before it runs. With `prefetch` 0 every
-- task leased has a slot waiting for it, as before.
workWith :: (Int -> IO ()) -> Connection -> WorkConfig -> Maybe Int -> Maybe Int -> IO ()
workWith sleep spool config maxTasks follow = do
  held <- newQSem (wcMaxConcurrent config + wcPrefetch config)
  slots <- newTVarIO (wcMaxConcurrent config)
  waiting <- newTVarIO Set.empty
  heldTickets <- newTVarIO Set.empty
  base <- getTemporaryDirectory
  let pool = Pool slots waiting heldTickets (toInteger <$> wcMinFreeBytes config) (freeBytes base)
  failure <- newMVar (Nothing :: Maybe SomeException)
  stoppedBySignal $ bracket (newIORef []) stopAll $ \running -> do
    let -- A task's failure is said when it happens, while the others run
        -- on. What is kept for the end is only the first one's exit
        -- status, so the entry point does not say it a second time, and a
        -- worker that runs for months does not keep every one. A task that
        -- is being stopped has not failed.
        record exception = case fromException exception of
          Just AsyncCancelled -> throwIO exception
          Nothing -> do
            kept <- case fromException exception of
              Just refusal -> do
                report (refusal :: SpoolError)
                pure (toException (ExitFailure (exitStatus refusal)))
              Nothing -> pure exception
            modifyMVar_ failure (pure . Just . fromMaybe kept)
        -- What has ended is let go, so the list holds what is running. Only
        -- this thread changes it.
        start ticket lease = mask_ $ do
          atomically $ do
            modifyTVar' (poolWaiting pool) (Set.insert ticket)
            modifyTVar' (poolHeld pool) (Set.insert ticket)
          task <- asyncWithUnmask $ \unmask ->
            (unmask (runOneLease spool config pool ticket lease) `catch` record)
              `finally` (leaveQueue pool ticket >> signalQSem held)
          live <- filterM (fmap isNothing . poll) =<< readIORef running
          atomicModifyIORef' running (const (task : live, ()))
        next = case follow of
          Nothing -> leaseOne spool
          Just capSeconds -> Just <$> awaitLease sleep report capSeconds (leaseOne spool)
        loop launched = unless (maybe False (launched >=) maxTasks) $ do
          leased <- bracketOnError (waitQSem held) (const (signalQSem held)) $
            \() -> do
              roomToLeaseAhead sleep pool (wcRenewSeconds config)
              leased <- next
              case leased of
                Just lease -> start launched lease >> pure True
                Nothing -> signalQSem held >> pure False
          when leased (loop (launched + 1 :: Int))
    loop 0
    readIORef running >>= mapM_ wait
  readMVar failure >>= mapM_ throwIO
  where
    stopAll running = readIORef running >>= mapM_ cancel

-- | Before leasing a task while another is held, wait for the free space
-- `min_free_bytes` asks for (ADR 0026): the waits start at 1 second and
-- double up to the renewal interval. With no floor, or nothing held, it
-- does not wait.
roomToLeaseAhead :: (Int -> IO ()) -> Pool -> Int -> IO ()
roomToLeaseAhead sleep pool capSeconds = case poolFloor pool of
  Nothing -> pure ()
  Just floorBytes ->
    let go said waiting = do
          others <- Set.size <$> readTVarIO (poolHeld pool)
          free <- if others == 0 then pure 0 else poolDiskFree pool
          if others == 0 || free >= floorBytes
            then when said (sayWorker "room on disk again, leasing")
            else do
              unless said $ sayWorker ("leases nothing ahead while " <> show free
                <> " bytes are free, under min_free_bytes " <> show floorBytes)
              sleep waiting
              go True (nextWait capSeconds waiting)
    in go False (min 1 capSeconds)

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
runOneLease :: Connection -> WorkConfig -> Pool -> Int -> Lease -> IO ()
runOneLease spool config pool ticket lease = do
  let task = leaseTask lease
      reference = LeaseRef (taskId task) (leaseId lease)
      capability = taskCapability task
  case Map.lookup capability (wcCapabilities config) of
    Nothing -> completeFailure spool reference
      ("capability " <> capabilityText capability
        <> " is not in the worker configuration") NoRetry
    Just capConfig -> do
      let payloadBytes = canonical (taskPayload task)
      if BL.length payloadBytes > capMaxPayloadBytes capConfig
        then completeFailure spool reference
          ("payload of " <> T.pack (show (BL.length payloadBytes))
            <> " bytes exceeds max_payload_bytes " <> T.pack (show (capMaxPayloadBytes capConfig)))
          NoRetry
        else runExecutable spool config pool ticket task (leaseId lease) capConfig payloadBytes

-- | Fetch, run, send, and acknowledge one task while its lease is renewed.
-- A renewal answered @withdrawn@ stops the run at once: its program is
-- ended and its working directory removed, and nothing has failed
-- (ADR 0023).
runExecutable
  :: Connection -> WorkConfig -> Pool -> Int -> Task -> LeaseId -> CapabilityConfig
  -> BL.ByteString -> IO ()
runExecutable spool config pool ticket task leaseIdent capConfig payloadBytes =
  withAsync (renewalLoop say spool reference renewSeconds) $ \renewing -> do
    let pause = whileLeased renewing
    ended <- try (race (withdrawnWhile renewing) (attempt pause))
    case ended of
      Right (Left _) -> stopped
      -- A request refused as stale may have met the withdrawal before the
      -- renewal did; one renewal says which.
      Left refusal@(SpoolError Stale _) -> do
        again <- try (renewLease spool reference)
          :: IO (Either SpoolError (Either SpoolError ()))
        case again of
          Right (Left answer) | isWithdrawn answer -> stopped
          _ -> throwIO refusal
      Left other -> throwIO other
      Right (Right outcome) -> do
        -- A lease lost in a wait has its refusal in hand.
        renewal <- case outcome of
          Lost -> Just <$> waitCatch renewing
          _ -> poll renewing
        case renewal of
          Just (Right refusal)
            | isWithdrawn refusal -> stopped
            | otherwise -> throwIO (withContext "work: renewal failed: " refusal)
          Just (Left exception) -> throwIO exception
          Nothing -> case outcome of
            Failed retry reason -> completeFailure spool reference reason retry
            Returned outputValue attachments ->
              completeSuccess say spool pause renewSeconds reference outputValue attachments
            Lost -> throwIO (stale "work: the lease was lost")
  where
    reference = LeaseRef (taskId task) leaseIdent
    renewSeconds = wcRenewSeconds config
    say = sayTask (taskId task)
    stopped = say "withdrawn: its run is stopped and its working directory removed"
    attempt pause = do
      roomy <- awaitRoomToFetch pool ticket pause say renewSeconds (attachmentBytes task)
      if not roomy
        then pure Lost
        else bracket freshTempDir removeWorkerDirectory $ \tempDir -> do
          received <- receiveTaskAttachments spool pause say renewSeconds task leaseIdent tempDir
          if not received
            then pure Lost
            else do
              ran <- bracket_ (takeSlot pool ticket) (releaseSlot pool)
                (runCapability capConfig (wcEnv config) tempDir payloadBytes)
              returned spool reference config capConfig pause say tempDir ran

-- | The renewal's refusal, if it was that the task was withdrawn; otherwise
-- this waits until it is stopped, and the run goes on as it always did.
withdrawnWhile :: Async SpoolError -> IO SpoolError
withdrawnWhile renewing = do
  ended <- waitCatch renewing
  case ended of
    Right refusal | isWithdrawn refusal -> pure refusal
    _ -> forever (threadDelay 3600000000)

-- | The bytes of a task's attachments, all together.
attachmentBytes :: Task -> Integer
attachmentBytes task = sum (map (toInteger . SA.attachmentSize) (taskAttachments task))

-- | Before a task fetches, wait while the fetch would take the disk under
-- `min_free_bytes` and a task leased before it is still held (ADR 0026),
-- renewing the lease. The first task held never waits, so the tasks held
-- cannot wait for each other. False when the lease ended meanwhile.
awaitRoomToFetch
  :: Pool -> Int -> (Int -> IO Bool) -> (String -> IO ()) -> Int -> Integer -> IO Bool
awaitRoomToFetch pool ticket pause say capSeconds size = case poolFloor pool of
  Nothing -> pure True
  Just floorBytes ->
    let go said waiting = do
          others <- Set.size . fst . Set.split ticket <$> readTVarIO (poolHeld pool)
          free <- if others == 0 then pure 0 else poolDiskFree pool
          if mayFetch (Just floorBytes) others free size
            then True <$ when said (say "room on disk, fetching")
            else do
              unless said $ say ("waits to fetch " <> show size <> " bytes while "
                <> show free <> " bytes are free, under min_free_bytes " <> show floorBytes)
              kept <- pause waiting
              if kept then go True (nextWait capSeconds waiting) else pure False
    in go False (min 1 capSeconds)

-- | Wait so many seconds while the lease is renewed: false, at once, when
-- its renewal has ended.
whileLeased :: Async SpoolError -> Int -> IO Bool
whileLeased renewing seconds = do
  expired <- registerDelay (seconds * 1000000)
  atomically $
    (False <$ waitCatchSTM renewing) `orElse` (True <$ (readTVar expired >>= check))

-- | Make a request again after the transport failed to carry it, or the
-- spool could not answer it (exit 75), for as long as the lease is renewed
-- (ADR 0027). The waits start at 1 second and double up to the renewal
-- interval. Nothing when the lease ended in a wait.
persisting :: (String -> IO ()) -> (Int -> IO Bool) -> Int -> String -> IO a -> IO (Maybe a)
persisting say pause capSeconds what request = go False (min 1 capSeconds)
  where
    go said waiting = do
      result <- try request
      case result of
        Right value -> do
          when said (say (what <> " reached the spool again"))
          pure (Just value)
        Left (SpoolError Retryable message) -> do
          unless said $ say (what <> " could not reach the spool, trying again while"
            <> " the lease is renewed: " <> message)
          kept <- pause waiting
          if kept then go True (nextWait capSeconds waiting) else pure Nothing
        Left other -> throwIO other

-- | A run that exited 0 with JSON returns that result, and sends what it
-- left in outputs/, while its lease is still renewed. outputs/ that breaks
-- the rules is the program's doing, and fails the task for good. A grant
-- with no room for a file now is waited for (ADR 0021), and one that could
-- never hold it fails the task for good. A send the transport could not
-- carry is made again (ADR 0027).
returned
  :: Connection -> LeaseRef -> WorkConfig -> CapabilityConfig -> (Int -> IO Bool)
  -> (String -> IO ()) -> FilePath -> RunOutcome -> IO Returned
returned spool reference config capConfig pause say tempDir ran = case ran of
  RunFailure retry reason -> pure (Failed retry reason)
  RunSuccess stdoutBytes -> case A.eitherDecode stdoutBytes of
    Left _ -> pure (Failed Retry "output is not JSON")
    Right outputValue -> do
      outputs <- collectOutputs (capMaxResultAttachmentBytes capConfig) (tempDir </> "outputs")
      case outputs of
        Left reason -> pure (Failed NoRetry reason)
        Right files -> do
          sent <- sendOutputs send pause say
            (roomWaits (wcRenewSeconds config) (capTimeoutSeconds capConfig)) files
          pure $ case sent of
            AllSent attachments -> Returned outputValue attachments
            NotSent retry reason -> Failed retry reason
            LeaseGone -> Lost
  where
    send attachment path = fromMaybe (Left (stale "the lease ended while a send waited"))
      <$> persisting say pause (wcRenewSeconds config)
        ("the send of result attachment " <> digestOf attachment)
        (sendResultAttachment spool reference attachment path)

-- | Say a line on stderr about one task.
sayTask :: TaskId -> String -> IO ()
sayTask ident line = sayWorker ("task " <> T.unpack (taskIdText ident) <> ": " <> line)

-- | Say a line on stderr about the worker.
sayWorker :: String -> IO ()
sayWorker line =
  BS.hPut stderr (TE.encodeUtf8 (T.pack ("spool: work: " <> line)) <> BS.singleton 10)

digestOf :: SA.Attachment -> String
digestOf = T.unpack . SA.sha256Text . SA.attachmentSha256

-- | Receive every declared attachment into the working directory, verified.
-- Bytes arrive in a partial file beside where the attachment goes; a fetch
-- the transport could not finish is asked again from where the partial
-- file ends, for as long as the lease is renewed (ADR 0027), and the whole
-- file is verified before it is given its name. False when the lease ended
-- while a fetch waited to be asked again.
receiveTaskAttachments
  :: Connection -> (Int -> IO Bool) -> (String -> IO ()) -> Int -> Task -> LeaseId -> FilePath
  -> IO Bool
receiveTaskAttachments spool pause say capSeconds task leaseIdent tempDir = do
  createDirectoryIfMissing True root
  go (taskAttachments task)
  where
    root = tempDir </> "attachments"
    reference = LeaseRef (taskId task) leaseIdent
    go [] = pure True
    go (attachment : rest) = do
      fetched <- persisting say pause capSeconds
        ("the fetch of attachment " <> digestOf attachment) (fetchOnce attachment)
      case fetched of
        Nothing -> pure False
        Just () -> go rest
    fetchOnce attachment = do
      let partial = root </> (".partial-" <> digestOf attachment)
          declared = SA.attachmentSize attachment
      withBinaryFile partial AppendMode $ \target -> do
        held <- fromInteger <$> hFileSize target
        when (held > declared) (throwIO (corrupt
          ("the partial copy of attachment " <> digestOf attachment <> " holds "
            <> show held <> " bytes, more than its " <> show declared)))
        when (held < declared) $
          withAttachment spool reference attachment held $ \source ->
            appendAtMost attachment (declared - held) source target
      verified <- SA.verifyAttachmentFile attachment partial
      case verified of
        Left message -> do
          removeFile partial
          throwIO (corrupt ("attachment verification failed for "
            <> T.unpack (taskIdText (taskId task)) <> ": " <> message))
        Right () -> renameFile partial (root </> digestOf attachment)

-- | Copy what a stream holds, up to so many bytes, to a file; a stream that
-- holds more is corrupt. One that ends sooner leaves what it held, for the
-- fetch to be asked again from there.
appendAtMost :: SA.Attachment -> Int64 -> Handle -> Handle -> IO ()
appendAtMost attachment remaining source target
  | remaining <= 0 = do
      after <- BS.hGetSome source 1
      unless (BS.null after) (throwIO (corrupt
        ("the spool sent more of attachment " <> digestOf attachment <> " than declared")))
  | otherwise = do
      chunk <- BS.hGetSome source (fromIntegral (min 65536 remaining))
      unless (BS.null chunk) $ do
        BS.hPut target chunk
        appendAtMost attachment (remaining - fromIntegral (BS.length chunk)) source target

removeWorkerDirectory :: FilePath -> IO ()
removeWorkerDirectory directory = do
  removed <- SA.attemptRemoveWorkerDirectory directory
  case removed of
    Left exception -> ioError exception
    Right () -> pure ()

-- | Renew the lease at each interval until a renewal is refused, and answer
-- with the refusal. A renewal the transport could not carry, or the spool
-- could not answer (exit 75), is said once and tried again at the next
-- interval (ADR 0027): a lease reclaimed meanwhile is taken back by the
-- next renewal that arrives, if nobody has leased its task since. It ends
-- no other way but by being stopped.
renewalLoop :: (String -> IO ()) -> Connection -> LeaseRef -> Int -> IO SpoolError
renewalLoop say spool reference renewSeconds = go False
  where
    go failing = do
      threadDelay (renewSeconds * 1000000)
      result <- try (renewLease spool reference)
      case result of
        Right (Right ()) -> do
          when failing (say "renewal reached the spool again")
          go False
        Right (Left refusal) -> pure refusal
        Left (SpoolError Retryable message) -> do
          unless failing (say ("renewal could not reach the spool, trying again: " <> message))
          go True
        Left other -> throwIO other

-- | Acknowledge, asking again while the transport cannot carry it and the
-- lease is renewed. A withdrawn task is said and is no failure.
completeSuccess
  :: (String -> IO ()) -> Connection -> (Int -> IO Bool) -> Int -> LeaseRef -> A.Value
  -> [SA.Attachment] -> IO ()
completeSuccess say spool pause capSeconds reference output attachments = do
  result <- persisting say pause capSeconds "the ack"
    (ackLease spool reference output attachments)
  case result of
    Nothing -> throwIO (stale "work: the lease ended while the ack waited for the spool")
    Just (Left refusal)
      | isWithdrawn refusal -> say "withdrawn: its result is not acknowledged"
      | otherwise -> throwIO (withContext "work: " refusal)
    Just (Right ()) -> pure ()

completeFailure :: Connection -> LeaseRef -> T.Text -> Retry -> IO ()
completeFailure spool reference reason retry = do
  result <- failLeaseWith spool reference reason retry
  case result of
    Left refusal
      | isWithdrawn refusal ->
          sayTask (refTask reference) "withdrawn: its failure is not recorded"
      | otherwise -> throwIO (withContext "work: " refusal)
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
      -- Only the three pipes: not the spool's lock, nor another program's
      -- pipes, held by a thread while this one was started.
    , close_fds = True
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
      Exited _ _ _ (Left exception) -> RunFailure Retry
        ("could not write payload: " <> T.pack (displayException exception))
      StoppedFor TimedOut -> timedOut
      StoppedFor Overran -> overran
      Exited _ output errors _ | any isPastLimit [Just output, Just errors] -> overran
      LeftOpen -> RunFailure Retry
        ("output still open " <> T.pack (show terminationGraceSeconds)
          <> " s after exit: the program left a process running")
      Exited ExitSuccess (Captured output) _ _ -> RunSuccess (BL.fromStrict output)
      Exited (ExitFailure n) _ (Captured errors) _ -> RunFailure (retryAfterExit n)
        ("exit " <> T.pack (show n) <> ": " <> decodeLenient (tailBytes 1000 errors))
      -- Every stream past its limit was answered above.
      Exited _ _ _ _ -> overran
    timedOut = RunFailure Retry
      ("timeout after " <> T.pack (show (capTimeoutSeconds capConfig)) <> " s")
    overran = RunFailure Retry
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
