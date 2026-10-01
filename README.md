# Spool

Spool keeps work that must outlive the process that asked for it. Someone puts
a task on a spool; a worker pulls it, runs it, and reports a result or a
failure; a task whose worker vanished is taken back and offered again.

It is a durable work queue protocol with one reference implementation. It knows nothing
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
  capabilities its owner configured, under Spool's own limits on concurrency,
  timeout, payload size, and output size. Those bound Spool's behaviour, not
  the executable's; containing what a program can do to the machine it runs
  on is the owner's job, not Spool's.
- **Coordination, not a record.** A spool remembers what is pending, leased,
  done, and failed so work survives crashes. Anything that must last is made
  from its results by whoever asked.

## What Spool is not

A queue server, a scheduler, a job platform, a store, or a way to run code on
someone else's machine. It is a durable work queue kept in files. Work that
does not need to survive its caller should skip Spool and use GNU parallel.

## Reference implementation

The `spool` binary implements the protocol with files, atomic transitions, and
JSONL commands. It can run configured local capabilities, renew and reclaim
fenced leases, and retain results and failure history. Dedicated SSH accounts
use revocable or expiring grants whose forced command exposes only worker
operations, and `put` for a grant that allows it, and fixes the worker
identity. A worker on another machine runs `spool work --via "ssh account@host"`
and speaks that command. Attachments are declared by digest, verified when
staged and received, and deleted when their task resolves.

The implementation is a library with a thin executable over it. The Nix flake
builds a static binary. Unit and property tests cover the grammars, the
envelopes, and the canonical encoding; the integration suite exercises the
local and forced-command paths against a built binary; the real-machine
validation exercises the full SSH, attachment, worker-death, reclaim, and
stale-ack path.

## The words

| Word | Meaning |
|---|---|
| spool | a directory of tasks, and the audience that can lease from it |
| task | `{task_id, capability, payload}`, plus attachments |
| capability | `name@version`; a worker's owner maps it to a program |
| worker | a named process that leases tasks and runs them |
| lease | a worker's claim on one task, fenced by its ID |
| attachment | a file staged with a task and deleted with it |
| grant | one peer's permission to lease from one spool, until revoked or expired |

## Where to look

```
AGENTS.md              how to change this repository (for agents and people)
spec/protocol.md       the protocol: envelope, states, commands, exit codes
docs/invariants.md     what must always hold
docs/decisions/        why each decision was made
docs/open-questions.md what is deliberately not decided yet
docs/real-machine-gate.md authorized cross-machine validation and evidence
src/                   the reference implementation, a library
app/                   the spool executable
test/                  unit and property tests
test.sh                the integration suite, run against a built binary
```

## Contributing

Read [AGENTS.md](AGENTS.md); it applies to people too. Run `make check` and
`nix flake check -L`. `nix develop` opens a shell with the compiler and Cabal,
where `cabal test` runs the unit tests alone. Sign off each commit (`git commit -s`) to certify it under
the [Developer Certificate of Origin](https://developercertificate.org).

## Licence

The code is licensed under the
[GNU Affero General Public License, version 3 or later](LICENSES/AGPL-3.0-or-later.txt).
The protocol and documentation are dedicated to the public domain under
[CC0 1.0](LICENSES/CC0-1.0.txt), so anyone may write a worker or a spool in
any language. `REUSE.toml` says which files are which. The reasons are
Archive's ADR 0017; Spool follows the same pattern.

Copyright the Spool contributors. Started by William Britt Mathis.
