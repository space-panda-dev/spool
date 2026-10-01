{-# LANGUAGE OverloadedStrings #-}

-- | A worker's connection to its spool: the five operations the worker
-- needs, however it reaches the spool.  On the spool's host the connection
-- is the directory and its lock.  On another machine it is a transport
-- command, typically ssh to the spool host's dedicated account, speaking the
-- forced command's grammar.  The worker loop cannot tell which it has.
module Spool.Worker.Connection
  ( Connection (..)
  , localConnection
  , remoteConnection
  ) where

import Control.Concurrent.Async (wait, withAsync)
import Control.Exception (bracket, throwIO)
import qualified Data.Aeson as A
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import qualified Data.Text as T
import System.Exit (ExitCode (..))
import System.IO (Handle, IOMode (ReadMode), hClose, openBinaryFile)
import System.Process
  ( CreateProcess (..)
  , StdStream (CreatePipe, Inherit)
  , proc
  , waitForProcess
  , withCreateProcess
  )
import qualified Spool.Attachments as SA
import Spool.Canonical (encode)
import Spool.Error (SpoolError, fromExitStatus, malformed, orThrow, retryable, stale)
import Spool.Files (Paths, attachmentsDir, withLock)
import Spool.Store (ackOne, failLease, leaseUpTo, renewOne)
import Spool.Types (Retry (..), WorkerName)
import Spool.Wire
  ( Ack (..)
  , Answer (..)
  , FailRequest (..)
  , FetchRequest (..)
  , Lease
  , LeaseRef (..)
  , parseAnswer
  , parseLease
  )

data Connection = Connection
  { leaseOne :: IO (Maybe Lease)
    -- ^ One pending task, or nothing when nothing is pending.
  , renewLease :: LeaseRef -> IO (Either SpoolError ())
  , ackLease :: LeaseRef -> A.Value -> IO (Either SpoolError ())
  , failLeaseWith :: LeaseRef -> T.Text -> Retry -> IO (Either SpoolError ())
  , withAttachment :: LeaseRef -> SA.Attachment -> (Handle -> IO ()) -> IO ()
    -- ^ Run an action on a handle that reads the attachment's bytes.
  }

-- | The spool in a directory on this machine.  Each operation is one
-- transition under the spool's lock, so no program runs while it is held.
localConnection :: Paths -> WorkerName -> Connection
localConnection paths worker = Connection
  { leaseOne = do
      leased <- withLock paths (leaseUpTo paths worker 1)
      pure $ case leased of
        lease : _ -> Just lease
        [] -> Nothing
  , renewLease = withLock paths . renewOne paths
  , ackLease = \reference output ->
      fmap (const ()) <$> withLock paths (ackOne paths reference output)
  , failLeaseWith = \reference reason retry ->
      withLock paths (failLease paths reference reason retry)
  , withAttachment = \(LeaseRef ident _) attachment action ->
      bracket
        (openBinaryFile (SA.attachmentPath (attachmentsDir paths) ident attachment) ReadMode)
        hClose action
  }

-- | A spool on another machine, reached by running this program with these
-- arguments and one remote word more for each request.  What the spool
-- answers on stdout is read back; what it says on stderr passes through to
-- the worker's own; its exit status is the failure it names, and a status
-- the protocol does not name is the transport's own failure.
remoteConnection :: FilePath -> [String] -> Connection
remoteConnection program arguments = Connection
  { leaseOne = do
      (status, output) <- request "lease" BL.empty
      case status of
        ExitFailure 1 -> pure Nothing
        _ -> do
          failed status
          case BLC.lines output of
            [line] -> Just <$> orThrow malformed (parseLease line)
            _ -> throwIO (malformed "lease answered with other than one line")
  , renewLease = \reference -> answered "renew" (encode reference)
  , ackLease = \reference output -> answered "ack" (encode (Ack reference output))
  , failLeaseWith = \reference reason retry ->
      answered (case retry of Retry -> "fail"; NoRetry -> "fail --no-retry")
        (encode (FailRequest reference reason))
  , withAttachment = \reference attachment action ->
      withCreateProcess (speaking "fetch") $ \toSpool fromSpool _ handle -> do
        (writing, reading) <- pipes toSpool fromSpool
        withAsync (feed writing (encode (FetchRequest reference (SA.attachmentSha256 attachment)))) $
          \feeding -> do
            action reading
            wait feeding
        waitForProcess handle >>= failed
  }
  where
    speaking word = (proc program (arguments <> [word]))
      { std_in = CreatePipe, std_out = CreatePipe, std_err = Inherit }

    feed writing line = BL.hPut writing (line <> "\n") >> hClose writing

    pipes (Just writing) (Just reading) = pure (writing, reading)
    pipes _ _ = throwIO (retryable "the transport was started without its pipes")

    -- One request with these lines; the exit status and what came back.
    request :: String -> BL.ByteString -> IO (ExitCode, BL.ByteString)
    request word input =
      withCreateProcess (speaking word) $ \toSpool fromSpool _ handle -> do
        (writing, reading) <- pipes toSpool fromSpool
        withAsync (BL.hPut writing input >> hClose writing) $ \feeding ->
          withAsync (BS.hGetContents reading) $ \collecting -> do
            output <- wait collecting
            wait feeding
            status <- waitForProcess handle
            pure (status, BL.fromStrict output)

    -- A transition on one lease: the one answer line says what became of it.
    answered :: String -> BL.ByteString -> IO (Either SpoolError ())
    answered word line = do
      (status, output) <- request word (line <> "\n")
      case BLC.lines output of
        [answerLine] -> do
          answer <- orThrow malformed (parseAnswer answerLine)
          pure $ if answerStatus answer == "stale"
            then Left (stale "lease is stale")
            else Right ()
        _ -> do
          failed status
          throwIO (malformed "the spool answered with other than one line")

    -- A status other than success is the failure the spool named, or the
    -- transport's own.
    failed :: ExitCode -> IO ()
    failed ExitSuccess = pure ()
    failed (ExitFailure status) =
      throwIO $ case fromExitStatus status "the spool refused the request" of
        Just failure -> failure
        Nothing -> retryable
          ("transport " <> unwords (program : arguments) <> " exited " <> show status)
