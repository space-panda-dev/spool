{-# LANGUAGE OverloadedStrings #-}

-- | Pure validation and rendering for the SSH access boundary.
--
-- This module deliberately does not read the environment, open files, or
-- execute commands.  The executable wires these values into its filesystem
-- transitions; keeping the byte grammar and record shapes here makes the
-- trust boundary testable without an SSH server.
module Spool.Access
  ( Grant
  , grantId
  , grantPeer
  , grantWorker
  , grantSpool
  , grantPublicKey
  , grantExpiresAt
  , GrantId
  , mkGrantId
  , grantIdText
  , PublicKey
  , mkPublicKey
  , publicKeyText
  , RemoteCommand (..)
  , grantRecordPath
  , filterManagedGrantLine
  , parseGrantJSON
  , parseRemoteCommand
  , renderGrant
  , renderManagedAuthorizedKeyLine
  , validateGrant
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), (.:), (.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteArray.Encoding as BAE
import Data.List (isSuffixOf, sort)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (UTCTime, defaultTimeLocale, formatTime, parseTimeM)
import System.FilePath (isAbsolute, normalise, splitDirectories, (</>))
import Spool.Canonical (encode)
import Spool.Types (Retry (..), WorkerName, mkWorkerName, validatePeer)

-- | @grant_@ and then 32 lower-case hexadecimal characters.
newtype GrantId = GrantId T.Text
  deriving (Eq, Ord, Show)

mkGrantId :: T.Text -> Either String GrantId
mkGrantId value
  | T.length value /= 38 = Left "grant_id must be grant_ followed by 32 lower-case hex characters"
  | not ("grant_" `T.isPrefixOf` value) = Left "grant_id must start with grant_"
  | not (T.all isLowerHex (T.drop 6 value)) = Left "grant_id must use lower-case hexadecimal"
  | otherwise = Right (GrantId value)
  where
    isLowerHex character = character `elem` (['0' .. '9'] <> ['a' .. 'f'])

grantIdText :: GrantId -> T.Text
grantIdText (GrantId value) = value

instance ToJSON GrantId where
  toJSON = toJSON . grantIdText

-- | The canonical two-word OpenSSH public-key form.  Comments and options are
-- intentionally excluded: the complete key is inserted into a managed line by
-- this module.
newtype PublicKey = PublicKey T.Text
  deriving (Eq, Ord, Show)

mkPublicKey :: T.Text -> Either String PublicKey
mkPublicKey value = case T.splitOn " " value of
  [keyType, encoded]
    | T.length keyType <= 128
        && validKeyType keyType
        && validBase64 encoded -> case
            (BAE.convertFromBase BAE.Base64 (TE.encodeUtf8 encoded)
              :: Either String BS.ByteString) of
          Right decoded
            | TE.decodeUtf8' (keyBlobType decoded) == Right keyType
                && not (BS.null (keyBlobBody decoded))
                && TE.decodeUtf8 (BAE.convertToBase BAE.Base64 decoded) == encoded ->
                  Right (PublicKey value)
          _ -> Left "public_key contains invalid base64"
  _ -> Left "public_key must be one OpenSSH key type and one base64 blob"
  where
    validKeyType keyType =
      ("ssh-" `T.isPrefixOf` keyType || "ecdsa-" `T.isPrefixOf` keyType || "sk-" `T.isPrefixOf` keyType)
        && T.all isKeyTypeChar keyType
    isKeyTypeChar character =
      character `elem` (['A' .. 'Z'] <> ['a' .. 'z'] <> ['0' .. '9'] <> "-_")
    validBase64 encoded =
      not (T.null encoded)
        && T.all isBase64Char encoded
        && let padding = T.length (T.takeWhileEnd (== '=') encoded)
               body = T.take (T.length encoded - padding) encoded
           in padding <= 2
                && not (T.null body)
                && T.all (/= '=') body
                && T.length body `mod` 4 /= 1
    isBase64Char character =
      character `elem` (['A' .. 'Z'] <> ['a' .. 'z'] <> ['0' .. '9'] <> "+/=")
    keyBlobType bytes
      | BS.length bytes < 4 = BS.empty
      | declared > BS.length bytes - 4 = BS.empty
      | otherwise = BS.take declared (BS.drop 4 bytes)
      where
        declared = decodeLength (BS.take 4 bytes)
    keyBlobBody bytes
      | BS.length bytes < 4 = BS.empty
      | declared > BS.length bytes - 4 = BS.empty
      | otherwise = BS.drop (4 + declared) bytes
      where
        declared = decodeLength (BS.take 4 bytes)
    decodeLength = BS.foldl' (\total byte -> total * 256 + fromIntegral byte) 0

publicKeyText :: PublicKey -> T.Text
publicKeyText (PublicKey value) = value

instance ToJSON PublicKey where
  toJSON = toJSON . publicKeyText

-- | A grant is the complete, trusted input to the forced command.  The
-- 'grantExpiresAt' field is 'Nothing' for a grant that does not expire.  The
-- only way to make one is 'validateGrant', so every grant has passed it.
data Grant = Grant
  { grantId :: GrantId
  , grantPeer :: T.Text
  , grantWorker :: WorkerName
  , grantSpool :: FilePath
  , grantPublicKey :: PublicKey
  , grantExpiresAt :: Maybe UTCTime
  } deriving (Eq, Show)

-- | The only operations accepted through a managed SSH key.
data RemoteCommand
  = RemoteLease (Maybe Integer)
  | RemoteAck
  | RemoteRenew
  | RemoteFail Retry
  | RemoteFetch
  deriving (Eq, Show)

grantKeys :: [T.Text]
grantKeys = sort
  [ "grant_id"
  , "peer"
  , "worker"
  , "spool"
  , "public_key"
  , "expires_at"
  ]

-- | The record as the bytes of one atomic file, in canonical form.
renderGrant :: Grant -> BS.ByteString
renderGrant = BL.toStrict . encode

instance ToJSON Grant where
  toJSON grant = A.object
    [ "grant_id" .= grantId grant
    , "peer" .= grantPeer grant
    , "worker" .= grantWorker grant
    , "spool" .= grantSpool grant
    , "public_key" .= grantPublicKey grant
    , "expires_at" .= fmap renderExpiry (grantExpiresAt grant)
    ]
    where
      renderExpiry :: UTCTime -> T.Text
      renderExpiry = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ"

instance FromJSON Grant where
  parseJSON = A.withObject "grant" $ \object -> do
    let actual = sort (map K.toText (KM.keys object))
    if actual /= grantKeys
      then fail "grant must contain exactly grant_id, peer, worker, spool, public_key, expires_at"
      else do
        identifier <- object .: "grant_id"
        peer <- object .: "peer"
        worker <- object .: "worker"
        spool <- object .: "spool"
        publicKey <- object .: "public_key"
        expiry <- object .: "expires_at"
        case validateGrant identifier peer worker spool publicKey expiry of
          Left message -> fail message
          Right grant -> pure grant

-- | Decode and validate one complete grant record.  Unknown or missing keys
-- are rejected before any value is used.
parseGrantJSON :: BS.ByteString -> Either String Grant
parseGrantJSON = A.eitherDecodeStrict'

-- | Make a grant from its fields as they were given, checking each in the
-- order a record lists them.  The fields arrive as text because this is
-- where they stop being text.
validateGrant
  :: T.Text
  -> T.Text
  -> T.Text
  -> FilePath
  -> T.Text
  -> Maybe T.Text
  -> Either String Grant
validateGrant identifierText peer workerText spool publicKeyValue expiryText = do
  identifier <- mkGrantId identifierText
  validatePeer peer
  worker <- mkWorkerName workerText
  validateGrantSpool spool
  publicKey <- mkPublicKey publicKeyValue
  expiry <- case expiryText of
    Nothing -> Right Nothing
    Just text -> Just <$> parseExpiry text
  pure Grant
    { grantId = identifier
    , grantPeer = peer
    , grantWorker = worker
    , grantSpool = spool
    , grantPublicKey = publicKey
    , grantExpiresAt = expiry
    }

parseExpiry :: T.Text -> Either String UTCTime
parseExpiry text = case parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" (T.unpack text) of
  Nothing -> Left "expires_at must be a UTC RFC3339 timestamp ending in Z"
  Just value -> Right value

-- | A record stores a canonical absolute path, not a path that will be
-- normalised differently when the forced command later reads it.
validateGrantSpool :: FilePath -> Either String ()
validateGrantSpool value
  | not (isCanonicalPath value) = Left "spool must be a canonical absolute path"
  | otherwise = Right ()

isCanonicalPath :: FilePath -> Bool
isCanonicalPath value =
  not (null value)
    && isAbsolute value
    && '\0' `notElem` value
    && normalise value == value
    && all (/= "..") (splitDirectories value)
    && all (/= ".") (splitDirectories value)
    && (value == "/" || not ("/" `isSuffixOf` value))

-- | The record's path beneath a grants directory.  The identifier's grammar
-- admits no separator, so it cannot leave the directory.
grantRecordPath :: FilePath -> GrantId -> Either String FilePath
grantRecordPath grantsDirectory identifier
  | null grantsDirectory || '\0' `elem` grantsDirectory =
      Left "grants directory must be non-empty and contain no NUL"
  | otherwise =
      Right (grantsDirectory </> T.unpack (grantIdText identifier) <> ".json")

-- | What marks a line of authorized_keys as this grant's.
managedGrantMarker :: GrantId -> T.Text
managedGrantMarker identifier = "spool-grant:" <> grantIdText identifier

-- | Remove exactly the line carrying a particular managed marker while
-- preserving every other byte, including line endings and comments.
filterManagedGrantLine :: GrantId -> BS.ByteString -> BS.ByteString
filterManagedGrantLine identifier bytes =
  let markerBytes = TE.encodeUtf8 (" " <> managedGrantMarker identifier)
      chunks = BS.split 10 bytes
      keep chunk = not (markerBytes `BS.isSuffixOf` chunk)
  in BS.intercalate "\n" (filter keep chunks)

-- | Render one managed authorized_keys line.  The executable is shell-quoted
-- as a word and then escaped for the OpenSSH option's double quotes.  The
-- line is UTF-8, so an executable whose path is not ASCII keeps its name.
renderManagedAuthorizedKeyLine :: FilePath -> Grant -> Either String BS.ByteString
renderManagedAuthorizedKeyLine executable grant
  | not (isCanonicalPath executable) =
      Left "spool executable must be a canonical absolute path"
  | otherwise =
      let identifier = grantIdText (grantId grant)
          command = shellQuote executable <> " remote --grant " <> T.unpack identifier
          option = "restrict,command=\"" <> escapeOption command <> "\" "
          line = option <> T.unpack (publicKeyText (grantPublicKey grant)) <> " "
            <> T.unpack (managedGrantMarker (grantId grant)) <> "\n"
      in Right (TE.encodeUtf8 (T.pack line))
  where
    shellQuote path
      | all isSafeShellChar path = path
      | otherwise = "'" <> concatMap quoteSingle path <> "'"
    quoteSingle '\'' = "'\"'\"'"
    quoteSingle character = [character]
    isSafeShellChar character = character `elem` (['A' .. 'Z'] <> ['a' .. 'z'] <> ['0' .. '9'] <> "_@%+=:,./-")
    escapeOption [] = []
    escapeOption ('\\' : rest) = "\\\\" <> escapeOption rest
    escapeOption ('"' : rest) = "\\\"" <> escapeOption rest
    escapeOption (character : rest) = character : escapeOption rest

-- | The byte-level grammar for SSH_ORIGINAL_COMMAND.  No text decoder or
-- shell tokenizer is involved, so malformed UTF-8 and NULs are rejected at
-- the boundary.
parseRemoteCommand :: BS.ByteString -> Either String RemoteCommand
parseRemoteCommand bytes
  | BS.length bytes > 64 = Left "remote command is longer than 64 bytes"
  | not (BS.all isPrintableAscii bytes) = Left "remote command must be printable ASCII"
  | bytes == "lease" = Right (RemoteLease Nothing)
  | bytes == "ack" = Right RemoteAck
  | bytes == "renew" = Right RemoteRenew
  | bytes == "fail" = Right (RemoteFail Retry)
  | bytes == "fail --no-retry" = Right (RemoteFail NoRetry)
  | bytes == "fetch" = Right RemoteFetch
  | Just suffix <- BS.stripPrefix "lease --count " bytes = do
      count <- parseCount suffix
      pure (RemoteLease (Just count))
  | otherwise = Left "unknown remote command"
  where
    isPrintableAscii byte = byte >= 0x20 && byte <= 0x7e
    parseCount value
      | BS.null value = Left "lease count is missing"
      | BS.length value > 19 = Left "lease count is too large"
      | BS.length value > 1 && BS.head value == 0x30 = Left "lease count has a leading zero"
      | not (BS.all (\byte -> byte >= 0x30 && byte <= 0x39) value) = Left "lease count must be decimal"
      | otherwise =
          let number = BS.foldl' (\total byte -> total * 10 + toInteger (byte - 0x30)) 0 value
          in if number >= 1 && number <= 9223372036854775807
               then Right number
               else Left "lease count is outside the permitted range"
