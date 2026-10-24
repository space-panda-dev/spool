# Map of Spool

Where each part of Spool lives: its code, its tests, the protocol section it
implements and the decisions behind it. Read the row for what you are
changing, then those sections and records; the
[protocol](spec/protocol.md) and the [invariants](docs/invariants.md) govern.

| area | code (`src/Spool/`) | unit (`test/Test/`) | `test.sh` | protocol | decisions |
|---|---|---|---|---|---|
| tasks and their states | `Store`, `Wire`, `Types`, `Input` | `Store`, `Wire`, `Types` | `queue` | [Tasks](spec/protocol.md#tasks), [States](spec/protocol.md#states), [Names](spec/protocol.md#names) | 0001, 0002, 0010, 0011, 0012 |
| records on disk, the lock, recovery | `Files`, `Canonical`, `Store` | `Files`, `Store` | `queue`, `retention` | [What a command writes](spec/protocol.md#what-a-command-writes), [Durability](spec/protocol.md#durability) | 0013, 0014 |
| attempts, reclaim, retention | `Store` | `Store` | `queue`, `retention`, `lifecycle` | [Reclaim driver](spec/protocol.md#reclaim-driver), [Retention](spec/protocol.md#retention), [`status` counters](spec/protocol.md#status-counters) | 0008, 0009, 0017, 0018 |
| task attachments | `Attachments` | `Attachments` | `attachments` | [Attachments](spec/protocol.md#attachments), [`fetch`](spec/protocol.md#fetch) | 0004, 0005 |
| grants and the forced command | `Grants`, `Access`, `Cli` | `Access`, `Cli` | `grants`, `remote` | [Grants](spec/protocol.md#grants), [SSH remote command](spec/protocol.md#ssh-remote-command) | 0003, 0006, 0007, 0015, 0016 |
| the worker | `Worker/Run`, `Worker/Config`, `Worker/Connection` | `WorkerConfig` | `work`, `remote` | [Workers](spec/protocol.md#workers), [Remote worker](spec/protocol.md#remote-worker) | 0017 |
| following a spool | `Worker/Follow` | `Follow` | `follow`, `lifecycle` | [Following a spool](spec/protocol.md#following-a-spool) | 0019 |
| result attachments | `Worker/Outputs`, `Worker/Room`, `Store` | `Outputs`, `Room` | `outputs` | [Result attachments](spec/protocol.md#result-attachments), [`send`](spec/protocol.md#send), [`take`](spec/protocol.md#take) | 0020, 0021 |
| scheduling: withdraw, each task's status, lease order, leasing ahead, a worker's link | `Store`, `Wire`, `Grants`, `Worker/Run`, `Worker/Disk` | `Store`, `Wire`, `Disk`, `WorkerConfig` | `scheduling`, `work`, `remote` | [A withdrawn task](spec/protocol.md#a-withdrawn-task), [Each task](spec/protocol.md#each-task), [Leasing ahead](spec/protocol.md#leasing-ahead), [The link](spec/protocol.md#the-link) | 0023, 0024, 0025, 0026, 0027 |
| commands, errors, exit codes, `--version` | `Cli`, `Error`, `../Spool.hs` | `Cli`, `Error` | every section | [Commands](spec/protocol.md#commands), [Exit codes](spec/protocol.md#exit-codes) | 0012, 0022 |
| metrics for a host's timers (not protocol) | `Metrics`, `Store` (`metricsCommand`) | `Metrics`, `Cli` | `metrics` | none: [docs/metrics.md](docs/metrics.md) | 0028 |

Records are in [docs/decisions](docs/decisions/README.md); what is not yet
decided is in [docs/open-questions.md](docs/open-questions.md).

## Entry points

<!-- wf:gen anchors src/Spool.hs#run src/Spool/Cli.hs#parseCommand src/Spool/Store.hs#putTasks src/Spool/Store.hs#leaseTasks src/Spool/Store.hs#ackTasks src/Spool/Store.hs#recover src/Spool/Grants.hs#runRemote src/Spool/Worker/Run.hs#runWork src/Spool/Worker/Outputs.hs#judgeOutputs -->
- `src/Spool.hs#run`: line 77
- `src/Spool/Cli.hs#parseCommand`: line 72
- `src/Spool/Store.hs#putTasks`: line 307
- `src/Spool/Store.hs#leaseTasks`: line 482
- `src/Spool/Store.hs#ackTasks`: line 582
- `src/Spool/Store.hs#recover`: line 228
- `src/Spool/Grants.hs#runRemote`: line 264
- `src/Spool/Worker/Run.hs#runWork`: line 191
- `src/Spool/Worker/Outputs.hs#judgeOutputs`: line 60
<!-- /wf:gen -->

## Checks

`bash test.sh SECTION...` runs those sections of the integration suite
(`--list` names them); `scripts/demo.sh` prints the protocol's happy path,
and `wf prove demo --golden` compares it with `test/golden/demo.txt`.

<!-- wf:gen suites -->
| suite | tier | timeout | run |
|---|---|---|---|
| structure | 1 | 60s | `python3 scripts/check.py "$@"` |
| docs | 1 | 60s | `"${WF:-wf}" vet --docs MAP.md AGENTS.md README.md "$@"` |
| build | 5 | 1800s | `cabal build -v0 -f werror --enable-tests exe:spool "$@"` |
| unit | 30 | 1800s | `cabal test -v0 -f werror --enable-tests --test-show-details=direct "$@"` |
| integration | 300 | 1800s | `bash test.sh "$@"` |
| demo | 5 | 1800s | `want=$(mktemp) && sed -e "1,3d" -e "/^--- stderr\$/,\$d" test/golden/demo.txt > "$want" && bash scripts/demo.sh \| diff -u "$want" -` |
| flake | night | 3600s | `nix flake check -L "$@"` |
<!-- /wf:gen -->
