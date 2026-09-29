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
  spool speaks?
- Is there a hard cancel for a running task?

## Access

- Should identities come from Tailscale SSH instead of key files, for friends
  who do not manage keys?
- How would a spool open to strangers work, with no tailnet? A caller would
  treat it as open to anyone.
