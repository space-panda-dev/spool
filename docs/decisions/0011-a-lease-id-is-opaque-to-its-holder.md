# 0011. A lease identifier is opaque to its holder

Status: accepted

The protocol shows a lease identifier as `lease_...` and says nothing of what
follows. The reference implementation writes the time of the lease, a serial
number, and the task there, and `reclaim` reads the time back out. A second
implementation cannot tell whether that form is the protocol's or this
implementation's, and a worker cannot tell whether it may rely on it.

## Decision

A `lease_id` is `lease_` followed by one or more of ASCII letters, digits,
`.`, `_`, and `-`, without `--`, and is at most 200 characters. The longest
the reference implementation makes is 171, and a file name has room for 200
and what the spool adds to it.

A worker is given a `lease_id` and gives it back unchanged. It reads nothing
from it. A `lease_id` that fits the grammar and names no lease on file is a
stale or unknown lease (exit 4), never malformed input.

What follows `lease_` belongs to the spool that made it. The reference
implementation writes `MICROS_SERIAL_TASK` and reads a lease's start time
from the first of those; another implementation may record the time
elsewhere.

`leased_at` is the time a lease was taken, for a worker that wants it.

## Rejected

- Make `MICROS_SERIAL_TASK` the protocol's form: every implementation would
  have to keep its clock and its serial number in a name, and a worker could
  come to read the task or the time from it.
- A random identifier with the time in a sidecar: it is a second file to
  write and lose for each lease, to hide a form nobody is asked to read.
