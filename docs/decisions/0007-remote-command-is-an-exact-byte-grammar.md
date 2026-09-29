# 0007. The remote command is an exact byte grammar

Status: proposed

OpenSSH supplies a requested command as one string intended for a shell. A
peer allowed to lease must not be able to turn that string into a shell, name
another worker, select another spool, or reach a local-only operation.

## Decision

The managed key line runs `spool remote --grant GRANT_ID`. That trusted grant
lookup supplies the spool directory and worker name. Neither value is accepted
from the peer. The remote command checks the grant before dispatch and verifies
that every lease reference belongs to the grant's worker.

The command reads `SSH_ORIGINAL_COMMAND` as bytes and never invokes a shell or
shell tokenizer. The value must be at most 64 ASCII bytes and exactly one of:

```text
lease
lease --count N
ack
renew
fail
fail --no-retry
fetch
```

`N` is canonical decimal from 1 through 9223372036854775807. Exact comparison
means one ASCII space where shown and none at either end. Empty input, NUL,
non-ASCII, controls, tabs, newlines, repeated spaces, quoting, backslashes,
redirection, substitutions, separators, globs, extra words, and unknown
options are malformed input.

`lease` inserts the grant's worker. `ack`, `renew`, and `fail` use the same
JSONL stdin and output as local operations after checking lease ownership.
`fetch` accepts the proposal's one JSON request on stdin and writes only raw
attachment bytes to stdout. It never accepts an identifier or digest as a
command word. Diagnostics go only to stderr.

The parser and dispatcher are separate functions tested from the full command
registry. Adversarial inputs exercise their raw byte boundary, and every
accepted form must reach exactly its named handler.

## Rejected

- Passing `SSH_ORIGINAL_COMMAND` to `sh -c`, `words`, or a shell-like parser:
  quoting and separators become execution.
- Supplying `--dir` or `--worker`: that permits option injection and violates
  INV-5.
- Putting task IDs, lease IDs, or digests in the command string: stdin already
  carries validated protocol data and avoids path-like words entirely.
- Exposing `put`, `results`, `failures`, `status`, `reclaim`, `grant`, or
  `revoke`: a grant authorizes only worker operations.
- A general remote CLI passthrough: one future local flag would silently widen
  remote authority.
