# 0023. A task may be withdrawn

Status: accepted

Nothing put on a spool can be taken back. A caller that stops wanting a
task, because it ran the work itself or got the result some other way, can
only leave the task where it is, and a worker runs it later, or is running
it now. On 2026-10-20 the Mac worker of the archive's stem backfill spent
about 3 of its 5.3 hours on tasks the backfill had given up on, 14 of them
from a run the day before, and another 36 minutes on work the laptop had
already done; 31 GB of their attachments sat on the spool host. `collect`
deletes only a finished task, and `gc` only one finished long ago.

The operator asked for this on 2026-10-21.

## Decision

**`withdraw` takes a task back.** It reads lines of the form `collect`
reads, `{"task_id": ...}`, every line before it acts on any, and answers
each in order, exiting 0 whatever it answers:

- a pending task is deleted, with its attachments and every failure record
  it has, and answered `withdrawn`;
- a leased task is deleted the same way, and its lease ends now: it is
  answered `withdrawn`;
- a done task, or one whose latest failure was final, is left for
  `collect`, and answered `finished`;
- an ID the spool holds nothing under is answered `unknown`.

A task withdrawn is gone: put again, it is inserted and runs again, as a
collected one does.

**A withdrawn lease is answered `withdrawn`, not `stale`.** Ending a leased
task writes a withdrawal record, `withdrawn/LEASE_ID.json`, holding the
task, the lease, and `withdrawn_at`, and then removes the lease, its
sidecars, and what it staged. The record is the commit: recovery finishes a
withdrawal a crash interrupted. A `renew`, `ack`, or `fail` naming that
lease acts on nothing and is answered `withdrawn` where it would have been
`stale`; the command still exits 4, since the lease is dead
([INV-6](../invariants.md)). A `send` or `fetch` on it exits 4 as before.
A lease reclaimed while its worker was away, whose task is withdrawn while
it waits to be taken back ([ADR 0027](0027-a-worker-survives-its-link.md)),
gets a withdrawal record too. `gc --older-than` deletes withdrawal records
that old, as it deletes finished tasks.

**A worker told `withdrawn` stops the run.** The renewal that is answered
`withdrawn` stops the run at once, wherever it is: fetching, running, or
sending. The program's process group is ended as for a timeout, the working
directory is removed, and nothing is acknowledged or failed. It is said on
stderr and is no failure: the worker carries on, and its exit status is not
touched. A request answered stale, which may have met the withdrawal before
the renewal did, is followed by one renewal to tell the two apart.

**It is a remote word for a grant that may put.** As `collect` is
([ADR 0018](0018-finished-work-is-collected-or-ages-out.md)): taking a task
back goes with having put it. A grant that may not put is denied (5)
before a line is read.

### Details the implementer decided, for the operator to confirm

1. Withdrawing deletes the task's failure records too, retried ones
   included, so a withdrawn task leaves nothing behind but the withdrawal
   records of its leases. A task whose only remains are records, which only
   a crash in a withdrawal can leave, is answered `unknown` and the records
   are deleted.
2. `withdraw` exits 0 whatever it answers, as `collect` does; `finished`
   and `unknown` are not failures of the caller.
3. A worker that holds a withdrawn lease learns it at its next renewal, up
   to `renew_seconds` later, and its program has up to 5 seconds more to
   end after SIGTERM. Nothing reaches a worker sooner: workers pull
   ([INV-2](../invariants.md)).
4. The withdrawal record does not name the worker. A request through the
   remote command that names another worker's withdrawn lease is answered
   `withdrawn`; a lease ID is opaque and not guessed.

## Rejected

- **Marking the lease withdrawn and leaving it in `leased/`.** Its task
  would still look leased, to `put`, which would answer `existing` to a
  caller putting it again, and to anyone reading the spool.
- **`collect` for unfinished tasks.** `collect` says a result has been read;
  withdrawing says the work is no longer wanted. Folding them together would
  make `not_finished` mean deleted.
- **Answering `stale`.** A worker could not tell a withdrawal from a lost
  lease, and would treat an operator's decision as a failure.
- **A new exit status.** Exit 4 already means the lease acts on nothing;
  the answer line says why.
