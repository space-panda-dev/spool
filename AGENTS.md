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

## Porting from V2

Spool starts as a port of the predecessor project's task spool
(`experiments/task-spool`, about 1,200 lines of Haskell with a shell test
suite). Its mechanism is proven on one machine; take it freely, renaming the
package and binary to Spool's. Its cross-machine design was never run, and
the predecessor's federation layer used push and is not ported
([ADR 0001](docs/decisions/0001-pull-protocol.md)). What is new here (grants,
the remote command, attachments) is built from the decision records, not from
the predecessor.

The port is done when two real machines pass this: a task put on one host is
leased over SSH by a worker on another, run, acknowledged, and its result read
back; then a worker killed mid-task has its lease reclaimed and the task run
again.

## Checks

`make check` validates the repository's structure: links resolve, every
document is linked from somewhere, every decision record is indexed, cited
invariants exist and cite a decision, the protocol's version matches
`spec/VERSION`, and every file has a licence in `REUSE.toml`.
