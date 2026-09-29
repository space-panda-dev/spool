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

**INV-6. A stale lease acts on nothing.** Once a lease is reclaimed or
resolved, its ID cannot acknowledge, renew, or fail anything.
([ADR 0001](decisions/0001-pull-protocol.md))

**INV-7. Retries are idempotent.** Putting an equal task again, or repeating an
acknowledgement, changes nothing; the same task ID with different content is a
conflict. ([ADR 0001](decisions/0001-pull-protocol.md))

**INV-8. Attachments live only as long as their task.** They are verified by
digest when staged and when received, and deleted from the spool and the worker
when the task is done or finally failed.
([ADR 0004](decisions/0004-attachments.md))

**INV-9. A spool is coordination, not a record.** Deleting a spool loses only
coordination history. Whatever must last is made from results by whoever asked
for the work. ([ADR 0001](decisions/0001-pull-protocol.md))
