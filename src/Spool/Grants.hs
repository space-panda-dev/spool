{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Account grants and the exact SSH forced-command boundary. The pure half,
-- the byte grammar and the record shapes, is "Spool.Access".
module Spool.Grants
  ( grantAccess
  , revokeAccess
  , runRemote
  ) where

import Control.Exception (bracket, onException)
import Control.Monad (forM, forM_, unless, when)
import Data.Aeson ((.=))
import qualified Data.Aeson as A
import qualified Data.ByteString as BS
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
import Spool.Failure (SpoolFailure (..), failWith, throwFailure)
import Spool.Files
  ( Paths (..)
  , withLock
  , makePaths
  , initialise
  , jsonFiles
  , fileExists
  , atomicCreate
  , atomicReplace
  , ignoreMissing
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
  , leaseTasks
  , ackLines
  , renewLines
  , failLines
  , returnToPending
  , fetchAttachmentBytes
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

grantAccess :: Paths -> T.Text -> T.Text -> FilePath -> Maybe T.Text -> IO ()
grantAccess paths peer worker keyPath expiry = do
  canonicalSpool <- canonicalizePath (rootDir paths)
  publicKey <- readCanonicalPublicKey keyPath
  (grants, authorizedKeys) <- prepareAccountPaths
  existing <- readGrantDirectory grants
  when (any (sameWorkerOrKey canonicalSpool worker publicKey) existing)
    (throwFailure (SpoolFailure 3
      "an active grant for this spool already uses that worker or public key"))
  identifier <- freshGrantId grants
  grant <- case Access.validateGrant identifier peer worker canonicalSpool publicKey expiry of
    Left message -> throwFailure (SpoolFailure 2 message)
    Right value -> pure value
  executablePath <- getExecutablePath >>= canonicalizePath
  managedLine <- case Access.renderManagedAuthorizedKeyLine executablePath grant of
    Left message -> throwFailure (SpoolFailure 2 message)
    Right value -> pure value
  recordPath <- either (throwFailure . SpoolFailure 2) pure
    (Access.grantRecordPath grants identifier)
  created <- atomicCreate recordPath (BL.fromStrict (Access.renderGrant grant))
  unless created (throwFailure (SpoolFailure 75 "could not create unique grant record"))
  appendManagedKey authorizedKeys managedLine
    `onException` ignoreMissing (removeFile recordPath)
  BLC.putStrLn (BL.fromStrict (Access.renderGrant grant))
  where
    sameWorkerOrKey spool workerName key grant =
      Access.grantSpool grant == spool
        && (Access.grantWorker grant == workerName
          || Access.grantPublicKey grant == key)

readCanonicalPublicKey :: FilePath -> IO T.Text
readCanonicalPublicKey path = do
  bytes <- BS.readFile path
  let withoutNewline =
        if not (BS.null bytes) && BS.last bytes == 10 then BS.init bytes else bytes
  when (BS.null withoutNewline || BS.elem 10 withoutNewline || BS.elem 13 withoutNewline)
    (throwFailure (SpoolFailure 2 "public key file must contain exactly one line"))
  key <- case TE.decodeUtf8' withoutNewline of
    Left _ -> throwFailure (SpoolFailure 2 "public key must be UTF-8")
    Right value -> pure value
  case Access.validatePublicKey key of
    Left message -> throwFailure (SpoolFailure 2 message)
    Right () -> pure key

readGrantDirectory :: FilePath -> IO [Access.Grant]
readGrantDirectory directory = do
  files <- jsonFiles directory
  forM files $ \path -> do
    grant <- readGrantRecord 70 path
    unless (T.unpack (Access.grantId grant) == takeBaseName path)
      (throwFailure (SpoolFailure 70
        ("grant filename does not match its record: " <> path)))
    pure grant

readGrantRecord :: Int -> FilePath -> IO Access.Grant
readGrantRecord failureCode path = do
  bytes <- BS.readFile path
  case Access.parseGrantJSON bytes of
    Left message -> throwFailure (SpoolFailure failureCode
      ("invalid grant record " <> path <> ": " <> message))
    Right grant -> pure grant

freshGrantId :: FilePath -> IO T.Text
freshGrantId grants = do
  bytes <- bracket (openBinaryFile "/dev/urandom" ReadMode) hClose (`BS.hGet` 16)
  unless (BS.length bytes == 16)
    (throwFailure (SpoolFailure 75 "could not read a grant identifier"))
  let identifier = "grant_" <> T.pack (concatMap renderByte (BS.unpack bytes))
  path <- either (throwFailure . SpoolFailure 70) pure
    (Access.grantRecordPath grants identifier)
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
revokeAccess paths identifier = do
  case Access.validateGrantId identifier of
    Left message -> throwFailure (SpoolFailure 2 message)
    Right () -> pure ()
  canonicalSpool <- canonicalizePath (rootDir paths)
  (grants, authorizedKeys) <- prepareAccountPaths
  activePath <- either (throwFailure . SpoolFailure 2) pure
    (Access.grantRecordPath grants identifier)
  let tombstonePath = grants </> T.unpack identifier <> ".revoked"
  active <- fileExists activePath
  activeGrant <- if active
    then Just <$> readGrantRecord 70 activePath
    else pure Nothing
  case activeGrant of
    Just value | Access.grantId value /= identifier ->
      throwFailure (SpoolFailure 70 "grant filename does not match its record")
    _ -> pure ()
  case activeGrant of
    Just value | Access.grantSpool value /= canonicalSpool ->
      throwFailure (SpoolFailure 5 "grant belongs to a different spool")
    _ -> pure ()
  when active (renameFile activePath tombstonePath)
  tombstoned <- fileExists tombstonePath
  grant <- case activeGrant of
    Just value -> pure (Just value)
    Nothing | tombstoned -> Just <$> readGrantRecord 70 tombstonePath
    Nothing -> pure Nothing
  case grant of
    Just value | Access.grantId value /= identifier ->
      throwFailure (SpoolFailure 70 "grant tombstone does not match its identifier")
    _ -> pure ()
  case grant of
    Just value | Access.grantSpool value /= canonicalSpool ->
      throwFailure (SpoolFailure 5 "grant belongs to a different spool")
    _ -> pure ()
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

reclaimWorkerLeases :: Paths -> T.Text -> IO ()
reclaimWorkerLeases paths worker = do
  files <- jsonFiles (leasedDir paths)
  forM_ files $ \path -> do
    let leaseIdent = T.pack (takeBaseName path)
    owner <- readWorkerSidecar paths leaseIdent
    when (owner == worker) $ do
      task <- readTaskFile path
      returnToPending paths task
      removeFile path
      removeSidecars paths leaseIdent

runRemote :: T.Text -> IO ()
runRemote identifier = do
  case Access.validateGrantId identifier of
    Left message -> failWith 2 ("spool: " <> message)
    Right () -> pure ()
  (grants, _) <- accountGrantPaths
  path <- either (failWith 2 . ("spool: " <>)) pure
    (Access.grantRecordPath grants identifier)
  grant <- loadActiveRemoteGrant identifier path
  requested <- PosixEnv.getEnv "SSH_ORIGINAL_COMMAND"
  operation <- case Access.parseRemoteCommand (maybe BS.empty id requested) of
    Left message -> failWith 2 ("spool: " <> message)
    Right value -> pure value
  let paths = makePaths (Access.grantSpool grant)
  initialise paths
  withLock paths $ do
    current <- loadActiveRemoteGrant identifier path
    unless (Access.grantSpool current == rootDir paths)
      (failWith 5 "spool: grant is missing, revoked, or expired")
    recoverAttachmentState paths
    dispatchRemote paths (Access.grantWorker current) operation

loadActiveRemoteGrant :: T.Text -> FilePath -> IO Access.Grant
loadActiveRemoteGrant identifier path = do
  present <- fileExists path
  unless present (failWith 5 "spool: grant is missing, revoked, or expired")
  grant <- readGrantRecord 5 path
  unless (Access.grantId grant == identifier)
    (failWith 5 "spool: grant is missing, revoked, or expired")
  now <- getCurrentTime
  when (maybe False (now >=) (Access.grantExpiresAt grant))
    (failWith 5 "spool: grant is missing, revoked, or expired")
  pure grant

dispatchRemote :: Paths -> T.Text -> Access.RemoteCommand -> IO ()
dispatchRemote paths worker operation = case operation of
  Access.RemoteLease count -> do
    let requested = maybe 1 id count
    when (requested > toInteger (maxBound :: Int))
      (throwFailure (SpoolFailure 2 "lease count is too large for this host"))
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
    (ident, leaseIdent, _) <- case parseFetchRequest bytes of
      Left message -> throwFailure (SpoolFailure 2 message)
      Right value -> pure value
    ensureLiveLeaseOwner paths worker (ident, leaseIdent)
    fetchAttachmentBytes paths bytes

ensureLiveLeaseOwner :: Paths -> T.Text -> (T.Text, T.Text) -> IO ()
ensureLiveLeaseOwner paths worker (ident, leaseIdent) = do
  let path = leasedDir paths </> T.unpack leaseIdent <> ".json"
  present <- fileExists path
  unless present (throwFailure (SpoolFailure 4 "lease is unknown or stale"))
  task <- readTaskFile path
  unless (taskId task == ident)
    (throwFailure (SpoolFailure 4 "lease does not belong to task_id"))
  owner <- readWorkerSidecar paths leaseIdent
  unless (owner == worker)
    (throwFailure (SpoolFailure 4 "lease belongs to a different worker"))

ensureRemoteAckOwner :: Paths -> T.Text -> (T.Text, T.Text) -> IO ()
ensureRemoteAckOwner paths worker reference@(_, leaseIdent) = do
  live <- fileExists (leasedDir paths </> T.unpack leaseIdent <> ".json")
  if live
    then ensureLiveLeaseOwner paths worker reference
    else do
      let resultPath = resultsDir paths </> T.unpack leaseIdent <> ".json"
      present <- fileExists resultPath
      unless present (throwFailure (SpoolFailure 4 "lease is unknown or stale"))
      (record, _) <- readResultRecordFile resultPath
      let (ident, _) = reference
      unless (extractTextField "task_id" record == ident
        && extractTextField "worker" record == worker)
        (throwFailure (SpoolFailure 4 "lease belongs to a different worker"))
