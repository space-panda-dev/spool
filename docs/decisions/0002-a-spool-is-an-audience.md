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
peer, an optional expiry, and optional limits. Removing it revokes the peer at
once; leases they hold are reclaimed like any other.

**The worker's owner decides what runs.** Each worker's configuration maps
capability names to programs its owner installed, with a timeout, a payload
limit, a concurrency limit, and the complete environment each program gets. A
task naming anything else is refused. Sharing capacity never hands over
control of the machine.

## Rejected

- **Routing labels in the envelope.** Anyone who can read the spool reads every
  task whatever its label.
- **The predecessor's offers with generation numbers and restart-to-revoke.** A
  grant that can be deleted does the same with one mechanism.
- **Sending code with a task.** It would make every worker a remote shell.
