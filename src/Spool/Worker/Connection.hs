{-# LANGUAGE OverloadedStrings #-}

-- | A worker's connection to its spool: the six operations the worker
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
import Control.Exception (IOException, bracket, displayException, throwIO, try)
import qualified Data.Aeson as A
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import qualified Data.Text as T
import Control.Monad (unless)
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
import Spool.Error
  ( ErrorClass (..)
  , SpoolError (..)
  , fromExitStatus
  , malformed
  , orThrow
  , retryable
  , stale
  )
import Spool.Files (Paths, attachmentsDir, withLock)
import Spool.Store (Sender (..), ackOne, failLease, leaseUpTo, renewOne, sendFrom)
import Spool.Types (Retry (..), WorkerName)
import Spool.Worker.Outputs (openOutput)
import Spool.Wire
  ( Ack (..)
  , Answer (..)
  , FailRequest (..)
  , FetchRequest (..)
  , Lease
  , LeaseRef (..)
  , SendRequest (..)
  , parseAnswer
  , parseLease
  )

data Connection = Connection
  { leaseOne :: IO (Maybe Lease)
    -- ^ One pending task, or nothing when nothing is pending.
  , renewLease :: LeaseRef -> IO (Either SpoolError ())
  , ackLease :: LeaseRef -> A.Value -> [SA.Attachment] -> IO (Either SpoolError ())
    -- ^ The result, and the result attachments sent under the lease.
  , failLeaseWith :: LeaseRef -> T.Text -> Retry -> IO (Either SpoolError ())
  , withAttachment :: LeaseRef -> SA.Attachment -> (Handle -> IO ()) -> IO ()
    -- ^ Run an action on a handle that reads the attachment's bytes.
  , sendResultAttachment :: LeaseRef -> SA.Attachment -> FilePath -> IO (Either SpoolError ())
    -- ^ Send the file at this path as a result attachment under the lease.
    -- A stale lease, or a grant with no room for it now or ever, is
    -- answered; any other refusal is thrown.
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
  , ackLease = \reference output attachments ->
      fmap (const ()) <$> withLock paths (ackOne paths (Ack reference output attachments))
  , failLeaseWith = \reference reason retry ->
      withLock paths (failLease paths reference reason retry)
  , withAttachment = \(LeaseRef ident _) attachment action ->
      bracket
        (openBinaryFile (SA.attachmentPath (attachmentsDir paths) ident attachment) ReadMode)
        hClose action
  , sendResultAttachment = \reference attachment path ->
      bracket (openOutput path) hClose $ \file -> do
        sent <- try (sendFrom paths (pure ()) HostWorker
          (SendRequest reference attachment) BS.empty file)
        either answeredOrThrown (pure . Right) sent
  }

-- | A refusal a send answers: its lease is stale, or its grant has no room
-- for it now, or could never have. Anything else ends the run.
answeredOrThrown :: SpoolError -> IO (Either SpoolError ())
answeredOrThrown refusal = case refusal of
  SpoolError Stale _ -> pure (Left refusal)
  SpoolError OverLimit _ -> pure (Left refusal)
  SpoolError NeverFits _ -> pure (Left refusal)
  _ -> throwIO refusal

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
  , ackLease = \reference output attachments ->
      answered "ack" (encode (Ack reference output attachments))
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
    -- The request line and then the file's bytes. A spool that refuses the
    -- request stops reading it, so a write that fails is looked at only
    -- once the spool's status has said why.
  , sendResultAttachment = \reference attachment path ->
      bracket (openOutput path) hClose $ \file ->
      withCreateProcess (speaking "send") $ \toSpool fromSpool _ handle -> do
        (writing, reading) <- pipes toSpool fromSpool
        let line = encode (SendRequest reference attachment) <> "\n"
        withAsync (try (BL.hPut writing line >> copy file writing >> hClose writing)) $
          \feeding -> withAsync (BS.hGetContents reading) $ \collecting -> do
            output <- wait collecting
            fed <- wait feeding
            status <- waitForProcess handle
            case status of
              ExitFailure code | Just refusal <- fromExitStatus code (refused code) ->
                answeredOrThrown refusal
              _ -> do
                failed status
                either (\exception -> throwIO (retryable ("could not send: "
                  <> displayException (exception :: IOException)))) pure fed
                case BLC.lines (BL.fromStrict output) of
                  [answerLine] -> do
                    answer <- orThrow malformed (parseAnswer answerLine)
                    if answerStatus answer == "staged"
                      then pure (Right ())
                      else throwIO (malformed "send was answered other than staged")
                  _ -> throwIO (malformed "the spool answered with other than one line")
  }
  where
    speaking word = (proc program (arguments <> [word]))
      { std_in = CreatePipe, std_out = CreatePipe, std_err = Inherit
        -- Only those three: not another request's pipes, nor a program's.
      , close_fds = True }

    feed writing line = BL.hPut writing (line <> "\n") >> hClose writing

    copy file writing = do
      chunk <- BS.hGetSome file 65536
      unless (BS.null chunk) (BS.hPut writing chunk >> copy file writing)

    refused 6 = "the spool refused the result attachment: it is over the grant's max_result_bytes"
    refused 7 = "the spool refused the result attachment: it could never fit under the grant's max_result_bytes"
    refused _ = "the spool refused the request"

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
