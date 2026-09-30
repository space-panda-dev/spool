# Spool protocol

Version: 0.0.1
Status: draft

The protocol a spool and its workers follow. It is dedicated to the public
domain under CC0 1.0: anyone may implement it. The version above must match
[`VERSION`](VERSION). Matters that are not settled remain listed in
[`docs/open-questions.md`](../docs/open-questions.md).

## Tasks

A task is one JSON object with exactly the three required fields below and the
optional `attachments` field defined in the next section. New writers include
that field explicitly.

```json
{"task_id":"task-one","capability":"classify@1","payload":{"anything":"opaque"},"attachments":[]}
```

- `task_id`: a name (below); `--` is reserved.
- `capability`: `name@version`, where `name` matches `[A-Za-z0-9._-]+` and
  `version` matches `[A-Za-z0-9.]+`, 1 to 128 characters in all. Only the
  grammar is checked.
- `payload`: any JSON value, including null. Never interpreted.

### Names

Under [ADR 0010](../docs/decisions/0010-names-have-one-grammar-and-a-length.md),
a name is 1 to 128 characters from ASCII letters, digits, `.`, `_`, and `-`.
`task_id` is a name. `worker` is a name of at most 64 characters, wherever it
is given: as an argument, in a grant, in a lease. `peer` is a label for a
person to read: 1 to 128 characters, none of them a control character.

The rule holds wherever the name is read. A name outside it is malformed
input from a caller (exit 2), a denied grant from a peer (exit 5), and
corrupt durable state in the spool's own files (exit 70).

### Attachments

The design defined by
[ADR 0005](../docs/decisions/0005-attachment-declaration-and-fetch.md) adds an
optional `attachments` field. Omission means an empty array; new writers emit
the field explicitly.

```json
{"task_id":"task-one","capability":"classify@1","payload":{"anything":"opaque"},"attachments":[{"sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","size":123}]}
```

Each attachment has exactly `sha256` and `size`. `sha256` is 64 lower-case
hexadecimal characters. `size` is an integer from 0 through
9223372036854775807. Digests are unique and sorted lexicographically. No
filename or path is part of the envelope. A lease carries the same attachment
array unchanged.

For a new task with attachments, `put --attachments DIR` reads each source
from `DIR/SHA256`, computes its digest and size while staging a spool-owned
copy, and commits the task only after every declaration matches. An equal task
already present remains an idempotent no-op and does not require source files.

## States

A task is **pending**, **leased**, **done**, or **failed**.

- `put` makes a task pending. An equal task put again is a no-op; the same ID
  with different content is a conflict.
- `lease` moves a pending task to leased under a new lease ID, naming the
  worker.
- `ack` with that lease ID moves it to done, carrying the task's result: any
  JSON value, `{"task_id", "lease_id", "result"}`. The result is kept with the
  done task until whoever put the task reads it; how long after that is open.
  Repeating an equal ack is a no-op. Repeating the task and lease with a
  different result is a stale-lease error and cannot replace the stored result.
- `renew` with that lease ID keeps the lease from being reclaimed.
- `fail` with that lease ID records a reason and returns the task to pending,
  or, with `--no-retry`, moves it to failed. A lease has at most one failure
  record. Where a record is already stored for a live lease, repeating the
  same reason and retry choice completes the fail; a different reason or
  choice is a stale-lease error and cannot replace the stored record.
- `reclaim --older-than SECONDS` returns to pending every lease whose later of
  lease time and last renewal is older than that. The old lease ID is dead.

A lease ID that is not the task's current lease acts on nothing.

Under [ADR 0011](../docs/decisions/0011-a-lease-id-is-opaque-to-its-holder.md),
a `lease_id` is `lease_` followed by one or more of ASCII letters, digits,
`.`, `_`, and `-`, without `--`, and is at most 200 characters. A worker is
given a `lease_id` and gives it back unchanged; it reads nothing from it. What
follows `lease_` belongs to the spool that made it. A `lease_id` that fits
the grammar and names no lease on file is stale or unknown (exit 4), never
malformed input. `leased_at` is the time the lease was taken, for a worker
that wants it.

## Commands

Every command takes an explicit spool directory. Input and output are JSONL,
except `fetch`, which writes one raw byte stream.

```sh
spool --dir DIR init
spool --dir DIR put < tasks.jsonl
spool --dir DIR put --attachments ATTACHMENT_DIR < tasks.jsonl
spool --dir DIR lease --worker WORKER [--count N]
spool --dir DIR ack < acknowledgements.jsonl
spool --dir DIR renew < renewals.jsonl
spool --dir DIR fail [--no-retry] < failures.jsonl
spool --dir DIR failures
spool --dir DIR results
spool --dir DIR fetch < attachment-request.json > attachment
spool --dir DIR reclaim --older-than SECONDS
spool --dir DIR status [--json]
spool --dir DIR work --worker WORKER --config FILE [--max-tasks N]
spool work --config FILE --show
```

### What a command writes

