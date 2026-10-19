# 0020. A result may carry attachments

Status: accepted

A task's bytes reach a worker as attachments
([ADR 0004](0004-attachments.md), [ADR 0005](0005-attachment-declaration-and-fetch.md)),
and a result comes back as JSON, small enough to be one line of a record.
Archive now wants the Mac's GPU to separate stems for tracks queued on the
ThinkPad's spool. The audio travels to the Mac as an attachment; the four
stems of a track, 100 to 200 MB of FLAC, have no way back. The open question
of how large results are returned has its real need.

The operator decided on 2026-10-18: a program names its output files by
digest, as its inputs arrive; a capability produces files only if its owner
opts in; a grant limits the bytes the spool holds from it, so a worker on
someone else's machine cannot fill the spool host's disk; and both machines
upgrade together, so a result without files stays what it was.

## Decision

**A program leaves its files in `outputs/`.** Each file a run is to send
back is a regular file in `outputs/` below its working directory, named by
its own lower-case SHA-256, as each attachment of its task arrives at
`attachments/SHA256`. Spool carries no file name and does not read the
result: a result that needs to say which file is which names them by digest
([INV-1](../invariants.md)). The worker looks at every entry without
following it. An entry that is not a regular file, a symbolic link above all,
a file whose name is not a digest, and a file whose bytes do not hash to its
name each fail the run for good, as exit 65 does: the program broke the rule,
and running it again will not mend it.

**A capability opts in.** A capability's configuration gains
`max_result_attachment_bytes`, the most bytes a run's outputs may hold
together. A capability without it may leave nothing in `outputs/`; a run
that does is failed without retry, and so is a run whose outputs are larger
than the limit. Only what an owner chose to send back is sent.

**The worker sends each file over its own connection.** The spool never
reaches a worker ([INV-2](../invariants.md)). After the program exits 0 with
JSON, while the lease is still renewed, the worker sends each file with a
new request, `send`: one line `{"task_id","lease_id","sha256","size"}`, then
exactly `size` bytes, then the end of the stream. One request is one file;
there is no path, range, or offset, as for `fetch`. Locally the worker's
connection copies the file in the same way.

**No lock is held while bytes move.** A send takes the lock to check that
the lease is in flight and the sender's, and that its grant has room, and
to make a temporary file under the lease's staging directory. It copies,
counts, hashes, and syncs the bytes with the lock let go. It takes the lock
again to check that the lease still stands, and gives the file its digest
for a name. A recent bug held the lock across program runs and serialized a
worker; bytes from another machine take longer than any program.

**The ack names them, and is the commit.** `ack` gains an optional
`attachments` array, sorted and unique, beside `result`. Every file it names
must be staged whole under its lease, or the ack is malformed input and
nothing is done. The result record carries the array, and writing it is the
commit ([ADR 0013](0013-the-record-commits-and-recovery-finishes.md)): the
steps after it file the attachments under the done task's ID, as
[ADR 0018](0018-finished-work-is-collected-or-ages-out.md) files the done
task, and recovery finishes them after a crash. An equal ack repeated is
`already_done`; one naming other attachments is `stale`, as one with another
result is.

**Whoever reads the result may take them.** `results` lists `attachments`
with a result that has them. A new command, `take`, reads one request
`{"task_id","sha256"}` and writes the bytes of that attachment of a done
task, verified against its digest and size before any is written, as
`fetch` does. Through the remote command it is for a grant that may put,
as `results` and `collect` are
([ADR 0016](0016-a-grant-that-may-put-may-read-what-came-of-it.md)).

**They live as long as the done task.** `collect` and `gc` delete a done
task's result attachments with it, under the same marker. A lease that ends
without a result, by `fail`, by reclaim, or by revoke, deletes what it
staged. [INV-8](../invariants.md) now says so.

**A grant limits what the spool holds from it.** A grant record gains
`max_result_bytes`: the bytes of result attachments the spool holds from that
grant at once, counting those staged and being sent under its leases and
those of its results not yet collected or expired. `grant --max-result-bytes
N` sets it. A record without the field, as every grant was, holds 0: that
grant may send no result attachment, and works as before for tasks without
them. A send that would go over is refused with a new exit status, 6, and
the worker fails that lease with retry, says why, and goes on. A worker on
the spool's host has no grant and no limit.
[ADR 0006](0006-grants-are-account-records.md) says a grant holds no limits:
those on what runs, and on what is disclosed, still belong to the worker's
owner and the caller. This one is neither. It is a limit on the spool host's
disk, which only the host can keep, so it is the grant's.

