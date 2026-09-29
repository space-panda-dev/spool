# 0009. Status counts coordination records, not an exclusive partition

Status: proposed

The protocol names four task states, but a retrying failure both returns its
task to pending and leaves a failure record. The existing `status.failed`
counter therefore cannot also be an exclusive count of tasks whose current
state is failed.

## Decision

`status` reports counts of the durable coordination records a spool currently
holds. `pending`, `leased`, and `done` count their task files. `failed` counts
all failure records, including records whose `retried` field is true. The four
numbers do not partition unique task IDs and must not be summed as a task
total.

The failed *state* still means a task resolved by `fail --no-retry`; retrying
failure history does not change the task's returned pending state. Callers that
need the distinction read `failures` and its `retried` field. Spool remains a
coordination retry ledger, not an analytics system.

## Rejected

- Count only terminal failures: it silently hides retry history that the
  existing counter and failure ledger expose.
- Add both `failed_tasks` and `failure_records` now: it expands a diagnostic
  command without a done-criterion need.
- Make all four counters an exclusive partition: that requires a second
  durable terminal-task representation and migration policy solely for
  display.