Every JSON line Spool writes, to stdout or to a file, is canonical: one line,
no space outside a string, and the keys of every object in code point order.
Equal values are therefore equal bytes. The examples in this document list
fields in the order they are easiest to read, which is not that order. Input
may have its keys in any order and any JSON whitespace.

Whatever a command has to say about a failure goes to stderr as text, one
line beginning `spool: `. stderr is for a person; nothing in it is part of
the protocol, and its wording may change.

`put`, `ack`, `renew`, `fail`, and `reclaim` answer on stdout with one line
for each task they acted on, in the order they acted:

```json
{"task_id":"task-one","status":"inserted"}
```

| Command | `status` | Meaning |
|---|---|---|
| `put` | `inserted` | the task is now pending |
| `put` | `existing` | an equal task was already there |
| `ack` | `acked` | the task is now done |
| `ack` | `already_done` | the same acknowledgement had been made |
| `renew` | `renewed` | the lease will not be reclaimed yet |
| `fail` | `failed_retry` | the task is pending again |
| `fail --no-retry` | `failed` | the task is failed |
| `reclaim` | `reclaimed` | the task is pending again and its lease is dead |

`init` answers nothing.

`lease` answers with one line for each task it leased, and exits 1 with no
line when nothing was pending:

```json
{"task_id":"task-one","capability":"classify@1","lease_id":"lease_...","worker":"worker-one","leased_at":"2026-09-29T12:00:00Z","payload":{"anything":"opaque"},"attachments":[]}
```

`ack`, `renew`, and `fail` take one line for each lease:

```json
{"task_id":"task-one","lease_id":"lease_...","result":{"anything":"opaque"}}
{"task_id":"task-one","lease_id":"lease_..."}
{"task_id":"task-one","lease_id":"lease_...","reason":"why"}
```

A line whose lease is stale or unknown gets no line on stdout. The lines
after it are still acted on, and the command then exits 4.

`results` emits one JSON object per acknowledged task, oldest first:

```json
{"task_id":"task-one","lease_id":"lease_...","capability":"classify@1","worker":"worker-one","finished_at":"2026-09-29T12:00:00Z","result":{"anything":"opaque"}}
```

The `result` value is exactly the value carried by `ack`. Spool does not
interpret it.

`failures` emits one JSON object per reported failure, oldest first:

```json
{"task_id":"task-one","lease_id":"lease_...","capability":"classify@1","worker":"worker-one","failed_at":"2026-09-29T12:00:00Z","reason":"exit 3: failed","retried":true}
```

Both record envelopes are validated when read. A missing field, an unknown
field, or a field of the wrong type is corrupt durable state, not an empty
result.

`reclaim` emits one JSON object per task it returned to pending, and nothing
when no lease was old enough:

```json
{"task_id":"task-one","status":"reclaimed"}
```

### `status` counters

Under
[ADR 0009](../docs/decisions/0009-status-counts-coordination-records.md),
`status` counts durable coordination records:

```text
pending=1 leased=0 done=3 failed=2
```

```json
{"pending":1,"leased":0,"done":3,"failed":2}
```

`pending`, `leased`, and `done` count task files in those locations. `failed`
counts every failure record, including retrying failures. These counters are
not an exclusive partition of task IDs. A retrying failure can contribute one
pending task and one or more failed records; its `retried` field distinguishes
that history from terminal failure.

### `fetch`

`fetch` accepts exactly one JSON object:

```json
{"task_id":"task-one","lease_id":"lease_...","sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}
```

The task and lease must be current and the digest must be declared by that
task. The spool verifies the stored bytes against both the declared SHA-256
and size before writing the raw bytes to stdout. Diagnostics use stderr. The
receiver verifies digest and size again before exposing the file. Ranges,
resumption, paths, and multiple requests in one invocation are unsupported.
Malformed requests and undeclared digests are exit 2. An unknown, stale, or
wrong-task lease is exit 4. A stored attachment whose declared digest or size
does not match is corrupt durable state and exit 70. A declaration whose
source bytes do not match during `put` is malformed input and exit 2; source
or staging I/O failure is exit 75.

### Grants

The design defined by
[ADR 0006](../docs/decisions/0006-grants-are-account-records.md) adds:

```sh
spool --dir DIR grant --peer PEER --worker WORKER --key PUBLIC_KEY_FILE [--expires-at RFC3339]
spool --dir DIR revoke --grant GRANT_ID
```

`grant` creates this record, in canonical form, beneath the dedicated
account's `$HOME/.spool/grants/` directory:

```json
{"grant_id":"grant_0123456789abcdef0123456789abcdef","peer":"peer-one","worker":"worker-one","spool":"/absolute/spool","public_key":"ssh-ed25519 AAAA...","expires_at":"2026-10-01T00:00:00Z"}
```

`expires_at` is either a UTC RFC3339 timestamp or null. A grant is expired when
the spool host's `now >= expires_at`. The remote command reads and validates
the record on every request. Grant records contain no execution or disclosure
limits.

