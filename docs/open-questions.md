# Open questions

Left open on purpose. Code that reaches one fails loudly as unsupported rather
than guessing.

## Protocol

- How is the protocol versioned, and how does a worker learn the version a
  spool speaks? Every reader refuses a field it does not define, so the
  first field added to an envelope or a record makes every older reader
  refuse it. Version 0.0.3 added no field but new answers (`failed` from
  `reclaim`, `collected`, `not_finished`, `unknown`, `expired`), which a
  client learns of only from [the protocol](../spec/protocol.md#since-002).
  Version 0.0.4 added the first fields, `attachments` on an ack and a result
  record and `max_result_bytes` on a grant, and writes each only when it
  holds something, so an older reader meets one only where it matters
  ([ADR 0020](decisions/0020-a-result-may-carry-attachments.md)). That is a
  way around the question, not an answer to it.
- Is there a hard cancel for a running task? A withdrawn task's worker
  stops its run at its next renewal
  ([ADR 0023](decisions/0023-a-task-may-be-withdrawn.md)); nothing reaches
  a worker sooner, since workers pull.
- Should a task's priority change once it is put? Putting it again with
  another priority changes nothing
  ([ADR 0025](decisions/0025-leases-follow-put-order-and-priority.md)).
- How do an attachment's bytes reach the spool from another machine? A task
  put through the remote command may declare none ([ADR 0015](decisions/0015-a-grant-may-let-its-holder-put.md)).
  A result's attachments do reach it, by `send` under a lease
  ([ADR 0020](decisions/0020-a-result-may-carry-attachments.md)); a task's
  would need a request naming a task not yet put.
- Should a grant's limit on result attachments be taken for a whole result
  before its first file is sent? Today each file is counted when it is sent,
  so a result can have its first files staged and its last refused. The run
  then waits for room with the first files held
  ([ADR 0021](decisions/0021-a-send-refused-for-room-waits.md)), and two
  leases of one grant can each hold what the other waits for until both
  give up at their timeout.
- Should a spool, or a task, choose its own number of attempts? Three is
  fixed ([ADR 0017](decisions/0017-a-task-has-three-attempts.md)) until a
  real need for another says what the setting should be.
- How does a spool keep a binary older than its layout from using it? An
  older binary ignores `.spool-layout` and files a done task under its lease
  again, where `put` and `collect` do not look
  ([ADR 0018](decisions/0018-finished-work-is-collected-or-ages-out.md)).
  Tied to how the protocol is versioned, above.
- Should a worker stop a run when its lease is lost? A renewal that is
  refused is found only when the program finishes, so the program runs to
  the end of work that can no longer be acknowledged. A renewal answered
  `withdrawn` does stop it
  ([ADR 0023](decisions/0023-a-task-may-be-withdrawn.md)).

## Access

- Should identities come from Tailscale SSH instead of key files, for friends
  who do not manage keys?
- How would a spool open to strangers work, with no tailnet? A caller would
  treat it as open to anyone.
