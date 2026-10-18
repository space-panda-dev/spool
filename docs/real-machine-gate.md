# Real-machine validation

This exercises the end-to-end deployment path. It is deliberately not a
simulation: A holds the spool, B and C make worker requests through their own
SSH grants, and reclaim is an explicit caller action on A.

Run it only after the operator names and authorizes all three roles and every
machine, account, spool path, binary, key path, and temporary worker directory
used by those roles. The script never chooses hosts or credentials and never
installs keys.

## Prerequisites

- A has the tested `spool` binary and a dedicated SSH account. The A-admin
  target runs spool commands as the filesystem owner of the spool; sharing
  the directory through an ACL is insufficient because durable task records
  are deliberately mode `0600`. Its B and C grants already exist, bind
  distinct workers, and use the public halves of the private keys named on B
  and C.
- The control machine can use batch SSH to the administrative accounts on A,
  B, and C. B and C can use their grant keys to reach A's dedicated account.
  When the controller is B or C, pass the literal target `local` for that
  worker instead of making an SSH loopback. This also avoids transports that
  execute commands but do not preserve their exit status.
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

For example, a controller running on B uses `--b-admin local`. Paths belonging
to B are then local to the controller; A and C remain batch SSH targets.

The script creates unique task IDs and an A-side attachment staging directory.
It records every JSON response in the evidence directory. It first proves B's
lease, fetch, run-time byte check, renew, result-bearing acknowledgement,
attachment deletion, and result. It then kills a real process on B while B's
second lease is live, runs `reclaim --older-than 0` explicitly on A, proves C
gets a different lease and completes the task, and requires B's late ack to
exit 4 without replacing C's result.

Success ends with `PASS RUN_ID evidence=PATH`. Preserve that directory with
the tested commit hash and the A/B/C role-to-machine mapping. On failure,
preserve the same files plus stderr; inspect state with local commands on A.
The script removes only the exact attachment staging file and exact B/C files
it created. It leaves the spool and its durable result/failure evidence intact.

## Observed in production

Use is not a gate, and does not replace a run of the script above: nothing
below killed a worker, reclaimed a lease, or answered a late ack. It records
what spool 0.0.3 (ef7bd7f) did under real load, so the gate's evidence and
the field's agree.

### 2026-10-17: a two-machine calibration batch

A caller split one long computation into 175 tasks of one capability, with
content-derived task IDs. Payloads were a digest and two indices; each
machine held a copy of the 94 MB input beforehand, so nothing travelled as
an attachment. The spool lived on a Linux laptop (8 cores, 14 GiB); both
that laptop and a macOS laptop (8 cores, 16 GB) worked it through their own
grants with `work --via`, at 6 and 4 concurrent tasks. One task alone took
22 min 32 s on the macOS worker.

| | |
|---|---|
| tasks put (remote, through a grant) | 175: one first, then 174 at once |
| wall time, put to last result | 6 h 04 min (5 h 40 min for the 174) |
| failures, retries, reclaims, stale answers | 0 at every status taken |
| results read, then `collect`ed | 175 of 175; the spool ended with its prior counts |
| Linux worker unit | 31 h 14 min CPU in 5 h 40 min wall, 5.4 GB peak memory |
| lease renewals over SSH, every 30 s | about 7,000, none refused |
| first worker done to last worker done | 23 min: the last two tasks ran on one machine |

On the spool's host, against a quiet window of the same length the next
night, the run added at most 0.14 cores of system time and 3.7 process
creations a second, beside 5.9 cores of the capability's own work. Disk
writes were no higher than at rest. Spool's own cost did not register.

Measured afterwards against the same spool:

- One remote request from the macOS worker cost 788 ms at the median and
  1.7 s at p95, almost all of it SSH connection setup over a 59 ms link. With
  OpenSSH connection sharing (`ControlMaster`/`ControlPersist` in the
  `--via` command) the same request cost 147 ms, p95 160 ms. On the host,
  over loopback, a request cost 188 ms.
- A local worker's resident memory stayed at 38 MB across 1,500 tasks.

What it did not exercise: worker death and reclaim, the retry cap and exit
65 under load, attachments, revocation, and `gc`.

### 2026-10-18: result attachments across two machines

Spool 0.0.4 before release (this branch), as a check of
[ADR 0020](decisions/0020-a-result-may-carry-attachments.md), not the
scripted gate: a scratch spool on the Linux laptop, a grant with
`--max-result-bytes 300000000`, and a macOS worker reaching it over the
tailnet with `work --via ssh …`. The grant's forced command was stood in for
by a wrapper that sets `SSH_ORIGINAL_COMMAND` and runs `spool remote
--grant`, so the authorized-keys line itself was not exercised.

Three tasks each carried a 40 MB attachment; the capability hashed it and
left two 60 MB files in `outputs/`.

| | |
|---|---|
| attachments fetched by the worker, then verified by its program | 3 of 3, digests equal |
| result files sent, staged, and acked | 4 (two tasks), 240 MB |
| the third task against the grant's limit | its first file staged (300 MB held), its second refused (exit 6); failed with retry, and the next two attempts the same, so it ended failed after 3 attempts |
| `take`, local and remote, by the caller on the host | 4 of 4 files, digests equal |
| `collect` | everything gone: no attachment, staged, or result file left |
| `status` from another process every 0.5 s throughout | 492 answers, mean 12 ms, slowest 71 ms |

Then the third task was put again and a worker killed with SIGKILL while it
was sending: the host's `send` saw a short stream and kept nothing, `reclaim`
returned the task, and a fresh worker finished it; both files were taken and
collected, leaving the spool empty.

What it showed beyond the tests: a send refused for the limit counts as an
attempt, and a worker that leases again at once spends all three in about a
minute, rerunning the program each time.
