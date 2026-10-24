# Metrics

`spool metrics` writes the state of a host's spools as Prometheus text
exposition, for a timer on the spool host to leave where the host's
collector reads it
([ADR 0028](decisions/0028-a-host-may-read-its-spools-as-metrics.md)). It
is not part of the [protocol](../spec/protocol.md): a grant cannot ask for
it, and nothing here is promised to a worker or a caller.

```sh
spool metrics --window SECONDS --dir DIR [--dir DIR]...
```

Each spool is read under its lock, after recovery, as `status` is, and
nothing else is written. A directory that is not a spool is exit 2 and is
not created. A spool that cannot be read fails the whole command, with
nothing on stdout, at the exit status of its failure; write the output to a
temporary file and rename it on success, so that the last good reading
stays.

```sh
spool metrics --window 3600 --dir /var/lib/spool/spools/a --dir /var/lib/spool/spools/b \
  > /var/lib/textfile/spool.prom.tmp && mv /var/lib/textfile/spool.prom.tmp /var/lib/textfile/spool.prom
```

## Series

Every series has the label `spool`, the base name of its directory, and no
`host`: the collector adds it. Every value is a gauge.

| series | labels | meaning |
|---|---|---|
| `spool_tasks` | `spool`, `state` | tasks pending, leased, done, and failed for good; all four always written |
| `spool_capability_tasks` | `spool`, `state`, `capability` | the same, by capability; only counts above 0 |
| `spool_leases` | `spool`, `worker` | leased tasks, by the worker holding each; `""` for a lease never handed to one |
| `spool_oldest_pending_age_seconds` | `spool` | seconds since the longest-waiting pending task became pending (put, or returned by `fail` or reclaim); 0 with none |
| `spool_oldest_lease_renewal_age_seconds` | `spool` | seconds since the stalest lease was taken or last renewed; 0 with none |
| `spool_recent_window_seconds` | `spool` | the `--window` the two below count over |
| `spool_recent_results` | `spool`, `capability`, `worker` | results whose `finished_at` is within the window |
| `spool_recent_failures` | `spool`, `capability`, `worker`, `reason`, `retried` | failure records whose `failed_at` is within the window |

`spool_tasks` partitions tasks: `failed` is a task failed for good and not
yet collected or aged out, where `status` counts failure records
([ADR 0009](decisions/0009-status-counts-coordination-records.md)). A
result or failure collected or aged out within the window is no longer
counted.

`reason` is a class of the failure's reason, taken from its start:

| `reason` | the reason begins |
|---|---|
| `reclaimed` | `reclaimed: not renewed within` |
| `revoked` | `reclaimed: grant revoked` |
| `exit` | `exit ` followed by a digit: the program exited non-zero |
| `timeout` | `timeout after ` |
| `output_limit` | `output exceeds max_output_bytes` |
| `output_not_json` | `output is not JSON` |
| `left_running` | `output still open` |
| `other` | anything else |

`retried` is the record's `retried`: `false` for a failure that ended its
task, by `--no-retry`, exit 65, or its last attempt.
