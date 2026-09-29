# Spool protocol

Version: 0.0.1
Status: draft

The protocol a spool and its workers follow. It is dedicated to the public
domain under CC0 1.0: anyone may implement it. The version above must match
[`VERSION`](VERSION). Most of it is carried over from the predecessor's task
spool, where it was tested on one machine; the parts marked provisional are
not settled.

## Tasks

A task is one JSON object with exactly these fields:

```json
{"task_id":"task-one","capability":"classify@1","payload":{"anything":"opaque"}}
```

- `task_id`: ASCII letters, digits, `.`, `_`, and `-`; `--` is reserved.
- `capability`: `name@version`, where `name` matches `[A-Za-z0-9._-]+` and
  `version` matches `[A-Za-z0-9.]+`. Only the grammar is checked.
- `payload`: any JSON value, including null. Never interpreted.

### Attachments (proposed)

The draft defined by
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
  or, with `--no-retry`, moves it to failed.
- `reclaim --older-than SECONDS` returns to pending every lease whose later of
  lease time and last renewal is older than that. The old lease ID is dead.

A lease ID that is not the task's current lease acts on nothing.

## Commands

Every command takes an explicit spool directory. Input and output are JSONL,
except the proposed `fetch` command writes one raw byte stream.

```sh
spool --dir DIR init
spool --dir DIR put < tasks.jsonl
spool --dir DIR put --attachments ATTACHMENT_DIR < tasks.jsonl  # proposed
spool --dir DIR lease --worker WORKER [--count N]
spool --dir DIR ack < acknowledgements.jsonl
spool --dir DIR renew < renewals.jsonl
spool --dir DIR fail [--no-retry] < failures.jsonl
spool --dir DIR failures
spool --dir DIR results
spool --dir DIR fetch < attachment-request.json > attachment  # proposed
spool --dir DIR reclaim --older-than SECONDS
spool --dir DIR status [--json]
spool --dir DIR work --worker WORKER --config FILE [--max-tasks N]
spool work --config FILE --show
```

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

### `fetch` (proposed)

`fetch` accepts exactly one JSON object:

```json
{"task_id":"task-one","lease_id":"lease_...","sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}
```

The task and lease must be current and the digest must be declared by that
task. The spool verifies the stored bytes against both the declared SHA-256
and size before writing the raw bytes to stdout. Diagnostics use stderr. The
receiver verifies digest and size again before exposing the file. Ranges,
resumption, paths, and multiple requests in one invocation are unsupported.

`grant`, `revoke`, and the remote command used over SSH are provisional
([ADR 0003](../docs/decisions/0003-ssh-first.md)).

## Exit codes

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | `lease`: no pending task |
| 2 | malformed input |
| 3 | task conflict |
| 4 | stale or unknown lease |
| 70 | corrupt durable state |
| 75 | retryable filesystem failure |

## Workers

`work` runs leased tasks with programs its owner configured. Each capability
names an absolute executable, optional arguments, a timeout, and a payload
limit; the configuration also sets the concurrency limit, the renew interval,
and the complete environment a program receives. A program gets the payload on
stdin in a fresh temporary directory. Exit 0 with JSON on stdout is a result;
anything else is a failure, retried unless the capability was unknown or the
payload too large. `work` acknowledges with that result.

Under the proposed attachment draft, `work` fetches and verifies every
declared attachment into `attachments/SHA256` below the fresh working
directory before starting the capability. It attempts to delete that entire
directory after the program exits. The spool keeps attachments across retry
and reclaim, and deletes them when `ack` or `fail --no-retry` resolves the
task.
