# Open questions

Left open on purpose. Code that reaches one fails loudly as unsupported rather
than guessing.

## Protocol

- How is an attachment declared in the envelope, and how is it fetched over
  SSH: a separate command, or a stream alongside the lease?
- What limits apply to attachments (per task, per spool), and is transfer
  resumable?
- When may a done task and its result be deleted: once read, after a period,
  or by the caller's command? A spool must not become an archive of finished
  work.
- How are large results returned? Results are small JSON; anything bigger is
  the capability's business until a real need says otherwise.
- How is the protocol versioned, and how does a worker learn the version a
  spool speaks?
- Is there a hard cancel for a running task?

## Access

- What exactly is the remote command's interface, and how does it read the
  requested command safely from SSH?
- What format do grants take, and where does their expiry live?
- Should identities come from Tailscale SSH instead of key files, for friends
  who do not manage keys?
- How would a spool open to strangers work, with no tailnet? A caller would
  treat it as open to anyone.
- What runs `reclaim`: a timer on the spool's host, and with what threshold?
