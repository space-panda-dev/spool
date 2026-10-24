# 0028. A host may read its spools as metrics

Status: proposed

The fleet's Agents pane is to show every spool on every host without
naming one (the fleet's ADR 0015: every series names its subject, and a
dashboard names no value). Today a spool is read with `status --json`,
`status --json --tasks`, `results` and `failures`, and none of them
answers what the pane needs:

- how long the longest-waiting task has waited: no listing carries the
  time a task became pending;
- what is queued, by capability: `status --json --tasks` lists no
  capability;
- what finished or failed lately, and why, in a form whose size does not
  grow with the work: `results` carries every result value, and a failure's
  `reason` is free text, one value per distinct stderr tail.

A fleet timer that read the listings and the spool's files would know the
layout, which ADR 0024 rejected for any caller. The fleet's ADR 0007 has
projects either send OTLP to the local collector or leave a Prometheus
textfile for it to read; Spool has no daemon (AGENTS.md: build the boring
thing), so a timer writing a textfile is the fit.

## Decision

**`spool metrics --window SECONDS --dir DIR [--dir DIR]...` writes the
named spools' state to stdout as Prometheus text exposition (version
0.0.4).** It is for the spool host's own timers, not for workers or
callers:

1. **It is not part of the protocol**, as `--version` is not
   ([ADR 0022](0022-a-binary-names-its-commit.md)). It changes no envelope,
   state, answer or exit code, and it has no remote word: a grant cannot ask
   for it. Its series are documented in [docs/metrics.md](../metrics.md),
   which is the contract with whoever reads them.
2. **It reads, and changes nothing a caller can see.** Each spool is read
   under its lock after recovery, as `status` is: recovery finishes
   transitions already committed (ADR 0013), and nothing else is written.
   A directory that is not a spool (it has no `pending` directory) is
   malformed input, exit 2, and is never created, unlike every other
   command, which initialises the directory it is given.
3. **Each series names its spool** by the label `spool`, the base name of
   its directory. Two directories with one base name are malformed input.
   No `host` label is written: the collector adds it.
4. **Every other label is a bounded dimension**: `state` (four values),
   `capability` and `worker` (as many as the spool's callers and grants),
   `reason` (the classes below), `retried` (`true`, `false`). No task ID,
   lease ID, payload or result is ever a label.
5. **Counts by state are a partition of tasks**, unlike `status`
   ([ADR 0009](0009-status-counts-coordination-records.md)): `failed`
   counts tasks failed for good and not yet collected or aged out, not
   failure records. Failure records are counted, by reason, in the window.
6. **Recent work is a window, not a counter.** Results and failure records
   are deleted by `collect` and `gc` (ADR 0018), so no count of them only
   grows. The command counts those whose `finished_at` or `failed_at` lies
   within the last `--window` seconds, and writes the window it used.
7. **A pending task's age is the time since it last became pending**:
   since its put, or since a `fail` or reclaim returned it. The spool keeps
   no put time; the pending task file's modification time is this, because
   every write of the file is an atomic create of a new one.
8. **A failure's reason is reported as a class**, from the start of the
   reason: `reclaimed` (`reclaimed: not renewed within`), `revoked`
   (`reclaimed: grant revoked`), and the reference worker's `exit`,
   `timeout`, `output_limit`, `output_not_json`, `left_running`, and
   `other` for anything else, including every reason another worker writes.
9. **One spool that cannot be read fails the command**, with nothing
   written to stdout, at the exit status that spool's failure has. A timer
   that writes the output to a temporary file and renames it on success
   leaves the last good reading in place, and the reading's age shows that
   it is stale.

The series:

| series | labels | meaning |
|---|---|---|
| `spool_tasks` | `spool`, `state` | tasks in each state; all four always written |
| `spool_capability_tasks` | `spool`, `state`, `capability` | the same, by capability; only counts above 0 |
| `spool_leases` | `spool`, `worker` | leased tasks, by the worker holding each |
| `spool_oldest_pending_age_seconds` | `spool` | how long the longest-waiting pending task has waited; 0 with none |
| `spool_oldest_lease_renewal_age_seconds` | `spool` | the longest any lease has gone unrenewed; 0 with none. Under `reclaim --older-than S`, a lease past S is reclaimed at the next run |
| `spool_recent_window_seconds` | `spool` | the window the two below count over |
| `spool_recent_results` | `spool`, `capability`, `worker` | results finished within the window |
| `spool_recent_failures` | `spool`, `capability`, `worker`, `reason`, `retried` | failure records within the window: a `fail`, a reclaim, a revoke |

### Details the implementer decided, for the operator to confirm

1. `--window` is required, as `--older-than` is for `reclaim` and `gc`:
   the timer that runs the command says what "recent" means.
2. A lease never handed to a worker (ADR 0024) is counted under `worker=""`.
3. `exit` is one class whatever the status, so that 254 exit statuses are
   not 254 series; exit 65 is visible as `retried="false"`.

## Rejected

- **A daemon serving `/metrics`, or sending OTLP.** Spool has no daemon,
  and a timer reading a few directories a minute costs nothing.
- **A script over `status`, `results` and `failures`.** They lack the
  pending age and the capability of queued work, `results` carries every
  result value, and adding what is missing to them changes the protocol for
  every caller to serve one reader.
- **Counters of finished and failed work.** They would need a count kept
  beside the records that `collect` and `gc` do not delete: new durable
  state, written by every `ack` and `fail`, for a display.
- **The reason text as a label.** Its values grow with every distinct
  stderr tail and would spend the fleet's series budget.
- **Writing what could be read and skipping a spool that could not.** A
  reading with a spool missing looks like a spool that went away; failing
  loudly keeps the last whole reading.
- **One invocation per spool.** Concatenated readings repeat each series'
  `# HELP` and `# TYPE`, which a textfile reader refuses.
