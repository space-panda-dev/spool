# Open questions

Left open on purpose. Code that reaches one fails loudly as unsupported rather
than guessing.

## Protocol

- How are large results returned? Results are small JSON; anything bigger is
  the capability's business until a real need says otherwise.
- How is the protocol versioned, and how does a worker learn the version a
  spool speaks? Every reader refuses a field it does not define, so the
  first field added to an envelope or a record makes every older reader
  refuse it. The answer has to come before that field does. Version 0.0.3
  added no field but new answers (`failed` from `reclaim`, `collected`,
  `not_finished`, `unknown`, `expired`), which a client learns of only from
  [the protocol](../spec/protocol.md#since-002).
- Is there a hard cancel for a running task?
- How do an attachment's bytes reach the spool from another machine? A task
  put through the remote command may declare none ([ADR 0015](decisions/0015-a-grant-may-let-its-holder-put.md)).
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
  the end of work that can no longer be acknowledged.

## Access

- Should identities come from Tailscale SSH instead of key files, for friends
  who do not manage keys?
- How would a spool open to strangers work, with no tailnet? A caller would
  treat it as open to anyone.