`grant` writes one generated `restrict,command="..."` line to the dedicated
account's `$HOME/.ssh/authorized_keys`; `revoke` removes that exact managed
line and preserves unrelated lines. A managed key and worker are unique per
spool. Revocation first disables the record, then removes the line, then
reclaims that worker's live leases. Repeating revoke changes nothing.

On success, `grant` emits its grant record as one JSON line. Reusing an active
public key or worker for the same spool is exit 3. `revoke` emits
`{"grant_id":"GRANT_ID","status":"revoked"}`; the same response is returned
when that grant was already absent. Malformed grant arguments are exit 2 and
account-file I/O failures are exit 75.

The exact forced command and request grammar follow below.

### SSH remote command

The design defined by
[ADR 0007](../docs/decisions/0007-remote-command-is-an-exact-byte-grammar.md)
uses this managed forced command:

```sh
spool remote --grant GRANT_ID
```

The grant record supplies the only spool directory and worker name. The peer
cannot override either one. The remote command checks the grant before every
invocation and checks that each referenced lease belongs to its fixed worker.

`SSH_ORIGINAL_COMMAND` is parsed literally, never by a shell. It is at most 64
ASCII bytes and exactly one of:

```text
lease
lease --count N
ack
renew
fail
fail --no-retry
fetch
```

`N` is decimal from 1 through 9223372036854775807 with no sign or leading
zero. Words use exactly one ASCII space. Empty input, NUL, non-ASCII, control
bytes, other whitespace, shell metacharacters, quoting, escaping, extra words,
and unknown options are malformed input with exit 2.

`lease` uses the grant's worker. `ack`, `renew`, and `fail` carry their local
JSONL stdin and output unchanged after the ownership check. `fetch` accepts
the single JSON request defined above on stdin and writes verified raw bytes to
stdout. Requested command words never contain task IDs, lease IDs, digests,
paths, or a claimed worker.

### Reclaim driver

Under [ADR 0008](../docs/decisions/0008-reclaim-is-caller-driven.md), Spool
starts no daemon, timer, scheduler, or background reclaim loop. A caller on the
spool host invokes the existing command directly; a deployment may arrange the
same invocation through its existing host timer facility.

`--older-than SECONDS` remains required, non-negative, and the sole threshold
configuration. It has no default and is not persisted. A recurring deployment
uses a positive threshold greater than its workers' renewal interval plus the
maximum renewal delay it intends to tolerate. The remote command does not
expose reclaim.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | `lease`: no pending task |
| 2 | malformed input |
| 3 | task conflict |
| 4 | stale or unknown lease |
| 5 | grant missing, revoked, or expired |
| 70 | corrupt durable state |
| 75 | retryable filesystem failure |
| 143 | `work`: stopped by SIGTERM |

## Workers

`work` runs leased tasks with programs its owner configured. Each capability
names an absolute executable, optional arguments, a timeout, a payload limit,
and an output limit; the configuration also sets the concurrency limit, the
renew interval, and the complete environment a program receives. A program
gets the payload on stdin in a fresh temporary directory, in its own process
group. Exit 0 with JSON on stdout is a result; anything else is a failure,
retried unless the capability was unknown or the payload too large. `work`
acknowledges with that result.

Every number in the configuration is a whole number of at least 1. The
concurrency limit and the byte limits may be as large as the host's integers
allow; `renew_seconds` and `timeout_seconds` may be at most 9223372036854. A
number outside its range is malformed input and exit 2; it is never rounded,
wrapped, or clamped.

These are the limits Spool itself enforces on a run: wall-clock time,
concurrent runs, payload bytes accepted, and stdout/stderr bytes captured
(each stream capped independently; past its cap the run is killed and failed,
retried). They bound what Spool does, not what the executable can do to the
machine it runs on: there is no CPU, memory, or file-size containment, and no
namespace or container boundary. A capability owner who needs that wraps
their executable themselves; Spool only guarantees that killing a run reaches
its whole process group, not just the process it exec'd, because a timed-out
or overrun capability may have spawned children of its own.

Killing a run sends its process group SIGTERM. A program may ignore that, so
a run still going 5 seconds later is sent SIGKILL. The limit on wall-clock
time is therefore enforced within `timeout_seconds` plus 5 seconds. The clock
runs from the program's start, while its payload is being written: a program
that does not read its payload is timed out like any other.

A program may exit, or close its input, without reading all of its payload.
That is not a failure; its exit status and its output say how it did.

A run has ended when its program has exited and its output has closed. A
program that exits leaving a process behind, holding its output open, has
not ended: 5 seconds after the program exits, whatever is left of its
process group is sent SIGKILL and the run is a failure, retried.

`work` sent SIGTERM stops: it leases nothing more, every run is killed as
above, each run's working directory is deleted, and `work` exits 143. It
reports nothing for the tasks it was running. Their leases stand, for
`reclaim` to return.

With attachments, `work` fetches and verifies every
declared attachment into `attachments/SHA256` below the fresh working
directory before starting the capability. It attempts to delete that entire
directory after the program exits. The spool keeps attachments across retry
and reclaim, and deletes them when `ack` or `fail --no-retry` resolves the
task.
