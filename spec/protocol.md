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

Attachments are provisional ([open questions](../docs/open-questions.md)).

## States

A task is **pending**, **leased**, **done**, or **failed**.

- `put` makes a task pending. An equal task put again is a no-op; the same ID
  with different content is a conflict.
- `lease` moves a pending task to leased under a new lease ID, naming the
  worker.
- `ack` with that lease ID moves it to done. Repeating it is a no-op.
- `renew` with that lease ID keeps the lease from being reclaimed.
- `fail` with that lease ID records a reason and returns the task to pending,
  or, with `--no-retry`, moves it to failed.
- `reclaim --older-than SECONDS` returns to pending every lease whose later of
  lease time and last renewal is older than that. The old lease ID is dead.

A lease ID that is not the task's current lease acts on nothing.

## Commands

Every command takes an explicit spool directory. Input and output are JSONL.

```sh
spool --dir DIR init
spool --dir DIR put < tasks.jsonl
spool --dir DIR lease --worker WORKER [--count N]
spool --dir DIR ack < acknowledgements.jsonl
spool --dir DIR renew < renewals.jsonl
spool --dir DIR fail [--no-retry] < failures.jsonl
spool --dir DIR failures
spool --dir DIR results
spool --dir DIR reclaim --older-than SECONDS
spool --dir DIR status [--json]
spool --dir DIR work --worker WORKER --config FILE [--max-tasks N]
spool work --config FILE --show
```

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
| 75 | retryable filesystem failure |

## Workers

`work` runs leased tasks with programs its owner configured. Each capability
names an absolute executable, optional arguments, a timeout, and a payload
limit; the configuration also sets the concurrency limit, the renew interval,
and the complete environment a program receives. A program gets the payload on
stdin in a fresh temporary directory. Exit 0 with JSON on stdout is a result;
anything else is a failure, retried unless the capability was unknown or the
payload too large.
