# 0002. A spool is an audience

Status: accepted

A payload can hold anything its caller puts in it, including private content,
and Spool cannot tell because payloads are opaque. Whoever can lease from a
spool can read what is on it. Routing labels inside a spool would promise a
separation that the directory cannot keep.

## Decision

**Putting a task discloses it to everyone who can lease from that spool.** The
protocol says so plainly, so a caller that governs disclosure (Archive does)
treats `put` as a disclosure to that spool's audience.

**One spool per audience.** The requester keeps separate spools: one for their
own machines, one for each friend or circle that shares compute. Choosing the
spool is choosing who may see the task. Spool has no routing, labels, or
classes of its own.

**A grant is one peer's permission to lease from one spool.** It names the
peer and, optionally, when it expires; nothing else. Execution limits belong to
the worker's owner, and what may be disclosed belongs to the caller. Removing a
grant stops every further operation by that peer and reclaims their leases.
Revocation ends authority, not possession: what the peer already received stays
disclosed.

**The worker's owner decides what runs.** Each worker's configuration maps
capability names to programs its owner installed, with a timeout, a payload
limit, an output limit, a concurrency limit, and the complete environment each
program gets. A task naming anything else is refused, after the worker has
already seen it: what a worker is configured to run never narrows who can
read the spool. Sharing capacity never hands over control of the machine.
These are limits Spool itself enforces on a run, not resource isolation: an
owner who needs CPU, memory, or filesystem containment wraps their executable
with it themselves.

## Rejected

- **Routing labels in the envelope.** Anyone who can read the spool reads every
  task whatever its label.
- **Limits on grants.** Concurrency, budgets, or capability filters there would
  rebuild a scheduler at the wrong layer.
- **The predecessor's offers with generation numbers and restart-to-revoke.** A
  grant that can be deleted does the same with one mechanism.
- **Sending code with a task.** It would make every worker a remote shell.
