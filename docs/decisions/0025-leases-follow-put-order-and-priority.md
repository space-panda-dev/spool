# 0025. Leases follow put order, and a task may be put above others

Status: accepted

`lease` takes pending tasks in the order of their file names, which are
their task IDs. When IDs are content hashes, as the archive's are, that
order is random: on 2026-10-20 the Mac worker took tasks the backfill had
given up on hours before ahead of the ones it was waiting for, and the task
put last was leased first because its hash sorted first. Once two callers
share a spool, an ID that sorts low also jumps every queue.

The operator asked for this on 2026-10-21, with a priority so that the
archive can put songs, then recent recordings, then the rest.

## Decision

**A task is leased in the order it was put.** `put` gives each task it
inserts the next number of a sequence the spool keeps, `.put-sequence`, and
writes it into the task's file as `put_serial`. `lease` takes the pending
task with the highest priority, and among those the lowest `put_serial`. A
task put before 0.0.5 has no `put_serial` and goes before every task that
has one, in task ID order, as before. A task that goes back to pending,
after a retried failure or a reclaim, keeps its place.

**A task may give a `priority`.** An optional integer from
-9223372036854775808 through 9223372036854775807, 0 when it is not given.
Higher goes first. It is written in the task's file only when it is not 0,
so a task put without one is written as before.

**Neither is part of what a task is.** Equal tasks are equal envelopes:
`task_id`, `capability`, `payload`, and `attachments`. A task put again with
another priority is `existing`, and keeps the priority and place it was put
with ([INV-7](../invariants.md)). A caller cannot give `put_serial`; a task
that does is malformed input. The lease envelope carries neither, so a
0.0.4 worker, which refuses fields it does not know, reads it.

### Details the implementer decided, for the operator to confirm

1. A place is a sequence number, not a time: clocks can step back, and two
   puts can share a microsecond.
2. Priority outranks age entirely. A steady stream of high-priority work
   starves lower work; that is what was asked for, and the caller sets the
   priorities.
3. `lease` now reads every pending task to order them, where it read until
   it had leased enough. Recovery already reads every pending task on each
   command, so the cost grows as it did.

## Rejected

- **Pending file names that sort in order.** Callers read `pending/` by task
  ID today (the archive does), and a file named by its place could not be
  found by its ID, which `put` needs to stay cheap
  ([ADR 0018](0018-finished-work-is-collected-or-ages-out.md)).
- **Changing a task's priority by putting it again.** It would make a
  repeated put change something ([INV-7](../invariants.md)); whether a
  priority should change once put is [open](../open-questions.md).
- **Ordering by the pending file's time.** A task that goes back to pending
  gets a new file, and would lose its place.
