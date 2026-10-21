# 0025. A worker may fetch ahead, above a floor of free disk

Status: accepted

A worker leases a task only when one of its `max_concurrent` slots is free,
and fetches, runs, and sends the task inside that slot. Off its spool's
network that leaves the program idle while bytes move: on 2026-10-20 a 93
minute recording took 359 s to fetch and 210 s to send around 609 s of
separation on the Mac, so transfer was 48% of each task. A second slot
overlaps them, but doubles the program's memory, which the Mac does not
have. The Mac's disk is its other limit: 3.1 GB were free, and a task holds
2 to 2.7 GB while it runs.

The operator asked for this on 2026-10-21.

## Decision

**`prefetch` leases tasks ahead.** A worker configuration may set
`prefetch`, a whole number from 0, 0 when it is not given. The worker holds
up to `max_concurrent` plus `prefetch` leases at once. Each task fetches its
attachments as soon as it is leased, while its lease is renewed, and then
waits for a slot to run its program in; the slot is let go when the program
ends, before its outputs are sent. A task never takes a slot ahead of a task
leased before it that is still waiting for one, so tasks run in the order
they were leased. With `prefetch` 0 every task leased finds a slot free, as
before.

**`min_free_bytes` keeps a floor of free disk.** A configuration may set
`min_free_bytes`, a whole number of at least 1. While a task leased earlier
is still held, the worker leases nothing more until the file system that
holds its working directories has that many bytes free, and a task waits to
fetch until its attachments would leave that many free. The first task held
never waits for the floor, so a worker with nothing else in hand works as
it always did, and two tasks never wait for each other. The waits start at
1 second and double up to `renew_seconds`, and a task's lease is renewed
while it waits. The free space is what `df -P -k` reports as available.

**`work --show` shows them only when set**, so a configuration without them
shows as it did.

### Details the implementer decided, for the operator to confirm

1. The slot is let go before outputs are sent, so a task fetched ahead
   starts its program while the last one's outputs go up. Under `prefetch`
   0 nothing changes: every task held already has a slot.
2. The floor is measured with `df`, found on the worker's `PATH`. When it
   cannot be run, what was measuring ends with exit 75, as a request the
   spool could not answer does: a task's lease stands, for reclaim, and a
   worker about to lease ahead stops.
3. A task waiting for the floor holds its lease. Nobody else can run it
   meanwhile; a caller that wants it back withdraws it
   ([ADR 0022](0022-a-task-may-be-withdrawn.md)).

## Rejected

- **Raising `max_concurrent`.** It overlaps transfer too, but runs two
  programs at once, which is the memory a 16 GB machine lacks.
- **Measuring the floor against the outputs too.** A program's outputs are
  not known before it runs.
- **A floor that applies to the first task.** A worker with too little disk
  for one task could then never work, where today it tries and fails loudly.
