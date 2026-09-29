# 0001. A pull protocol with one reference implementation

Status: accepted

Work sometimes has to outlive the process that asked for it: a long
enrichment, a batch on a friend's machine, a job whose worker may crash. The
predecessor project built this twice. Its first system pushed jobs to peers
over HTTP; its task spool let workers pull from a directory of files, and the
spool was simpler and had better properties.

## Decision

**Spool is a protocol.** The task envelope, the states a task moves through
(pending, leased, done, failed), the commands that move it, and their exit
codes are specified in [the protocol](../../spec/protocol.md), which is CC0 so
a worker or a spool can be written in any language. This repository holds the
specification and one reference implementation.

**Workers pull.** A spool lives with whoever asks for the work. A worker leases
a task, runs it, and acknowledges or fails it. A lease that goes quiet is
reclaimed and the task offered again. Pulling means a worker takes only what it
can handle, a crashed worker costs nothing but a reclaim, and the side that
asks for work never needs a way into anyone else's machine.

**Leases are fenced.** A lease's ID is part of its filename, so once a lease is
reclaimed or resolved its holder can no longer act. Putting an equal task twice
and acknowledging twice are no-ops.

**The reference implementation keeps the predecessor's mechanism.** It is
Haskell, built as a static binary, storing tasks as files moved by atomic
renames under a lock held only for one transition at a time. No daemon: a timer
or the caller drives it.

**A spool is coordination, not a record.** Its done and failed directories are
a retry ledger. Whoever asked for the work turns results into whatever lasting
record they need.

## Rejected

- **Push, as the predecessor's federation did.** The requester needs a way into
  the worker's machine and has to guess its capacity; a crash mid-dispatch
  leaves both sides unsure who holds the job.
- **A program with no specification.** Its behaviour would be the only
  definition, and friends could run only this implementation.
- **A database or queue server.** Files and renames already give atomic
  transitions and fencing, with nothing to run.
