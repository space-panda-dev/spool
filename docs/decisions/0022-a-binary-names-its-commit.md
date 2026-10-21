# 0022. A binary names the commit it was built from

Status: accepted

`spool --version` printed `spool 0.0.4` and nothing more. Every binary built
between two releases says the same, so neither a person nor a test can tell
the one built from the tree in front of them from one installed months ago.
The integration suite was found passing while it ran a `spool` from `PATH`
rather than the binary built from the tree under test: it asked the binary
its version, and an old one gave the same answer.

## Decision

**`spool --version` prints the program, the release and the commit:**
`spool 0.0.4 COMMIT`, three words on one line. COMMIT is the full commit
identifier of the tree the binary was built from, that identifier followed
by `-dirty` when the tree held uncommitted changes, or `unknown` when the
build was not told.

1. The flake tells the build: it writes its own revision into
   `src/Spool.hs` before compiling, and its `spool-version` check holds the
   binary to it.
2. A cabal build says `unknown`. Cabal rebuilds a module when its source
   changes, not when the commit does; a commit given to it at build time
   would go stale in the next incremental build, and one passed as a
   compiler option would rebuild every module at every commit. `unknown` is
   true; a stale commit is not.
3. `test.sh` refuses a binary named by a relative path, one that is the
   `spool` on `PATH`, and one whose commit is neither `unknown` nor the
   tree's (or `SPOOL_COMMIT`'s, which the flake sets). Without `SPOOL` it
   builds one from the tree.

`--version` is not part of the [protocol](../../spec/protocol.md): how a
client learns the version a spool speaks is still
[open](../open-questions.md), and this decision does not answer it.

## Rejected

- **Template Haskell asking git at compile time.** The same staleness as a
  build-time option under cabal, and a build that needs git and a checkout,
  which the flake's sandbox has neither of.
- **A version file written beside the binary.** It can be separated from the
  binary it describes, which is the failure this answers.
- **Only the short commit.** Two short identifiers can collide; the full one
  costs nothing to print.
