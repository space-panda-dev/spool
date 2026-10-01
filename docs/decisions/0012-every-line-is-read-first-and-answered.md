# 0012. Every line is read first, and every line is answered

Status: accepted

`put`, `ack`, `renew`, and `fail` take many lines. Two things about them are
undecided, and the implementation decides each differently by accident.

What a malformed line does depends on the path. A command given its lines on
stdin reads one, acts on it, and reads the next, so a malformed third line
stops it with two lines already acted on. The remote command reads every
line before it acts on any, because it checks who owns each lease first, so
the same input does nothing at all.

What a stale lease gets depends on reading stderr. The line gets no answer
on stdout and a sentence on stderr, and the command exits 4. A caller that
sent ten lines and got eight answers has to match task identifiers to find
which two were refused, and cannot if two lines named the same task.

## Decision

A command reads and checks every line of its input before it acts on any. A
malformed line is exit 2 with nothing acted on. This holds on stdin and
through the remote command alike.

`ack`, `renew`, and `fail` answer every line, in the order given, and every
answer names the lease it answers:

```json
{"task_id":"task-one","lease_id":"lease_...","status":"acked"}
{"task_id":"task-two","lease_id":"lease_...","status":"stale"}
```

`stale` is the answer to a lease that is stale, unknown, another task's, or,
through the remote command, another worker's. The answer does not say which,
as the remote command's refusal of a grant does not. The command acts on the
lines that are not stale and then exits 4 if any was.

Through the remote command a lease that is another worker's makes its own
line `stale` and leaves the other lines to be acted on. That replaces the
refusal of the whole request.

stderr goes on saying what it says, for a person.

## Rejected

- Act on each line as it is read: a caller whose input was cut short cannot
  tell which part took effect without asking the spool about every task.
- Refuse the whole input when one lease is stale: a worker that lost one
  lease to reclaim could then acknowledge none of the work it finished.
- Say why a lease is stale: through the remote command that tells a peer
  whether a lease it does not hold exists.
- Keep the answer without `lease_id`: a task leased twice is two lines with
  one `task_id`.
