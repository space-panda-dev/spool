# Working in this repository

Guidance for anyone changing Spool, coding agents and people alike. `CLAUDE.md`
imports it; tool-specific additions go there, never a second copy.

Read [README.md](README.md), [docs/invariants.md](docs/invariants.md), and the
[decision records](docs/decisions/README.md) before changing the protocol or
what Spool promises. Read [spec/protocol.md](spec/protocol.md) before changing
any command, file, or exit code.

## How to work

- **The invariants are the rules.** Every change keeps all of them.
- **Spool never learns what a task means.** No knowledge of any caller's
  domain: not archives, records, media, or models. A caller's meaning travels
  in the payload.
- **The protocol is the product.** A change to an envelope, a command, a state,
  or an exit code is a change to [spec/protocol.md](spec/protocol.md) first.
- **Build the boring thing.** Files, atomic renames, a lock, SSH. No daemon, no
  database, no scheduler. Unimplemented behaviour fails loudly.
- **An open question is a boundary, not a TODO.** When the documents leave
  something open, stop at it: keep the mechanism below it and leave the
  behaviour unsupported. Add what you find to
  [docs/open-questions.md](docs/open-questions.md).

## Checks

`make check` validates the repository's structure: links resolve, every
document is linked from somewhere, every decision record is indexed, cited
invariants exist and cite a decision, the protocol's version matches
`spec/VERSION`, and every file has a licence in `REUSE.toml`.

`nix flake check -L` builds the static binary with warnings as errors and runs
the unit tests in `test/` and the integration suite in `test.sh`. CI runs the
same on Linux and macOS, and builds against Hackage with each supported
compiler. A test goes in `test/` when it needs a pure function or a failure at
one exact moment, and in `test.sh` when it needs the binary. Changes to grants, remote dispatch, attachment lifecycle, reclaim, or
lease fencing also run the authorized three-role procedure in the
[real-machine validation runbook](docs/real-machine-gate.md).
