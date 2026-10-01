# 0015. A grant may let its holder put

Status: accepted

The remote command of [ADR 0007](0007-remote-command-is-an-exact-byte-grammar.md)
exposes the worker operations and nothing else, so only the spool's owner,
on the spool's host, can put a task. A spool is an audience
([ADR 0002](0002-a-spool-is-an-audience.md)): everyone who can lease from
it reads every task on it. Where the audience is one person's own machines,
each of them has work for the others, and the spool host is the machine that
is always on, not the one the work comes from. The owner has had to put
through a shell on the host, outside the protocol.

## Decision

A grant records whether its holder may put. `grant --put` makes one that
may; the record gains a required field `put`, true or false. The remote
grammar gains the word `put`. Through it, a grant that may put reads the
same lines `put` takes locally and answers the same lines; a grant that may
not is denied with exit 5, as a missing grant is, and the request's lines
are not read.

A task put through the remote command may declare no attachments. One that
does is malformed input (exit 2). How an attachment's bytes reach the spool
from another machine is open; until it is decided, attachments are staged
only by `put --attachments` on the spool host.

A grant that may put is a grant to tell the whole audience what to do. It is
given to one's own machines, and to a friend's only on purpose.

## Rejected

- Let every grant put: a friend who shares compute would then be handing
  work to every machine on the spool, including the owner's.
- A second kind of key for putting: two managed lines per machine, and two
  records to revoke, for one bit of permission.
- Carry attachments through `put` over SSH now: the bytes would have to
  travel in the same stream as the JSONL or in a second request that names a
  task not yet put. Either is a design, and neither is forced by the need at
  hand.
