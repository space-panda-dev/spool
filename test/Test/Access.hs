{-# LANGUAGE OverloadedStrings #-}

-- | The SSH boundary.  The shell cannot carry a NUL in SSH_ORIGINAL_COMMAND,
-- so the raw-byte cases live here, where the parser is given the bytes an
-- SSH server can supply.
module Test.Access (tests) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Either (isLeft, isRight)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Spool.Access
  ( Grant
  , GrantId
  , RemoteCommand (..)
  , filterManagedGrantLine
  , grantExpiresAt
  , grantPut
  , grantWorker
  , mkGrantId
  , mkPublicKey
  , parseGrantJSON
  , parseRemoteCommand
  , renderGrant
  , renderManagedAuthorizedKeyLine
  , validateGrant
  )
import Spool.Types (Retry (..), workerNameText)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.QuickCheck (Gen, elements, forAll, listOf, testProperty, vectorOf, (===))

tests :: TestTree
tests = testGroup "access"
  [ testGroup "remote command accepts" (map accepted acceptedCommands)
  , testGroup "remote command rejects" (map rejected rejectedCommands)
  , testGroup "grant record" grantRecord
  , testGroup "managed authorized_keys line" managedLine
  ]

acceptedCommands :: [(BS.ByteString, RemoteCommand)]
acceptedCommands =
  [ ("lease", RemoteLease Nothing)
  , ("lease --count 1", RemoteLease (Just 1))
  , ("lease --count 9223372036854775807", RemoteLease (Just 9223372036854775807))
  , ("ack", RemoteAck)
  , ("renew", RemoteRenew)
  , ("fail", RemoteFail Retry)
  , ("fail --no-retry", RemoteFail NoRetry)
  , ("fetch", RemoteFetch)
  , ("put", RemotePut)
  ]

rejectedCommands :: [(String, BS.ByteString)]
rejectedCommands =
  [ ("empty", "")
  , ("nul", BS.cons 0 "lease")
  , ("malformed utf8", BS.pack [0xff])
  , ("control", BS.pack [0x1f])
  , ("delete", BS.pack [0x7f])
  , ("overlong", BS.replicate 65 0x78)
  , ("leading space", " lease")
  , ("trailing space", "lease ")
  , ("repeated space", "lease  --count 1")
  , ("tab", "lease\t--count\t1")
  , ("newline", "lease\n")
  , ("quoted", "'lease'")
  , ("backslash", "lease\\")
  , ("separator", "lease;status")
  , ("and separator", "lease && status")
  , ("pipeline", "lease | status")
  , ("substitution", "$(status)")
  , ("glob", "lease*")
  , ("option injection", "lease --worker other")
  , ("put with a word", "put --attachments x")
  , ("local results", "results")
  , ("local failures", "failures")
  , ("local status", "status")
  , ("local reclaim", "reclaim --older-than 0")
  , ("local grant", "grant --worker other")
  , ("local revoke", "revoke --grant grant_deadbeef")
  , ("missing count", "lease --count")
  , ("zero count", "lease --count 0")
  , ("leading zero", "lease --count 01")
  , ("signed count", "lease --count +1")
  , ("negative count", "lease --count -1")
  , ("fractional count", "lease --count 1.0")
  , ("count newline", "lease --count 1\n")
  , ("count over maximum", "lease --count 9223372036854775808")
  , ("count too long", "lease --count 111111111111111111111")
  , ("extra word", "lease extra")
  , ("unknown option", "--count 1")
  ]

accepted :: (BS.ByteString, RemoteCommand) -> TestTree
accepted (input, expected) =
  testCase (show input) (parseRemoteCommand input @?= Right expected)

rejected :: (String, BS.ByteString) -> TestTree
rejected (label, input) = testCase label $ case parseRemoteCommand input of
  Left _ -> pure ()
  Right command -> assertFailure ("escaped the parser as " <> show command)

identifierText :: T.Text
identifierText = "grant_0123456789abcdef0123456789abcdef"

identifier :: GrantId
identifier = either error id (mkGrantId identifierText)

publicKey :: T.Text
publicKey =
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

grantWith :: T.Text -> Maybe T.Text -> Either String Grant
grantWith worker = validateGrant identifierText "peer-one" worker "/srv/spool" publicKey False

grantRecord :: [TestTree]
grantRecord =
  [ testCase "a written record reads back as the grant it was written from" $ do
      grant <- either assertFailure pure (grantWith "worker-one" Nothing)
      parseGrantJSON (renderGrant grant) @?= Right grant
  , testCase "an expiry reads back to the same instant" $ do
      grant <- either assertFailure pure
        (grantWith "worker-one" (Just "2026-10-01T00:00:00Z"))
      assertBool "the grant has an expiry" (grantExpiresAt grant /= Nothing)
      parseGrantJSON (renderGrant grant) @?= Right grant
  , testCase "a worker name outside the grammar is refused" $
      assertBool "refused" (isLeft (grantWith "\321" Nothing))
  , testCase "a worker name is read back as it was written" $ do
      grant <- either assertFailure pure (grantWith "worker.two_3-4" Nothing)
      fmap (workerNameText . grantWorker) (parseGrantJSON (renderGrant grant))
        @?= Right "worker.two_3-4"
  , testCase "a peer may be a label with spaces" $
      assertBool "accepted" $ isRight $
        validateGrant identifierText "Alice's laptop" "worker-one" "/srv/spool" publicKey False Nothing
  , testCase "a peer of 129 characters is refused" $
      assertBool "refused" $ isLeft $
        validateGrant identifierText (T.replicate 129 "p") "worker-one" "/srv/spool" publicKey False Nothing
  , testCase "a record is written in canonical form" $ do
      grant <- either assertFailure pure
        (grantWith "worker-one" (Just "2026-10-01T00:00:00Z"))
      renderGrant grant @?= TE.encodeUtf8
        ( "{\"expires_at\":\"2026-10-01T00:00:00Z\",\"grant_id\":\"" <> identifierText
            <> "\",\"peer\":\"peer-one\",\"public_key\":\"" <> publicKey
            <> "\",\"put\":false,\"spool\":\"/srv/spool\",\"worker\":\"worker-one\"}" )
  , testCase "a grant that may put reads back as one that may" $ do
      grant <- either assertFailure pure
        (validateGrant identifierText "peer-one" "worker-one" "/srv/spool" publicKey True Nothing)
      assertBool "may put" (grantPut grant)
      fmap grantPut (parseGrantJSON (renderGrant grant)) @?= Right True
  , testCase "a record without put is refused" $
      assertBool "refused" $ isLeft $ parseGrantJSON
        "{\"grant_id\":\"grant_0123456789abcdef0123456789abcdef\",\"peer\":\"p\",\"worker\":\"w\",\"spool\":\"/s\",\"public_key\":\"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\",\"expires_at\":null}"
  , testCase "an unknown field is refused" $
      assertBool "refused" $ isLeft $ parseGrantJSON
        "{\"grant_id\":\"grant_0123456789abcdef0123456789abcdef\",\"peer\":\"p\",\"worker\":\"w\",\"spool\":\"/s\",\"public_key\":\"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\",\"put\":false,\"expires_at\":null,\"extra\":1}"
  , testCase "a missing field is refused" $
      assertBool "refused" $ isLeft $ parseGrantJSON
        "{\"grant_id\":\"grant_0123456789abcdef0123456789abcdef\",\"peer\":\"p\",\"worker\":\"w\",\"spool\":\"/s\",\"expires_at\":null}"
  , testCase "a relative spool path is refused" $
      assertBool "refused" $ isLeft $
        validateGrant identifierText "peer-one" "worker-one" "srv/spool" publicKey False Nothing
  , testCase "a worker name with a control character is refused" $
      assertBool "refused" (isLeft (grantWith "one\ntwo" Nothing))
  , testCase "a key with a comment is refused" $
      assertBool "refused" (isLeft (mkPublicKey (publicKey <> " someone@host")))
  , testCase "a key whose blob names another type is refused" $
      assertBool "refused" $ isLeft $ mkPublicKey
        (T.replace "ssh-ed25519 " "ssh-rsa " publicKey)
  , testGroup "a grant identifier outside its grammar is refused"
      [ testCase (show text) (assertBool "refused" (isLeft (mkGrantId text)))
      | text <-
          [ ""
          , "grant_"
          , "grant_0123456789abcdef0123456789abcde"
          , "grant_0123456789abcdef0123456789abcdef0"
          , "grant_0123456789ABCDEF0123456789abcdef"
          , "lease_0123456789abcdef0123456789abcdef"
          , "../0123456789abcdef0123456789abcdef01"
          ]
      ]
  ]

managedLine :: [TestTree]
managedLine =
  [ testCase "the line restricts, forces the command, and ends in its marker" $ do
      grant <- either assertFailure pure (grantWith "worker-one" Nothing)
      line <- either assertFailure pure
        (renderManagedAuthorizedKeyLine "/usr/bin/spool" grant)
      line @?= BSC.pack
        ( "restrict,command=\"/usr/bin/spool remote --grant "
            <> T.unpack identifierText <> "\" " <> T.unpack publicKey
            <> " spool-grant:" <> T.unpack identifierText <> "\n" )
  , testCase "an executable whose path is not ASCII keeps its name" $ do
      grant <- either assertFailure pure (grantWith "worker-one" Nothing)
      let executable = "/home/jos\233/bin/spool"
          path = TE.encodeUtf8 (T.pack executable)
      line <- either assertFailure pure
        (renderManagedAuthorizedKeyLine executable grant)
      assertBool "the path holds a character of more than one byte"
        (BS.length path == length executable + 1)
      assertBool "the line holds the path as UTF-8" (path `BS.isInfixOf` line)
  , testCase "a path that is not canonical is refused" $ do
      grant <- either assertFailure pure (grantWith "worker-one" Nothing)
      assertBool "refused" $ isLeft $
        renderManagedAuthorizedKeyLine "/usr/bin/../bin/spool" grant
  , testCase "removing the line leaves every other byte" $ do
      grant <- either assertFailure pure (grantWith "worker-one" Nothing)
      line <- either assertFailure pure
        (renderManagedAuthorizedKeyLine "/usr/bin/spool" grant)
      let before = "# a comment\nssh-ed25519 AAAA someone\n"
          after = "ssh-rsa BBBB other\n"
      assertBool "the line is there to remove" (not (BS.null line))
      filterManagedGrantLine identifier (before <> line <> after) @?= before <> after
  , testProperty "a file without the marker is returned unchanged" $
      forAll unmanagedFile $ \bytes ->
        filterManagedGrantLine identifier bytes === bytes
  ]

-- | Lines of printable ASCII that cannot end in a grant marker, because they
-- never contain a colon.
unmanagedFile :: Gen BS.ByteString
unmanagedFile = do
  count <- elements [0 .. 5 :: Int]
  rows <- vectorOf count (listOf (elements (filter (/= ':') [' ' .. '~'])))
  pure (BSC.pack (concatMap (<> "\n") rows))
