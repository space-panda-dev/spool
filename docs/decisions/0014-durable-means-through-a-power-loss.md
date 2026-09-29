# 0014. Durable means through a power loss

Status: proposed

Spool calls itself a durable work queue and keeps work that must outlive the
process that asked for it. Every transition is atomic: a file appears whole
under its name or not at all. None is synced. What a command has answered is
in the operating system's memory, and reaches the disk when the operating
system sends it.

So the spool survives the death of any process, and does not survive the
machine losing power. After a power loss a task that `put` answered
`inserted` may be gone, a result that `ack` answered `acked` may be gone, and
on some file systems a file may be there under its name and empty. The
documents promise neither more nor less than this; they do not say.

## Decision

When a command answers, what it answers for is on the disk.

- A file is synced before it is given its name.
- A directory is synced after a name is added to it, removed from it, or
  moved into or out of it.
- A command answers a line only after the syncs of that line's transition.

A spool on a file system that does not honour a sync is as durable as that
file system. Spool does not detect this.

The cost is two or three syncs for each transition, where there were none.
On a disk that takes ten milliseconds to sync, `put` of a thousand tasks
takes tens of seconds where it took one.

## Rejected

- Survive a process and say so: it is cheaper, and it is what a caller of a
  queue kept in files does not expect. A caller that made a record from a
  result would hold a record of work the spool no longer knows was done.
- An option to turn syncing off: two behaviours to test, and the one that
  loses work is the one a benchmark chooses.
- Sync once at the end of a command: a command that is killed after it has
  answered half its lines has answered for what is not on the disk.
