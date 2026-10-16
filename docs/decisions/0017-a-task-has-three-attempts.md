# 0017. A task has three attempts, and a program can say it is hopeless

Status: accepted

A `fail` with retry returns a task to pending, and a reclaimed lease does
the same, as many times as it happens. A task whose program always exits
non-zero is leased, run, and failed for ever, and so is a task that kills
its worker: an input that runs the machine out of memory takes the worker
with it, the lease is reclaimed, and the next worker leases the same task.
Nothing stops either loop but a person who notices it. A spool that is set
and forgotten has nobody to notice.

A program cannot stop the loop itself. It knows when an input can never
succeed, a payload it cannot parse, but every non-zero exit is retried; only
an unknown capability or an oversized payload is failed for good, and those
are the worker's judgements, not the program's.

## Decision

A task has at most three attempts: it goes back to pending after at most two
failures. The number is fixed.

- **A reclaim is a failure.** `reclaim` ends each lease it takes back by
  writing an ordinary failure record for it, as `fail` does, with the reason
  `reclaimed: not renewed within N s`; `revoke` does the same for the leases
  of the worker it revokes, with the reason `reclaimed: grant revoked`. The
  record has no new field. A lease with no worker on file was never handed
  to a worker, since the worker is recorded before the lease is answered; it
  goes back to pending with no record and is no attempt.
- **Attempts are counted from the failure records.** The attempts a task has
  had before a lease are its failure records that were retried, other than
  that lease's own, taken under leases later than its latest record that was
  not retried. `put` accepts a task again once it has failed for good, and
  it starts afresh. A record is named by its lease, and the lease names its
  task, so only that task's records are read.
- **The last attempt is not retried.** A `fail` with retry, or a reclaim, of
  a task that has had two attempts writes `retried` false and adds
  `; retries exhausted after 3 attempts` to the reason. `fail` answers
  `failed`, and `reclaim` answers `{"task_id":...,"status":"failed"}`.
  `fail --no-retry` is final at any attempt, as before.
- **The decision is in the record.** It is made under the lock and written
  into the record, which is the commit
  ([ADR 0013](0013-the-record-commits-and-recovery-finishes.md)). Recovery
  follows `retried` and never counts again, so a crash between the record
  and the steps after it cannot change the answer.
- **Exit 65 is final.** A program that exits 65 (`EX_DATAERR`) says the task
  can never succeed. `work` fails it with `--no-retry` and the reason
  `exit 65: ` followed by the end of its stderr. Every other non-zero exit is
  retried, up to the cap.

`failures` and the `failed` counter of `status` now include reclaims.

## Rejected

- A limit set per spool, or per task: it is a setting to persist, show, and
  validate for a number nobody has asked to change. A spool that needs
  another can be given one by a later record.
- A counter beside the task: a second record of what the failure records
  already say, which a crash can leave disagreeing with them.
- Counting reclaims apart from failures: a task that kills its worker is the
  loop that most needs stopping, and it never reaches `fail`.
- Counting every failure record of the task, ever: a task put again after it
  failed for good would have one attempt, or none.
- Ordering a task's records by when they were written: clocks step. A lease's
  serial number only grows.
- A new exit status for `work` or a field in the failure record to mark
  exhaustion: `retried` false already says the task is finished, and the
  reason says why.
