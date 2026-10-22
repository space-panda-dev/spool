{-# LANGUAGE OverloadedStrings #-}

-- | Account grants and the exact SSH forced-command boundary. The pure half,
-- the byte grammar and the record shapes, is "Spool.Access".
module Spool.Grants
  ( grantAccess
  , revokeAccess
  , runRemote
  ) where

import Control.Exception (bracket, onException, throwIO)
import Control.Monad (forM, forM_, unless, void, when)
import Data.Aeson ((.=))
import qualified Data.Aeson as A
import qualified Data.ByteString as BS
import Data.Maybe (fromMaybe)
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (getCurrentTime)
import Numeric (showHex)
import System.Directory (createDirectoryIfMissing, canonicalizePath,
                         getHomeDirectory, removeFile)
import System.Environment (getExecutablePath)
import System.FilePath (takeBaseName, takeDirectory, (</>))
import System.IO (IOMode (ReadMode), hClose, openBinaryFile)
import System.Posix.Files (setFileMode)
import qualified System.Posix.Env.ByteString as PosixEnv
import qualified Spool.Access as Access
import Spool.Error
  ( SpoolError
  , conflict
  , corrupt
  , grantRefused
  , malformed
  , orThrow
  , retryable
  , stale
  )
import Spool.Files
  ( Created (..)
  , Paths
  , atomicCreate
  , atomicReplace
  , fileExists
  , ignoreMissing
  , initialise
  , jsonFiles
  , leasedDir
  , leasedPath
  , openSpool
  , resultPath
  , rootDir
  , syncedRemove
  , syncedRename
  , withLock
  )
import Spool.Input
  ( parseAckLine
  , parseLeaseRefLine
  , parseFailLine
  , inputLines
  )
import Spool.Store
  ( recover
  , putTasks
  , readResultRecordFile
  , readWorkerSidecar
  , leaseIdOfFile
  , leaseTasks
  , resultsCommand
  , failuresCommand
  , collectTasks
  , withdrawTasks
  , statusTasks
  , answerEach
  , ackStep
  , renewStep
  , failStep
  , abandonLease
  , leaseStands
  , revive
  , withdrawnLease
  , fetchAttachment
  , checkStaged
  , liveLeaseOwned
  , Sender (..)
  , sendCommand
  , takeCommand
  )
import Spool.Cli (GrantOptions (..))
import Spool.Types (WorkerName, workerNameText)
import Spool.Wire
  ( Ack (..)
  , FailRequest (..)
  , LeaseRef (..)
  , ResultRecord (..)
  , canonical
  )

accountGrantPaths :: IO (FilePath, FilePath)
accountGrantPaths = do
  home <- getHomeDirectory
  pure (home </> ".spool" </> "grants", home </> ".ssh" </> "authorized_keys")

prepareAccountPaths :: IO (FilePath, FilePath)
prepareAccountPaths = do
  (grants, authorizedKeys) <- accountGrantPaths
  createDirectoryIfMissing True grants
  createDirectoryIfMissing True (takeDirectory authorizedKeys)
  setFileMode (takeDirectory authorizedKeys) 0o700
  pure (grants, authorizedKeys)

grantAccess :: Paths -> T.Text -> WorkerName -> FilePath -> GrantOptions -> IO ()
grantAccess paths peer worker keyPath options = do
  let put = grantOptionPut options
      expiry = grantOptionExpiry options
  canonicalSpool <- canonicalizePath (rootDir paths)
  publicKey <- readCanonicalPublicKey keyPath
  (grants, authorizedKeys) <- prepareAccountPaths
  existing <- readGrantDirectory grants
  when (any (sameWorkerOrKey canonicalSpool worker publicKey) existing)
    (throwIO (conflict
      "an active grant for this spool already uses that worker or public key"))
  identifier <- freshGrantId grants
  grant <- orThrow malformed (Access.validateGrant
    (Access.grantIdText identifier) peer (workerNameText worker) canonicalSpool
    (Access.publicKeyText publicKey) put (grantOptionMaxResultBytes options) expiry)
  -- The forced command names a program by absolute path. By default that is
  -- this binary's own canonical path, which under a store such as Nix's is
  -- one build of it; a path chosen by the owner, kept pointing at whatever
  -- is installed, outlives the build.
  executablePath <- case grantOptionExecutable options of
    Just chosen -> pure chosen
    Nothing -> getExecutablePath >>= canonicalizePath
  managedLine <- orThrow malformed
    (Access.renderManagedAuthorizedKeyLine executablePath grant)
  recordPath <- orThrow malformed (Access.grantRecordPath grants identifier)
  created <- atomicCreate recordPath (BL.fromStrict (Access.renderGrant grant))
  when (created == AlreadyThere)
    (throwIO (retryable "could not create unique grant record"))
  appendManagedKey authorizedKeys managedLine
    `onException` ignoreMissing (removeFile recordPath)
  BLC.putStrLn (BL.fromStrict (Access.renderGrant grant))
  where
    sameWorkerOrKey spool workerName key grant =
      Access.grantSpool grant == spool
        && (Access.grantWorker grant == workerName
          || Access.grantPublicKey grant == key)

readCanonicalPublicKey :: FilePath -> IO Access.PublicKey
readCanonicalPublicKey path = do
  bytes <- BS.readFile path
  let withoutNewline =
        if not (BS.null bytes) && BS.last bytes == 10 then BS.init bytes else bytes
  when (BS.null withoutNewline || BS.elem 10 withoutNewline || BS.elem 13 withoutNewline)
    (throwIO (malformed "public key file must contain exactly one line"))
  key <- case TE.decodeUtf8' withoutNewline of
    Left _ -> throwIO (malformed "public key must be UTF-8")
    Right value -> pure value
  orThrow malformed (Access.mkPublicKey key)

readGrantDirectory :: FilePath -> IO [Access.Grant]
readGrantDirectory directory = do
  files <- jsonFiles directory
  forM files $ \path -> do
    grant <- readGrantRecord corrupt path
    unless (T.unpack (Access.grantIdText (Access.grantId grant)) == takeBaseName path)
      (throwIO (corrupt
        ("grant filename does not match its record: " <> path)))
    pure grant

-- | Read a grant record. What an unreadable one means depends on who asks:
-- corrupt state to the account's owner, and no grant at all to a peer.
readGrantRecord :: (String -> SpoolError) -> FilePath -> IO Access.Grant
readGrantRecord classify path = do
  bytes <- BS.readFile path
  case Access.parseGrantJSON bytes of
    Left message -> throwIO (classify
      ("invalid grant record " <> path <> ": " <> message))
    Right grant -> pure grant

freshGrantId :: FilePath -> IO Access.GrantId
freshGrantId grants = do
  bytes <- bracket (openBinaryFile "/dev/urandom" ReadMode) hClose (`BS.hGet` 16)
  unless (BS.length bytes == 16)
    (throwIO (retryable "could not read a grant identifier"))
  identifier <- orThrow corrupt (Access.mkGrantId
    ("grant_" <> T.pack (concatMap renderByte (BS.unpack bytes))))
  path <- orThrow corrupt (Access.grantRecordPath grants identifier)
  collision <- fileExists path
  if collision then freshGrantId grants else pure identifier
  where
    renderByte byte = case showHex byte "" of
      [digit] -> ['0', digit]
      digits -> digits

appendManagedKey :: FilePath -> BS.ByteString -> IO ()
appendManagedKey authorizedKeys managedLine = do
  present <- fileExists authorizedKeys
  current <- if present then BS.readFile authorizedKeys else pure BS.empty
  let separator = if BS.null current || BS.last current == 10 then BS.empty else "\n"
  atomicReplace authorizedKeys
    (BL.fromStrict (current <> separator <> managedLine))
  setFileMode authorizedKeys 0o600

rewriteAuthorizedKeys :: FilePath -> (BS.ByteString -> BS.ByteString) -> IO ()
rewriteAuthorizedKeys authorizedKeys transform = do
  present <- fileExists authorizedKeys
  when present $ do
    current <- BS.readFile authorizedKeys
    let updated = transform current
    when (updated /= current) $ do
      atomicReplace authorizedKeys (BL.fromStrict updated)
      setFileMode authorizedKeys 0o600

revokeAccess :: Paths -> T.Text -> IO ()
revokeAccess paths requested = do
  identifier <- orThrow malformed (Access.mkGrantId requested)
  canonicalSpool <- canonicalizePath (rootDir paths)
  (grants, authorizedKeys) <- prepareAccountPaths
  activePath <- orThrow malformed (Access.grantRecordPath grants identifier)
  let tombstonePath = grants </> T.unpack requested <> ".revoked"
      -- A record must be the one its file name says, and must be this
      -- spool's, before anything is done on its word.
      checked mismatch grant = do
        when (Access.grantId grant /= identifier) (throwIO (corrupt mismatch))
        when (Access.grantSpool grant /= canonicalSpool)
          (throwIO (grantRefused "grant belongs to a different spool"))
        pure grant
  active <- fileExists activePath
  activeGrant <- if active
    then fmap Just (readGrantRecord corrupt activePath
      >>= checked "grant filename does not match its record")
    else pure Nothing
  when active (syncedRename activePath tombstonePath)
  tombstoned <- fileExists tombstonePath
  grant <- case activeGrant of
    Just value -> pure (Just value)
    Nothing | tombstoned -> fmap Just (readGrantRecord corrupt tombstonePath
      >>= checked "grant tombstone does not match its identifier")
    Nothing -> pure Nothing
  rewriteAuthorizedKeys authorizedKeys
    (Access.filterManagedGrantLine identifier)
  case grant of
    Just value -> reclaimWorkerLeases paths (Access.grantWorker value)
    Nothing -> pure ()
  when tombstoned (syncedRemove tombstonePath)
  BLC.putStrLn (canonical (A.object
    [ "grant_id" .= identifier
    , "status" .= ("revoked" :: T.Text)
    ]))

reclaimWorkerLeases :: Paths -> WorkerName -> IO ()
reclaimWorkerLeases paths worker = do
  files <- jsonFiles (leasedDir paths)
  forM_ files $ \path -> do
    leaseIdent <- leaseIdOfFile path
    owner <- readWorkerSidecar paths leaseIdent
    when (owner == worker)
      (void (abandonLease paths "reclaimed: grant revoked" path leaseIdent))

runRemote :: T.Text -> IO ()
runRemote requested = do
  identifier <- orThrow malformed (Access.mkGrantId requested)
  (grants, _) <- accountGrantPaths
  path <- orThrow malformed (Access.grantRecordPath grants identifier)
  grant <- loadActiveRemoteGrant identifier path
  command <- PosixEnv.getEnv "SSH_ORIGINAL_COMMAND"
  operation <- orThrow malformed
    (Access.parseRemoteCommand (fromMaybe BS.empty command))
  paths <- openSpool (Access.grantSpool grant)
  initialise paths
  -- Under the lock, before anything is done: the grant is read again, and
  -- the spool recovered.
  let guarded = do
        current <- loadActiveRemoteGrant identifier path
        unless (Access.grantSpool current == rootDir paths) (throwIO noGrant)
        recover paths
        pure current
  case operation of
    -- The words that move bytes take the lock only on either side of them
    -- (ADR 0020).
    Access.RemoteSend -> sendCommand paths (void guarded)
      (GrantedWorker (Access.grantWorker grant) (Access.grantMaxResultBytes grant))
    Access.RemoteFetch -> fetchAttachment paths (void guarded) (Just (Access.grantWorker grant))
    -- Taking a result attachment goes with reading the result (ADR 0016).
    Access.RemoteTake
      | Access.grantPut grant -> takeCommand paths (void guarded)
      | otherwise -> throwIO (grantRefused "grant does not permit reading the spool")
    _ -> withLock paths (guarded >>= \current -> dispatchRemote paths current operation)

-- | A peer learns that it has no grant, and never why.
noGrant :: SpoolError
noGrant = grantRefused "grant is missing, revoked, or expired"

loadActiveRemoteGrant :: Access.GrantId -> FilePath -> IO Access.Grant
loadActiveRemoteGrant identifier path = do
  present <- fileExists path
  unless present (throwIO noGrant)
  grant <- readGrantRecord grantRefused path
  unless (Access.grantId grant == identifier) (throwIO noGrant)
  now <- getCurrentTime
  when (maybe False (now >=) (Access.grantExpiresAt grant)) (throwIO noGrant)
  pure grant

dispatchRemote :: Paths -> Access.Grant -> Access.RemoteCommand -> IO ()
dispatchRemote paths grant operation = case operation of
  -- A grant that may put reads the same lines put reads locally; one that
  -- may not is denied before a line is read (ADR 0015). Attachments cannot
  -- arrive this way, which putTasks says when a task declares one.
  Access.RemotePut
    | Access.grantPut grant -> putTasks paths Nothing
    | otherwise -> throwIO (grantRefused "grant does not permit put")
  -- Reading what came of the tasks goes with having put them (ADR 0016).
  Access.RemoteResults -> reading (resultsCommand paths)
  Access.RemoteFailures -> reading (failuresCommand paths)
  Access.RemoteStatus format -> reading (statusTasks paths format)
  -- Saying a result has been read goes with reading it (ADR 0018). A grant
  -- that may not is denied before a line is read.
  Access.RemoteCollect
    | Access.grantPut grant -> collectTasks paths
    | otherwise -> throwIO (grantRefused "grant does not permit collect")
  -- Taking a task back goes with having put it (ADR 0023).
  Access.RemoteWithdraw
    | Access.grantPut grant -> withdrawTasks paths
    | otherwise -> throwIO (grantRefused "grant does not permit withdraw")
  Access.RemoteLease count -> do
    let requested = fromMaybe 1 count
    when (requested > toInteger (maxBound :: Int))
      (throwIO (malformed "lease count is too large for this host"))
    leaseTasks paths worker (fromInteger requested)
  -- Every line is read before any is acted on. A line whose lease is not
  -- the grant's worker's is answered stale, and the others are acted on.
  Access.RemoteAck -> do
    acks <- mapM parseAckLine =<< inputLines
    mapM_ (checkStaged paths) acks
    answerEach ackRef (ownedAck `before` ackStep paths) acks
  Access.RemoteRenew -> do
    references <- mapM parseLeaseRefLine =<< inputLines
    answerEach id (standing `before` renewStep paths) references
  Access.RemoteFail retry -> do
    requests <- mapM parseFailLine =<< inputLines
    answerEach failRef ((ownedLive . failRef) `before` failStep retry paths) requests
  -- Handled before the lock is taken, by runRemote.
  Access.RemoteSend -> throwIO (malformed "send is not dispatched under the lock")
  Access.RemoteTake -> throwIO (malformed "take is not dispatched under the lock")
  Access.RemoteFetch -> throwIO (malformed "fetch is not dispatched under the lock")
  where
    worker = Access.grantWorker grant
    reading command
      | Access.grantPut grant = command
      | otherwise = throwIO (grantRefused "grant does not permit reading the spool")
    ownedLive = liveLeaseOwned paths (Just worker)
    -- A renewal takes back the worker's own lease reclaimed while it was
    -- away, if its task has waited since (ADR 0027).
    standing = leaseStands paths (Just worker)
    ownedAck ack = ackOwned paths worker (ackRef ack)
    -- Act on an item only if its lease is the grant's worker's.
    before owned step item = do
      allowed <- owned item
      case allowed of
        Left refusal -> pure (Left refusal)
        Right () -> step item

-- | Whether a lease is this worker's to acknowledge: live and its own, or
-- already done by it, so that repeating an acknowledgement is allowed.
ackOwned :: Paths -> WorkerName -> LeaseRef -> IO (Either SpoolError ())
ackOwned paths worker reference@(LeaseRef ident leaseIdent) = do
  inFlight <- fileExists (leasedPath paths leaseIdent)
  -- An ack takes back the worker's own lease reclaimed while it was away,
  -- if its task has waited since (ADR 0027).
  live <- if inFlight then pure True else revive paths (Just worker) reference
  if live
    then liveLeaseOwned paths (Just worker) reference
    else do
      let path = resultPath paths leaseIdent
      present <- fileExists path
      gone <- withdrawnLease paths reference
      if not present
        then pure (Left (fromMaybe (stale "lease is unknown or stale") gone))
        else do
          record <- readResultRecordFile path
          pure $ if resultTask record == ident && resultWorker record == worker
            then Right ()
            else Left (stale "lease belongs to a different worker")
