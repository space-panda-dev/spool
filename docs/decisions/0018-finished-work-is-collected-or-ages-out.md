# 0018. Finished work is collected, or ages out

Status: accepted

A spool should be long-lived: one per domain, started with the machine, and
never rebuilt. Today it degrades with its history. A done task is never
deleted, so `done/`, `results/`, and `failed/` only grow. `results` answers
every result the spool has ever kept, on every poll. And `put` reads every
done task: a done file is named by the lease that finished it, so the only
way to learn whether a task ID is done is to parse every file in `done/`.
At 550 done tasks a put took 15.6 ms, nearly all of it spent there.

[INV-9](../invariants.md) already says a spool is coordination, not a record:
whatever must last is made from results by whoever asked. Nothing said when
the spool may forget.

The operator decided on 2026-10-15: callers derive task IDs from the
content of the task; finished tasks age out through a command; and whoever
put a task can say they have read what came of it.

## Decision

A finished task is a done task, or a task whose latest failure was final
(`fail --no-retry`). It is kept until whoever put it collects it, or until
it is older than a caller says to keep it. Then the task, its result, and
its whole failure history are deleted together.

### `collect`

`spool --dir DIR collect` reads lines `{"task_id":"..."}` and answers each,
in order, with `{"task_id":"...","status":"..."}`:

- `collected`: the task was finished, and it, its result, and its failure
  records are gone.
- `not_finished`: the task is pending or leased. Nothing is deleted, not even
  the failure records of its earlier attempts.
- `unknown`: the spool holds nothing under that ID, including a task already
  collected.

Every line is read before any is acted on
([ADR 0012](0012-every-line-is-read-first-and-answered.md)). Since `collect`
deletes what it collects, `results` and `failures` list only what has not
been collected, and a caller polling them needs no cursor.

`collect` is a remote word for a grant whose `put` is true, as `results` is
([ADR 0016](0016-a-grant-that-may-put-may-read-what-came-of-it.md)): reading
a result and saying it has been read go together. For any other grant it is
exit 5 and no line is read.

### `gc --older-than SECONDS`

`gc` deletes every finished task that finished at least `SECONDS` ago, and
answers `{"task_id":"...","status":"expired"}` for each, oldest first. A done
task finished at its result's `finished_at`; a failed task at the latest
`failed_at` of its final failures. Pending and leased tasks are never
touched, whatever their history.

Like reclaim ([ADR 0008](0008-reclaim-is-caller-driven.md)), `gc` is
caller-driven: Spool starts no timer, the threshold is required, has no
default, and is not persisted. A deployment runs it from the host's timer
facility. It is not a remote word: a grant collects what it read, and the
spool's owner decides how long the rest is kept.

### The dedupe window is the retention window

An equal task put again while its earlier run is pending, leased, or done is
`existing`, as before ([INV-7](../invariants.md)). Once the task has been
collected or has aged out, the spool no longer knows it, and putting it
again inserts it and runs it again. A caller that needs a task never to run
twice keeps its own record of what it has collected, or does not collect it.

### A done task is filed under its task ID

A done task is `done/TASK_ID.json`, given that name by the rename that
finishes an `ack`. So `put` looks at `pending/TASK_ID.json`,
`done/TASK_ID.json`, and the leases in flight, and never at the done tasks
of other IDs: its cost no longer grows with history.

Result and failure records stay filed under their lease. That keeps the
record as the commit
([ADR 0013](0013-the-record-commits-and-recovery-finishes.md)), and a
repeated `ack` is still answered from `results/LEASE_ID.json` alone. A lease
this spool made is named `lease_MICROS_SERIAL_TASK_ID`, so `collect` and
`gc` find a task's records by listing names, then check that each record
they found names that task. A lease ID is still opaque to its holder
([ADR 0011](0011-a-lease-id-is-opaque-to-its-holder.md)); only the spool
that made it reads it.

### Deleting is committed by a marker, and recovery finishes it

Deleting a task is several removals. Its commit is the creation of an empty
marker `.task-cleanup/TASK_ID`. Then the done file, the result records, the
failure records, and last the marker are removed, each synced
([ADR 0014](0014-durable-means-through-a-power-loss.md)). Recovery, which
runs before every command, finishes every marker it finds, as it does for
an attachment directory set aside for deletion. A crash before the marker
leaves the task whole; a crash after it leaves a deletion the next command
completes. `collect` answers `collected` only after the marker is gone.

### Existing spools are migrated in place

A spool records its layout in `.spool-layout`. When the file is absent, the
next command renames each `done/X.json` whose task's `task_id` is not `X`
to `done/TASK_ID.json`, and then writes the file. What a file holds decides,
not its name, because a task ID may itself look like a lease ID. A migration
interrupted at any point is rerun from the start and finds less to do. A
layout this binary does not know is corrupt state, exit 70.

A binary from before this decision does not read `.spool-layout`, and would
file a done task under its lease again, where `put` and `collect` no longer
look. Running one on a migrated spool is unsupported; how a spool could
refuse it is part of the [open question](../open-questions.md) of how the
protocol is versioned.

### Status

`status` still counts the records a spool holds
([ADR 0009](0009-status-counts-coordination-records.md)); after `collect`
or `gc` it counts fewer.

### Decision details, confirmed by the operator on 2026-10-16

1. `collect` exits 0 when a line is `not_finished` or `unknown`. Those are
   answers about tasks, not a refused lease, and exit 4 belongs to leases.
2. An `ack` repeated after its task was collected is `stale`: the result it
   would be compared with is gone, so it cannot be `already_done`.
3. `gc` reads every result and failure record the spool holds, to find what
   finished when. Its cost grows with what is retained, not with all
   history, and a spool that is collected or aged out stays small.
4. A task whose latest failure was final is still never deduplicated:
   putting it again inserts it, as before this decision. Collecting or
   expiring it deletes its failure history.

## Rejected

- Tombstones, a record of every task ID ever collected so that a repeat put
  is still refused: the spool would keep an ever-growing list of the history
  this decision deletes, and become the archive INV-9 says it is not.
- Delete a result when `results` reads it: reading is not acknowledging. A
  caller that crashes between the read and its own record loses the result.
- A cursor for `results`: it asks the caller to keep state the spool could
  drop, and the spool still keeps everything.
- A retention daemon or a default age: the same reasons reclaim has none
  ([ADR 0008](0008-reclaim-is-caller-driven.md)).
- Rename result and failure records to task IDs too: a task has a failure
  record per attempt, the record is the commit of a lease's transition, and
  a stale ack must still be answered from its own lease's record.
- An index file mapping task IDs to done files: a second record of what the
  file names can say themselves, and one more thing to keep in step.
- Remote `gc`: how long finished work is kept is the spool owner's policy.
