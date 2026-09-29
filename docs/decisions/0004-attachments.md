# 0004. Attachments live and die with their task

Status: accepted

Some work needs bytes: matching cover songs needs the audio. Putting bytes
inline in a JSON payload bloats it and caps its size awkwardly. The
predecessor's federation staged uploads per job but never deleted them, so
every friend's machine kept a growing copy of everything it had been sent.

## Decision

**A task may carry attachments.** Each is a file named by its SHA-256 and size,
staged in the spool with the task. A worker fetches a task's attachments over
the same transport as the task, verifies each digest, and hands them to the
capability as local paths.

**They live only as long as the task.** When a task is done, or failed without
retry, its attachments are deleted from the spool, and the worker deletes its
copies once the program exits. A retried task keeps them until it resolves.
The spool's deletion is guaranteed; the worker's is attempted, and a crash, a
snapshot, or a dishonest worker can defeat it.

**Spool is not a store.** Nothing is cached between tasks. If sending the same
bytes repeatedly costs too much, keeping a copy on the worker's machine is the
caller's deliberate choice, made outside Spool.

**Deletion on a worker is its owner's promise.** A caller that governs
disclosure must still count a worker's machine as somewhere a copy may survive.

## Rejected

- **Bytes inline in the payload.** JSON grows by a third and every size limit
  becomes a payload limit.
- **Workers fetching from the caller's storage.** It hands a peer access to far
  more than one task's files.
- **A cache on the worker.** A store nobody designed, holding other people's
  content indefinitely.
