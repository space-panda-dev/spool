{-# LANGUAGE OverloadedStrings #-}

-- | Account grants and the exact SSH forced-command boundary. The pure half,
-- the byte grammar and the record shapes, is "Spool.Access".
module Spool.Grants
  ( grantAccess
  , revokeAccess
  , runRemote
  ) where

import Control.Exception (bracket, onException, throwIO)
import Control.Monad (forM, forM_, unless, when)
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
                         getHomeDirectory, removeFile, renameFile)
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
  , Paths (..)
  , atomicCreate
  , atomicReplace
  , fileExists
  , ignoreMissing
  , initialise
  , jsonFiles
  , leasedPath
  , makePaths
  , resultPath
  , withLock
  )
import Spool.Input
  ( parseAckLine
  , parseLeaseRefLine
  , parseFailLine
  , inputLines
  )
import Spool.Store
  ( recoverAttachmentState
  , readTaskFile
  , readResultRecordFile
  , readWorkerSidecar
  , removeSidecars
  , leaseIdOfFile
  , leaseTasks
  , ackLines
  , renewLines
  , failLines
  , returnToPending
  , fetchAttachmentBytes
  )
import Spool.Types
  ( LeaseId
  , TaskId
  , WorkerName
  , taskIdText
  , workerNameText
  )
import Spool.Wire (Task (..), parseFetchRequest, canonical, extractTextField)

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

grantAccess :: Paths -> T.Text -> WorkerName -> FilePath -> Maybe T.Text -> IO ()
grantAccess paths peer worker keyPath expiry = do
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
    (Access.publicKeyText publicKey) expiry)
  executablePath <- getExecutablePath >>= canonicalizePath
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
  when active (renameFile activePath tombstonePath)
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
  when tombstoned (removeFile tombstonePath)
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
    when (owner == worker) $ do
      task <- readTaskFile path
      returnToPending paths task
      removeFile path
      removeSidecars paths leaseIdent

runRemote :: T.Text -> IO ()
runRemote requested = do
  identifier <- orThrow malformed (Access.mkGrantId requested)
  (grants, _) <- accountGrantPaths
  path <- orThrow malformed (Access.grantRecordPath grants identifier)
  grant <- loadActiveRemoteGrant identifier path
  command <- PosixEnv.getEnv "SSH_ORIGINAL_COMMAND"
  operation <- orThrow malformed
    (Access.parseRemoteCommand (fromMaybe BS.empty command))
  let paths = makePaths (Access.grantSpool grant)
  initialise paths
  withLock paths $ do
    current <- loadActiveRemoteGrant identifier path
    unless (Access.grantSpool current == rootDir paths) (throwIO noGrant)
    recoverAttachmentState paths
    dispatchRemote paths (Access.grantWorker current) operation

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

dispatchRemote :: Paths -> WorkerName -> Access.RemoteCommand -> IO ()
dispatchRemote paths worker operation = case operation of
  Access.RemoteLease count -> do
    let requested = fromMaybe 1 count
    when (requested > toInteger (maxBound :: Int))
      (throwIO (malformed "lease count is too large for this host"))
    leaseTasks paths worker (fromInteger requested)
  Access.RemoteAck -> do
    linesIn <- inputLines
    references <- mapM (fmap (\(ident, lease, _) -> (ident, lease)) . parseAckLine) linesIn
    mapM_ (ensureRemoteAckOwner paths worker) references
    ackLines paths linesIn
  Access.RemoteRenew -> do
    linesIn <- inputLines
    references <- mapM parseLeaseRefLine linesIn
    mapM_ (ensureLiveLeaseOwner paths worker) references
    renewLines paths linesIn
  Access.RemoteFail retry -> do
    linesIn <- inputLines
    references <- mapM (fmap (\(ident, lease, _) -> (ident, lease)) . parseFailLine) linesIn
    mapM_ (ensureLiveLeaseOwner paths worker) references
    failLines retry paths linesIn
  Access.RemoteFetch -> do
    bytes <- BL.getContents
    (ident, leaseIdent, _) <- orThrow malformed (parseFetchRequest bytes)
    ensureLiveLeaseOwner paths worker (ident, leaseIdent)
    fetchAttachmentBytes paths bytes

ensureLiveLeaseOwner :: Paths -> WorkerName -> (TaskId, LeaseId) -> IO ()
ensureLiveLeaseOwner paths worker (ident, leaseIdent) = do
  let path = leasedPath paths leaseIdent
  present <- fileExists path
  unless present (throwIO (stale "lease is unknown or stale"))
  task <- readTaskFile path
  unless (taskId task == ident)
    (throwIO (stale "lease does not belong to task_id"))
  owner <- readWorkerSidecar paths leaseIdent
  unless (owner == worker)
    (throwIO (stale "lease belongs to a different worker"))

ensureRemoteAckOwner :: Paths -> WorkerName -> (TaskId, LeaseId) -> IO ()
ensureRemoteAckOwner paths worker reference@(ident, leaseIdent) = do
  live <- fileExists (leasedPath paths leaseIdent)
  if live
    then ensureLiveLeaseOwner paths worker reference
    else do
      let path = resultPath paths leaseIdent
      present <- fileExists path
      unless present (throwIO (stale "lease is unknown or stale"))
      (record, _) <- readResultRecordFile path
      unless (extractTextField "task_id" record == taskIdText ident
        && extractTextField "worker" record == workerNameText worker)
        (throwIO (stale "lease belongs to a different worker"))
