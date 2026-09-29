# 0006. Grants are account records with expiry in the record

Status: proposed

A forced SSH command needs trusted spool and worker values that cannot come
from the peer. The dedicated account also needs revocation and expiry to take
effect without editing opaque command strings by hand.

## Decision

A grant is a JSON record in the dedicated account's
`$HOME/.spool/grants/GRANT_ID.json`. It contains exactly a generated
`grant_id`, operator label `peer`, fixed `worker`, canonical absolute `spool`,
canonical OpenSSH `public_key`, and `expires_at`, which is either a UTC RFC3339
timestamp or null. The generated ID is `grant_` followed by 32 lower-case
hexadecimal characters. It is an identifier, not a secret.

`spool --dir DIR grant` validates the record values and public key, writes the
record atomically, and atomically rewrites `$HOME/.ssh/authorized_keys` with
one managed line:

```text
restrict,command="ABSOLUTE_SPOOL_EXECUTABLE remote --grant GRANT_ID" KEY spool-grant:GRANT_ID
```

Spool generates and escapes the option; nobody writes it by hand. The command
uses Spool's canonical absolute executable path and the path-safe generated
ID, never peer text. A managed public key and worker name may each occur in at
most one active grant for a spool, so SSH selection and lease reclamation are
unambiguous. Unmanaged key lines are preserved byte for byte.

The remote command loads the record on every invocation. A missing, malformed,
wrong-spool, or expired record denies the request. `now >= expires_at` is
expired; null never expires. Expiry lives only in the record, so no expiry
daemon or duplicated timestamp in `authorized_keys` is needed.

`revoke` first makes the record unavailable, then removes its exact managed
line, then reclaims every live lease under that grant's fixed worker while
holding the spool transition lock. A crash after the first step leaves a key
line whose forced command still denies every request. Repeating revoke is a
no-op. Revocation ends authority but cannot erase bytes already received.

A grant contains no capabilities, concurrency, budget, timeout, payload, or
attachment limits. Those belong to the worker owner or caller, not access.

## Rejected

- Expiry only in `authorized_keys`: OpenSSH has no portable per-line expiry,
  and the remote command could not recheck it.
- Grant values embedded directly in a shell command: peer labels, paths, and
  timestamps would become quoting hazards.
- One shared grant document: a per-ID record is the smallest fail-closed unit
  for revocation.
- Duplicate managed keys or workers on one spool: the accepted SSH line and
  leases to reclaim would be ambiguous.
- Capability or resource limits in grants: that rebuilds a scheduler at the
  wrong layer.
