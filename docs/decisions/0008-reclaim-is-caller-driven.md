# 0008. Reclaim is caller-driven

Status: proposed

Expired leases need a liveness mechanism, but putting a clock loop inside
Spool would create the daemon and scheduler the design deliberately avoids.

## Decision

Spool starts no reclaim process. A caller on the spool host runs the existing
`spool --dir DIR reclaim --older-than SECONDS` command. A deployment may invoke
that same command from its existing host timer facility; the timer unit is
deployment configuration, not a Spool protocol object. The real-machine gate
invokes it explicitly.

The required `--older-than` argument is the complete threshold configuration.
It remains a non-negative integer, has no default, and is not persisted. For a
recurring production timer the operator chooses a positive value greater than
the workers' renewal interval plus the longest renewal delay they intend to
tolerate. Choosing badly can duplicate execution, but lease fencing still
protects state.

Each invocation examines the later of initial lease time and last successful
renewal, returns every older lease to pending under the existing transition
lock, and permanently kills the old lease ID. The remote command does not
expose reclaim.

## Rejected

- A Spool daemon, background thread, or scheduler: it adds a service lifecycle
  to a command-and-files design.
- Implicit reclaim during `lease`: the recovery threshold would become hidden
  remote behaviour.
- A persisted or universal default threshold: the correct outage tolerance is
  deployment policy and depends on worker renewal configuration.
- Remote reclaim: a grant authorizes worker operations, not spool-wide lease
  recovery.
