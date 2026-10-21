# 0026. A worker survives its link

Status: accepted

A worker on another machine reaches its spool by one SSH process for each
request, so every request is a chance for the link to fail. Three things
made a short outage cost a whole task:

- The renewal loop ended at the first renewal the transport could not
  carry, and the run's result was then thrown away when the program
  finished.
- A fetch, send, or ack the transport could not carry ended the run; a
  fetch of 1.5 GB that broke started again from nothing.
- A lease reclaimed while the worker was away was dead when it came back,
  even if nobody had taken its task since. On 2026-10-20 the Mac lost its
  link for 53 minutes; its lease was reclaimed at 300 s and its send was
  refused when the link returned.

The operator asked for this on 2026-10-21, as "accept a send on a stale
lease when the task has not been re-leased since", and a resumable fetch
if cheap.

## Decision

**A lease reclaimed for want of renewal is taken back, if nobody has leased
its task since.** A `renew`, `ack`, `send`, or `fetch` naming a lease that
is not in flight takes it back when:

- the lease's failure record is a reclaim for want of renewal, with retry
  (reason `reclaimed: not renewed within ...`, `retried` true);
- its task is pending; and
- no failure record of the task is later than the lease's.

Through the remote command, the lease must also have been the grant's
worker's. The task moves back under the lease, with its worker and a
renewal now, and the reclaim's failure record is deleted, last: deleting it
is the commit, and until then recovery finishes the reclaim again. The
request then goes on as for any lease in flight. A reclaim that left the
task failed, a revoke's reclaim, and a worker's own `fail` are never taken
back, and `fail` never takes a lease back.

**What a reclaimed lease staged waits with it.** A reclaim that returns
its task to pending keeps the result attachments the lease staged
([ADR 0020](0020-a-result-may-carry-attachments.md)), counted against its
worker's grant, until the lease is taken back or the task is leased again,
withdrawn, or finishes; then they go as before.

**The worker asks again.** A renewal the transport could not carry, or the
spool could not answer (exit 75), is said once on stderr and tried again at
the next interval; a renewal that arrives after a reclaim takes the lease
back as above. A fetch, a send, and an ack that fail with 75 are asked
again after a wait of 1 second, doubling up to `renew_seconds`, for as long
as the lease is renewed. A `fail` is not asked again: a fail that is lost
leaves the lease to be reclaimed, which records a failure too.

**`fetch` may start from an offset.** A fetch request may carry `offset`,
the bytes of the attachment the worker already holds, from 0 through its
size; 0 is not written. The spool verifies the whole file as before and
writes the bytes after the offset. A worker keeps what it received of an
attachment in a partial file, asks again from where it ends, and verifies
the whole file before it gives it its name. An offset past the end is
malformed input (2).

[INV-6](../invariants.md) changes with this: a lease is dead once it is
resolved, or once it has been reclaimed and its task leased again, or its
reclaim left the task failed.

### Details the implementer decided, for the operator to confirm

1. Taking a lease back deletes the reclaim's failure record, so the attempt
   it counted is given back ([ADR 0017](0017-a-task-has-three-attempts.md)):
   the attempt did not end, and its worker finished it.
2. The rule reads the reclaim's reason. Spool writes it, and a worker that
   fails with that reason itself only makes its own fail revivable.
3. There is no limit on how long a worker asks again while its lease is
   renewed. A lease that is reclaimed and leased elsewhere ends it at the
   next renewal.
4. ControlMaster/ControlPersist for the worker's SSH transport is not
   Spool's: it belongs in the `--via` command the operator configures, and
   would spare a full handshake on each of the hundreds of requests an hour
   a worker makes.

## Rejected

- **A longer reclaim for remote grants.** It holds a dead worker's task as
  long as it waits for a live one, and is a setting per grant.
- **Accepting any stale lease's request.** A task leased again would have
  two holders.
- **Resuming a send.** A send is staged whole or not at all, under the lock
  only at its two ends ([ADR 0020](0020-a-result-may-carry-attachments.md));
  a partial staged file would need a request of its own. A failed send is
  sent again from the start.
- **Asking again without a lease.** A worker that cannot renew its lease
  has nothing to ask with once the lease is gone.
