# 0019. A worker may follow its spool

Status: accepted

`spool work` leases until nothing is pending and then exits. That fits a
batch: put a thousand tasks, start workers, and they stop when the work is
done. It does not fit a spool kept for one domain, where tasks are put a few
at a time, at any hour, by a program that will not start a worker each time.
The operator wants such a spool set and forgotten: a worker started at boot
by the machine's service manager that is still there next month. Restarting
`work` in a loop from a timer or a shell script does that badly: every
restart reloads the configuration, a script that loops on any exit hides a
revoked grant behind an endless retry, and nothing bounds how often it asks.

The operator approved this on 2026-10-15.

## Decision

**`work --follow` waits for work instead of stopping.** On both forms,
`spool --dir DIR work --worker W --config FILE --follow` and
`spool work --via COMMAND --config FILE --follow`, a lease that finds nothing
pending is followed by a wait and another lease, for as long as the worker
runs. `--max-tasks` still ends it once that many tasks have been started.
Everything else about a worker is as it was: the configuration, the limits,
renewal, and what is done with a program's exit and output.

**It backs off, up to a cap the caller sets.** The first wait is 1 second,
and each wait after an empty lease doubles, to at most `--idle-seconds N`,
30 by default. A task leased starts the schedule again at 1 second. An idle
worker therefore asks at most once every N seconds, and through `--via`,
where every lease is one SSH process, it starts at most one process every N
seconds. A task put on an idle spool waits at most N seconds to be leased.
`--idle-seconds` without `--follow` is malformed input.

**A transport failure is waited out; a refusal is not.** A lease that fails
with exit 75, a transport that could not carry the request (ssh's 255
included) or a spool that could not answer it, is said on stderr in one
`spool:` line and asked again on the same schedule, without limit. A worker
started at boot comes up before the network does, and a laptop sleeps. A
denied grant (5), malformed input (2), or corrupt state (70) ends the worker
with that status, at once and without a wait, as it does today. A revoked
worker stops instead of knocking every N seconds.

**SIGTERM ends the wait.** A following worker stops as any worker stops: it
leases nothing more, kills its runs, deletes their working directories, and
exits 143. The wait is interrupted, not finished.

**A failure in one task does not stop a following worker.** It is said when it
happens, as today, and the worker leases on. Only the first one's status is
kept, for the exit at `--max-tasks`. A stale acknowledgement after a reclaim
is routine on a spool that runs for months; a refused grant shows itself at
the next lease. A worker that runs for months keeps only the runs in
progress, not every run it ever started.

**This is not a daemon in the spool.** The README and
[ADR 0001](0001-pull-protocol.md) promise no daemon, and
[ADR 0008](0008-reclaim-is-caller-driven.md) refuses a background loop in
Spool. What they rule out is a process that the spool needs: a service the
spool host must run for tasks to move, holding state that requests depend on.
A following worker is none of that. It is the worker owner's own client
process, on the worker's machine, started by that owner's service manager. On
the spool host nothing runs between two requests; the worker holds no lock
and no lease while it waits; it does not reclaim, schedule, or push. Killing
it at any moment costs at most a reclaim of the leases it held, exactly as
killing a batch worker does. It still pulls, one request at a time, through
the same commands any worker uses, so the protocol does not change: nothing
on the spool can tell a following worker from a script that runs `work`
every N seconds.

## Rejected

- **Watching the spool with inotify or FSEvents.** It answers sooner, but only
  on the spool's host, never through SSH, so a remote worker would still
  poll; two mechanisms where one does. It also ties the worker to each
  platform's file events.
- **A blocking `lease --wait` over SSH.** The remote command would hold a
  process and a session open on the spool host for as long as nothing is
  pending: a process the spool host keeps for someone else's worker, which is
  the daemon this design refuses, and a new word in the remote grammar.
- **A fixed interval.** Short enough to pick up work promptly, it knocks on an
  idle spool for nothing all night; long enough to be quiet, it delays the
  first task after a pause by the whole interval. A backoff that starts short
  and caps is both.
- **Giving up after N transport failures.** A worker started at boot would die
  before the network came up, or during the first long outage, and stay dead
  until someone noticed. A transport failure is retryable by definition; a
  refusal, which is not, already stops the worker.
- **The interval in the configuration file.** The configuration says what the
  owner lets run and under what limits, and is the same for a batch run and
  a following one. How long to wait for work is how this invocation is run,
  like `--max-tasks`, so it is an argument beside it.