**Nothing changes for a result without files.** The field is written only
when it is not empty, on an ack and in a result record, so a result without
files is the bytes 0.0.3 wrote, and an older binary meets the field only on a
result that has files. A spool that does not know `send` refuses it as
malformed input, and the worker ends with that status without acknowledging:
it never acks a result whose files did not arrive. The protocol and the
binary are 0.0.4.

Remote `put` with attachments is still exit 2, and still an
[open question](../open-questions.md). `send` names a lease, so it could not
carry them as it is; a request naming a task to be put would be another
word.

`fetch` follows the same rule. It held the lock while it wrote a task's
attachment, so a large file sent to a slow reader stopped every other
command on the spool; it now opens the file under the lock and writes it
after letting go, as `take` does.

### Details the implementer decided, confirmed by the operator on 2026-10-18

1. A refused `outputs/`, and outputs over `max_result_attachment_bytes`, are
   failed without retry. The second could instead be retried as output past
   `max_output_bytes` is; it is final here because, like a payload over
   `max_payload_bytes`, it is what the task makes under this configuration.
2. Exit 6 is new. The worker fails the lease with retry and the reason
   `result attachment SHA256 refused: ...`, which names `max_result_bytes`.
3. A send counts against the limit from its start: its temporary file's name
   carries the size it declared, so sends running at once cannot together
   pass the limit. A send killed midway leaves its temporary file, counted,
   until its lease ends and takes it.
4. An ack naming a file not staged under its lease, or staged with another
   size, is exit 2, checked for every line before any is acted on. The ack
   checks size, not digest: the send hashed the file before it was named,
   and hashing gigabytes under the lock would hold it.
5. Files staged under a lease that its ack does not name are deleted when
   the lease moves to done.
6. `take` of a task that is not done, or of a digest its result does not
   declare, is exit 2. A stored file whose bytes do not match is exit 70, and
   nothing is written. The file is opened under the lock and read after it
   is let go.
7. `send` answers `{"task_id","lease_id","status":"staged"}`. Sending a file
   already staged answers the same and keeps one copy. A request line is at
   most 4096 bytes. A stream shorter or longer than its size, or whose bytes
   do not match its digest, is exit 2, and nothing is kept.
8. `max_result_bytes` is written only when it is not 0, so a grant made
   without the option is the record 0.0.3 wrote. `--max-result-bytes` takes
   1 through 9223372036854775807.
9. The limit counts by the grant's worker name, since that is what a lease
   and a result record keep. A grant revoked and given again to the same name
   inherits what is held under it.
10. `spool --dir DIR send` exists on the host too, with no limit, as `fetch`
    does.
11. The worker sends its files one at a time, after the program has exited
    and before the ack, with its lease renewed throughout.
12. `status` is unchanged.

## Rejected

- **Bytes in the result.** Base64 in JSON grows by a third, and the output
  limit would become a limit on stems.
- **The spool fetching from the worker.** A spool never reaches a worker,
  and a friend's machine is not an address the host should know.
- **Original file names in `outputs/`.** Spool would carry names, with their
  collisions and their paths; a digest is already a name.
- **A manifest of outputs.** A second record of what the directory already
  says.
- **Following links in `outputs/`.** A link can point anywhere the program's
  user can read, and its target is not what the run produced.
- **Holding the lock while bytes move.** One slow upload would stop every
  other worker's renewal.
- **Every file in one request.** Framing many files in one stream invents a
  container format; one request per file keeps `send` the twin of `fetch`.
- **A limit only on the worker.** It is someone else's machine. The disk at
  risk is the spool host's.
- **A limit for the whole spool.** One grant could then use all of it, and
  the owner's own workers would be refused for a friend's files.
- **Checking the limit only when a file is named.** The bytes are on the
  disk by then; several sends at once could each pass.
- **Letting every grant take.** A result attachment is a result; who may
  read one is who may read the other.
