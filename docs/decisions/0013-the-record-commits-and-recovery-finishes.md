# 0013. The record commits the transition, and recovery finishes it

Status: proposed

`ack` writes a result record and then moves the lease to done. `fail` writes
a failure record, returns the task to pending if it is to be retried, and
then removes the lease. Each is several steps on a file system, and a crash
between two of them leaves a record beside a lease that still stands.

Repeating the same `ack` or `fail` finishes it. If nobody repeats it,
`reclaim` takes the lease for abandoned and returns the task to pending. The
result record stays. `results` then lists a result for a task that is
pending and is run again, and a second result follows under another lease.
Whoever put the task made something from the first.

## Decision

The record is the commit. Once a result record or a failure record is
written, the transition has happened, and the steps after it only bring the
rest of the spool into line.

Recovery runs under the lock before every command. It finishes every
transition whose record is written and whose lease still stands:

- For a result record, it moves the lease to done, removes the lease's
  sidecars, and deletes the task's attachments.
- For a failure record, it does what `retried` says: it returns the task to
  pending or leaves it failed, removes the lease and its sidecars, and for a
  task left failed deletes its attachments.

`reclaim` is a command, so recovery runs before it, and it never sees a
lease whose transition was committed.

A worker that repeats an `ack` or a `fail` that recovery has finished is
answered as it is for any repeat: `already_done` for the same result, stale
for a different one or for a `fail`.

## Rejected

- Move the lease first and write the record after: a crash then leaves a
  done task with no result, which is the one thing a caller came for.
- Have `results` list only tasks that are done: the listing is then right
  and the spool is not, and `reclaim` still runs the task a second time.
- A journal of intended steps: it is a second record of what the first
  already says.
