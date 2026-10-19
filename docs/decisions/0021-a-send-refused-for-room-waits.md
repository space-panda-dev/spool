# 0021. A send refused for room waits

Status: accepted

Under [ADR 0020](0020-a-result-may-carry-attachments.md) a send that would
take a grant past its `max_result_bytes` is refused with exit 6, and the
worker fails the lease with retry. In the first run across two machines
([the gate's last section](../real-machine-gate.md)) that cost a task its
life: the worker leased the task again at once, ran its program again, a
stem separation of minutes, was refused again, and in about a minute the
task had spent its three attempts
([ADR 0017](0017-a-task-has-three-attempts.md)) and was failed for good, its
input attachment deleted, only because the caller had not yet collected
earlier results. A full grant is not a failure of the task. It clears when
the caller collects, and the run has already done its work.

The operator decided on 2026-10-18 to back off before deploying 0.0.4.

## Decision

**A send refused for room waits, keeping its lease and its outputs.** A
send answered 6 keeps the working directory and the files already staged
under the lease, says once on stderr that it is waiting for room, waits, and
sends the same file again; when one is staged it says once that it is
sending on. The waits start at 1 second and double up to the worker's
`renew_seconds`, as a following worker's waits do
([ADR 0019](0019-a-worker-may-follow-its-spool.md)), so a waiting worker
asks no more often than it renews. There is no new setting. The renewal
loop runs throughout, so the lease stands while the worker waits, and the
program is not run again.

**It stops waiting when the lease is lost.** A renewal refused ends the wait
at once. Nothing is sent or acknowledged, and the worker does what it does
for any refused renewal. A lease reclaimed, or a grant revoked, is the
spool's to decide; the failure record is the reclaim's, as for any other
lease that is not renewed.

**SIGTERM ends it as it ends anything else.** The run's directory is
deleted, `work` exits 143, and the lease stands for reclaim.

**It stops after the capability's `timeout_seconds`.** A run that has waited
that long in all, over every file it sends, fails the lease with retry and
the reason `result attachment SHA256 waited N s for room under
max_result_bytes: ...`, as every refusal for room did before. The waits are
cut to come to that bound exactly. The bound is what breaks a deadlock: two
leases of one grant, each with files staged, can each be waiting for room
the other holds, and neither acks. After the bound both fail, the files
they staged are deleted with their leases, and a later attempt can win. A
run is already trusted with `timeout_seconds` of the worker's time and of
its lease; the wait is given the same, and no more.

**A file the grant could never hold is answered 7.** Bytes staged under the
sender's own lease are freed by no collect while it stands, and a limit of
0, which every grant made before 0.0.4 holds, frees nothing ever. When the
bytes staged under the same lease and this file together exceed the grant's
limit, the spool refuses the send with a new exit status, 7: a grant's
limit could never hold this result. Exit 6 keeps its meaning of no room
now. The worker fails the lease without retry on 7, with a reason that
names `max_result_bytes`, and waits for nothing: the same worker would run
the program again and be refused again.

The protocol stays 0.0.4, which is not yet released.

### Details the implementer decided, for the operator to confirm

1. **7 is final.** Another worker, under another grant with a larger limit,
   could succeed where this one cannot, and a retry would let it. The task
   is failed for good instead because retrying hands the same task back to
   the same worker first, which would run the program again, minutes of
   GPU, to be refused the same way, until its attempts are spent. The owner
   who raises the limit puts the task again.
2. The limit on the total wait is the capability's `timeout_seconds`, not
   a new setting, and it counts the waits only: the time the requests take
   is not in it.
3. The waits of one run are one schedule: a second file that must wait
   goes on from where the first left off, and does not start again at
   1 second.
4. Being stale on a send while waiting ends the run as a stale send always
   did, without an ack. Which the worker meets first, the refused renewal or
   the stale send, depends on timing; either way nothing is acknowledged.
5. "Waiting for room" and "sending on" are each said once a wait, on stderr,
   under the task's ID: `spool: work: task T: result attachment SHA256
   waits for room: ...` and `... room for result attachment SHA256 after N
   s, sending on`.
6. The spool decides 7 before 6: a file that could never fit is 7 even
   while the grant is also full.

## Rejected

- **Failing with retry, as before.** It spends the task's attempts on a
  condition of the caller's, not the task's, and runs the program again for
  each.
- **Waiting without a bound.** Two leases of one grant can each hold what
  the other needs, and neither would ever ack.
- **A setting for the wait.** `renew_seconds` already bounds how often the
  worker asks, and `timeout_seconds` how long a run may hold its lease.
- **Holding the program's outputs and leasing on.** The lease would have to
  end, and with it the files staged; a later lease of the same task would
  run the program again.
- **Retrying 7.** See the first detail above.
- **Reserving a whole result before its first file.** It would answer the
  deadlock where it starts, but it is a new request, and it is still an
  [open question](../open-questions.md).
