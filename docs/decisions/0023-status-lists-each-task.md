# 0023. Status lists each task pending or leased

Status: accepted

`status` counts ([ADR 0009](0009-status-counts-coordination-records.md)).
A caller that puts work and waits for it cannot learn from counts whether a
worker holds its task, so it guesses from how long the result has taken.
The archive's backfill guessed wrong six times on 2026-10-20: it declared the
Mac worker absent, ran the work on the laptop too, and left the task on the
spool, while the Mac was busy and reachable. Until now the backfill read the
spool's files directly, a stopgap that knows the layout.

The operator asked for this on 2026-10-21.

## Decision

**`status --json --tasks` writes one line for each task pending or
leased.** Pending tasks come first, in the order they will be leased
([ADR 0024](0024-leases-follow-put-order-and-priority.md)), then leased
ones, in the order they were leased:

```json
{"task_id":"t1","state":"pending","priority":0}
{"task_id":"t2","state":"leased","priority":0,"lease_id":"lease_...","worker":"mac","leased_at":"2026-10-21T00:00:00Z","renewed_at":"2026-10-21T00:05:00Z"}
```

`renewed_at` is the last renewal, or `leased_at` if there has been none.
`worker` is null for a lease never handed to a worker, which only a crash
between the lease and its sidecar leaves. Times are to the second, as every
time Spool writes. No payload, attachment, or result is listed: this is the
queue's state, not its contents. A task withdrawn, done, or failed is not
listed.

**It is a remote word for a grant that may put**, exactly
`status --json --tasks`, as `status` is
([ADR 0016](0016-a-grant-that-may-put-may-read-what-came-of-it.md)).
Locally, `status --tasks --json` is accepted too.

### Details the implementer decided, for the operator to confirm

1. The form needs `--json`; `status --tasks` alone is malformed input,
   since there is no text form to give it.
2. `priority` is always written, 0 included, so a reader need not know the
   default.

## Rejected

- **Adding the lines to `status --json`.** It answers one object today, and
  a reader that parses one object would break.
- **Reading the spool's files.** It ties every caller to a layout that is
  the implementation's, not the protocol's, and it needs to share the host.
- **Listing payloads.** A caller that put the task has it; a listing that
  carried it would grow with every payload.
