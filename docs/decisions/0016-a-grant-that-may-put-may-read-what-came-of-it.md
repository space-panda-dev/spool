# 0016. A grant that may put may read what came of it

Status: accepted

[ADR 0015](0015-a-grant-may-let-its-holder-put.md) lets a grant put tasks
through the remote command. The results of those tasks, and the failures,
can be read only by the spool's owner on the spool's host: `results`,
`failures`, and `status` are not remote words. A machine that put a thousand
tasks from across the tailnet and worked half of them has to ask someone at
the host what came of them. The first batch run across the Mac and the
ThinkPad ended exactly there.

## Decision

The remote grammar gains the words `results`, `failures`, and `status`, and
`status --json`. Through them, a grant whose `put` is true reads what the
local commands write, line for line. A grant whose `put` is false is denied
with exit 5, as it is for `put`: a grant that may only work a spool sees the
tasks it leases and nothing of the rest.

The three words read and change nothing, so they take no lines on stdin and
the remote command reads none. `reclaim`, `grant`, `revoke`, `init`, and
`put --attachments` stay on the host.

Whoever reads a result is still whoever put the task, in the sense that
matters: `put` was the permission to tell the audience what to do, and
reading the results is seeing what the audience did about it. The two go
together on one bit of the grant.

## Rejected

- Let every grant read results: a worker that may only work would then see
  every result on the spool, including those of tasks it never leased.
  Leasing already shows it every task, but a result is the output of
  someone's machine, and the owner chose who gets to see that by choosing who
  may put.
- A separate permission to read: a third bit for the one case where a
  machine may put and may not see what came of it, which no one has asked
  for.
- Return results through `ack`: the worker that acknowledges is not the
  machine that asked, and a result is kept for whoever asked.
- Filter `results` to the tasks a grant put: the spool does not record who
  put a task, and recording it would make `put` a question of identity where
  it is a question of permission.
