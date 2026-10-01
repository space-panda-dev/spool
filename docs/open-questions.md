# Open questions

Left open on purpose. Code that reaches one fails loudly as unsupported rather
than guessing.

## Protocol

- When may a done task and its result be deleted: once read, after a period,
  or by the caller's command? A spool must not become an archive of finished
  work.
- How are large results returned? Results are small JSON; anything bigger is
  the capability's business until a real need says otherwise.
- How is the protocol versioned, and how does a worker learn the version a
  spool speaks? Every reader refuses a field it does not define, so the
  first field added to an envelope or a record makes every older reader
  refuse it. The answer has to come before that field does.
- Is there a hard cancel for a running task?
- How do an attachment's bytes reach the spool from another machine? A task
  put through the remote command may declare none ([ADR 0015](decisions/0015-a-grant-may-let-its-holder-put.md)).
- Should a worker stop a run when its lease is lost? A renewal that is
  refused is found only when the program finishes, so the program runs to
  the end of work that can no longer be acknowledged.

## Access

- Should identities come from Tailscale SSH instead of key files, for friends
  who do not manage keys?
- How would a spool open to strangers work, with no tailnet? A caller would
  treat it as open to anyone.
