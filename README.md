# Spool

Spool keeps work that must outlive the process that asked for it. Someone puts
a task on a spool; a worker pulls it, runs it, and reports a result or a
failure; a task whose worker vanished is taken back and offered again.

It is a small protocol with one reference implementation. It knows nothing
about what its tasks mean: a payload is opaque JSON, and a capability is a
name that each worker's owner maps to a program they installed. Archive uses
it, and any unrelated program can.

## What Spool is

- **Pull, not push.** A spool lives with whoever asks for work. Workers come to
  it and take tasks; nothing is ever sent to a worker uninvited, and no code is
  ever sent at all.
- **A spool is an audience.** Everyone who can lease from a spool can read what
  is put on it. Putting a task is telling them. Keep one spool per audience:
  one for your own machines, one for a friend who shares compute.
- **The worker's owner decides what runs.** A friend's machine runs only the
  capabilities its owner configured, under their limits.
- **Coordination, not a record.** A spool remembers what is pending, leased,
  done, and failed so work survives crashes. Anything that must last is made
  from its results by whoever asked.

## What Spool is not

A scheduler, a queue service, a store, or a way to run code on someone else's
machine. Work that does not need to survive its caller should skip Spool and
use GNU parallel.

## The words

| Word | Meaning |
|---|---|
| spool | a directory of tasks, and the audience that can lease from it |
| task | `{task_id, capability, payload}`, plus attachments |
| capability | `name@version`; a worker's owner maps it to a program |
| worker | a named process that leases tasks and runs them |
| lease | a worker's claim on one task, fenced by its ID |
| attachment | a file staged with a task and deleted with it |
| grant | one peer's permission to lease from one spool |

## Where to look

```
AGENTS.md              how to change this repository (for agents and people)
spec/protocol.md       the protocol: envelope, states, commands, exit codes
docs/invariants.md     what must always hold
docs/decisions/        why each decision was made
docs/open-questions.md what is deliberately not decided yet
```

## Contributing

Read [AGENTS.md](AGENTS.md); it applies to people too. Run `make check`. Sign
off each commit (`git commit -s`) to certify it under the
[Developer Certificate of Origin](https://developercertificate.org).

## Licence

The code is licensed under the
[GNU Affero General Public License, version 3 or later](LICENSES/AGPL-3.0-or-later.txt).
The protocol and documentation are dedicated to the public domain under
[CC0 1.0](LICENSES/CC0-1.0.txt), so anyone may write a worker or a spool in
any language. `REUSE.toml` says which files are which. The reasons are
Archive's ADR 0017; Spool follows the same pattern.

Copyright the Spool contributors. Started by William Britt Mathis.
