# Real-machine gate

This is the final port gate from [`AGENTS.md`](../AGENTS.md). It is deliberately
not a simulation: A holds the spool, B and C make worker requests through
their own SSH grants, and reclaim is an explicit caller action on A.

Do not run the gate until the operator names and authorizes all three machines,
accounts, spool path, binary, key paths, and temporary worker directories.
The script never chooses hosts or credentials and never installs keys.

## Prerequisites

- A has the tested `spool` binary and a dedicated SSH account. Its B and C
  grants already exist, bind distinct workers, and use the public halves of
  the private keys named on B and C.
- The control machine can use batch SSH to the administrative accounts on A,
  B, and C. B and C can use their grant keys to reach A's dedicated account.
- A's spool path and the B/C work directories are absolute, traversal-free
  paths chosen for this run. The script does not delete the spool.
- `ssh`, `scp`, `jq`, and a SHA-256 command are installed where the script
  uses them. Host-key verification is left enabled; populate `known_hosts`
  before the gate.

## Run

Review [`scripts/real-machine-gate.sh`](../scripts/real-machine-gate.sh), then
invoke it from the control machine with explicit values:

```sh
scripts/real-machine-gate.sh \
  --a-admin admin@host-a --a-worker spool@host-a \
  --b-admin admin@host-b --c-admin admin@host-c \
  --a-spool-bin /absolute/path/to/spool \
  --a-spool-dir /absolute/path/to/gate-spool \
  --b-key /absolute/path/on/b/grant-key \
  --c-key /absolute/path/on/c/grant-key \
  --b-work-dir /absolute/path/on/b/spool-gate-b \
  --c-work-dir /absolute/path/on/c/spool-gate-c \
  --evidence-dir ./gate-evidence
```

The script creates unique task IDs and an A-side attachment staging directory.
It records every JSON response in the evidence directory. It first proves B's
lease, fetch, run-time byte check, renew, result-bearing acknowledgement,
attachment deletion, and result. It then kills a real process on B while B's
second lease is live, runs `reclaim --older-than 0` explicitly on A, proves C
gets a different lease and completes the task, and requires B's late ack to
exit 4 without replacing C's result.

Success ends with `PASS RUN_ID evidence=PATH`. Preserve that directory with
the tested commit hash and the three machine identities. On failure, preserve
the same files plus stderr; inspect state with local commands on A. The script
removes only the exact attachment staging file and exact B/C files it created.
It leaves the spool and its durable result/failure evidence intact.
