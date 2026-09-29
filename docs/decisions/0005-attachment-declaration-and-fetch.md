# 0005. Declare attachments by digest and fetch one verified stream

Status: accepted

Attachments must cross the task boundary without making payloads non-opaque,
accepting caller paths, or becoming a cache. This proposal supplies the
missing envelope and transfer mechanism beneath
[ADR 0004](0004-attachments.md).

## Decision

A task may have an `attachments` array. Omission means an empty array so old
task records still load; new writers emit the array. Each entry contains
exactly a `sha256` digest and byte `size`. Digests are unique, lower-case, and
sorted. There is no filename or path: the payload may refer to a digest if its
meaning requires one, and Spool does not interpret that reference.

Local `put --attachments DIR` finds source files at `DIR/SHA256`. For every
new task it copies each declared file into that task's spool-owned directory,
computing digest and size while staging, and makes the task pending only after
all declarations match. Equal repeated puts need no source files because they
change nothing. The lease envelope carries the declaration unchanged.

`fetch` accepts exactly one JSON request on stdin and writes that attachment's
raw bytes to stdout. It succeeds only for an attachment declared by the
current task and lease. The spool hashes and counts its copy before writing;
the worker writes to a temporary file, hashes and counts the received bytes,
then renames it to `attachments/SHA256` in the capability's temporary working
directory. There are no paths, ranges, or offsets in a request.

Resolving `ack` or `fail --no-retry` makes the task's attachment directory
unreachable and deletes it before reporting success. A cleanup tombstone makes
an interrupted deletion recoverable on the next invocation. Retry and reclaim
keep the directory. The worker attempts to delete its whole temporary working
directory after every program exit, including failure and timeout; crashes,
snapshots, and dishonest workers remain outside that guarantee as stated by
INV-8.

Spool imposes no attachment quota and does not resume transfers. Filesystem
capacity is the only staging bound. A caller needing quotas or resumption gets
an explicit unsupported error rather than guessed behaviour.

## Rejected

- Inline or base64 bytes: they inflate transfers and turn task or payload
  limits into attachment limits.
- Original filenames or relative paths: they add collision and traversal
  semantics with no protocol need.
- Worker fetches from caller storage: it grants access beyond this task.
- A worker cache: it outlives the task and makes Spool a store.
- Ranges, resumable transfers, or quotas now: no current requirement chooses
  their semantics.
