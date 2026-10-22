# Invariants

What must always hold. Every change keeps all of them; changing one takes a
decision record.

**INV-1. Payloads are opaque.** Spool validates the envelope and the grammar of
a capability, and never interprets a capability's name, a payload, or a result.
([ADR 0001](decisions/0001-pull-protocol.md))

**INV-2. Workers pull.** A spool never sends work to a worker, and Spool never
sends code anywhere. ([ADR 0001](decisions/0001-pull-protocol.md))

**INV-3. Putting a task discloses it to the spool's audience.** Everyone who can
lease from a spool can read every payload and attachment put on it.
([ADR 0002](decisions/0002-a-spool-is-an-audience.md))

**INV-4. The worker's owner decides what runs.** A worker runs only the
capabilities its owner configured, with the programs, limits, and environment
they chose. ([ADR 0002](decisions/0002-a-spool-is-an-audience.md))

**INV-5. A grant fixes who is leasing.** A remote worker's name comes from its
grant, never from what it claims.
([ADR 0003](decisions/0003-ssh-first.md))

**INV-6. A stale lease acts on nothing.** Once a lease is resolved,
withdrawn, or reclaimed and its task leased again or failed for good, its ID
cannot acknowledge, renew, or fail anything. A lease reclaimed for want of
renewal, whose task nobody has leased since, is not stale: its worker takes
it back.
([ADR 0001](decisions/0001-pull-protocol.md),
[ADR 0023](decisions/0023-a-task-may-be-withdrawn.md),
[ADR 0027](decisions/0027-a-worker-survives-its-link.md))

**INV-7. Retries are idempotent.** Putting an equal task again, or repeating an
acknowledgement, changes nothing; the same task ID with different content is a
conflict. This holds for as long as the spool keeps the task: once it is
collected or has aged out, it is new again.
([ADR 0001](decisions/0001-pull-protocol.md),
[ADR 0018](decisions/0018-finished-work-is-collected-or-ages-out.md))

**INV-8. Attachments live only as long as their task.** They are verified by
digest when staged and when received. The spool deletes its copies when the
task is done or finally failed. A worker deletes its copies when the program
exits, but Spool cannot confirm that, so a worker's machine remains somewhere a
copy may survive. A result's attachments live only as long as its done task:
the spool deletes them when the task is collected or ages out, and deletes
what a lease sent when the lease ends without a result.
([ADR 0004](decisions/0004-attachments.md),
[ADR 0020](decisions/0020-a-result-may-carry-attachments.md))

**INV-9. A spool is coordination, not a record.** Deleting a spool loses only
coordination history. Whatever must last is made from results by whoever asked
for the work. ([ADR 0001](decisions/0001-pull-protocol.md))

**INV-10. A task is attempted at most three times.** Every lease that ends
without a result is an attempt and leaves a failure record, and a task goes
back to pending after at most two of them.
([ADR 0017](decisions/0017-a-task-has-three-attempts.md))
