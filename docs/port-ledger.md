# Port ledger

Temporary inventory for the port from the predecessor, inspected at commit
`137af2ec8f76c5a039147de204ec040970a05690`. A disposition describes how a unit
reaches Spool; it does not make a deferred design decision. Delete this ledger
when the port is complete.

- **Keep the mechanism** preserves a proven implementation technique while
  bringing its errors and tests under Spool's contract.
- **Translate** preserves behaviour but expresses it in Spool's names and
  documented interface.
- **Rewrite** replaces behaviour where Spool's contract differs or the old
  mechanism can silently misreport failure.
- **Delete** leaves predecessor-specific material behind.
- **Defer** stops at an explicit open question.

## Implementation units

| Predecessor unit | Disposition | Reason and authority |
|---|---|---|
| Process entry point and `--version` | Translate | Keep one native `spool` binary and rename package metadata; the repository provides one reference implementation ([ADR 0001](decisions/0001-pull-protocol.md)). |
| CLI parser and command dispatcher | Translate | Expose exactly the commands and argument shapes in the [protocol](../spec/protocol.md#commands), with dispatch-chain tests required by the repository-wide test guidance. |
| Task, lease, path, and worker configuration types | Translate | Model the documented envelope, states, and worker configuration without interpreting payloads ([protocol](../spec/protocol.md#tasks), [INV-1](invariants.md)). |
| Directory layout and initialization | Keep the mechanism | Plain state directories and result files are the boring file-backed implementation chosen by [ADR 0001](decisions/0001-pull-protocol.md). |
| Per-transition file lock and in-process mutex | Keep the mechanism | A lock held only for an atomic transition preserves concurrency without a daemon or database ([ADR 0001](decisions/0001-pull-protocol.md)). |
| Task and capability validation | Keep the mechanism | Exact fields, task-ID grammar, capability grammar, and opaque payloads are specified by the [task envelope](../spec/protocol.md#tasks) and [INV-1](invariants.md). |
| Lease-ID validation and filename grammar | Keep the mechanism | A lease ID embedded in the filename provides the fencing required by [INV-6](invariants.md) and [ADR 0001](decisions/0001-pull-protocol.md). |
| Canonical JSON encoder | Keep the mechanism | Stable bytes make equal puts and acknowledgements testable and idempotent as required by [INV-7](invariants.md). |
| JSONL input and output plumbing | Translate | Every local command uses the protocol's JSONL interface ([commands](../spec/protocol.md#commands)). |
| Exclusive hard-link create | Rewrite | Preserve exclusive creation, but distinguish an existing target from refused or failed I/O; retryable filesystem failure is exit 75 ([exit codes](../spec/protocol.md#exit-codes)). |
| Atomic temporary-file replacement | Keep the mechanism | Same-directory temporary files and rename implement atomic record replacement chosen by [ADR 0001](decisions/0001-pull-protocol.md). |
| Generic ignored-I/O helper | Rewrite | Cleanup and transition errors must not be silently swallowed; failures must be narrowly harmless or fail loudly ([AGENTS.md](../AGENTS.md#how-to-work), [exit codes](../spec/protocol.md#exit-codes)). |
| Worker and renewal sidecars | Keep the mechanism | Sidecars retain the worker and latest renewal while the fenced filename remains the coordination token ([states](../spec/protocol.md#states)). |
| Sidecar creation, reads, and removal | Rewrite | Missing optional renewal is distinct from unreadable or corrupt state, and worker metadata must survive through failure and result records ([states](../spec/protocol.md#states)). |
| Existing-task search across pending, leased, and done | Keep the mechanism | Searching every live or resolved location enforces equal-put idempotency and conflicting-content refusal across transitions ([INV-7](invariants.md)). |
| Put transaction | Keep the mechanism | Exclusive creation plus full-envelope comparison implements the specified no-op/conflict split ([states](../spec/protocol.md#states)). |
| Lease selection and pending-to-leased rename | Rewrite | Keep atomic rename and count, but an I/O refusal may not be skipped as though another process won ([INV-2](invariants.md), [exit codes](../spec/protocol.md#exit-codes)). |
| Active-task guard | Keep the mechanism | Preventing two live leases for one task supports fencing and the pending-to-leased transition ([INV-6](invariants.md)). |
| Unique lease sequence and timestamp | Keep the mechanism | A fresh persistent token makes reclaimed lease IDs permanently stale ([INV-6](invariants.md)). |
| Acknowledge transition | Rewrite | `ack` must accept `{"task_id","lease_id","result"}` and persist the opaque result as it resolves the lease ([states](../spec/protocol.md#states), [INV-1](invariants.md), [INV-7](invariants.md)). |
| Done-lease lookup for repeated acknowledgement | Rewrite | Idempotency now compares the repeated result as well as task and lease; stale leases still act on nothing ([INV-6](invariants.md), [INV-7](invariants.md)). |
| Separate pre-ack result writer | Delete | A result written before `ack` can survive a failed or stale acknowledgement; the protocol makes the result part of `ack` ([states](../spec/protocol.md#states)). |
| Renew transition and renewal clock | Keep the mechanism | Renewing the current lease and reclaiming from the later timestamp is specified behaviour ([states](../spec/protocol.md#states)). |
| Fail record and retry/no-retry transition | Rewrite | Keep retry and terminal failure, but make record creation and state movement one recoverable transition with loud I/O failures ([states](../spec/protocol.md#states), [INV-6](invariants.md)). |
| Return-to-pending helper shared by fail and reclaim | Keep the mechanism | Equal recreation is idempotent and conflicting recreation fails, preserving [INV-7](invariants.md). |
| Failure listing and chronological ordering | Translate | `failures` is documented and failed coordination history is a retry ledger ([commands](../spec/protocol.md#commands), [ADR 0001](decisions/0001-pull-protocol.md)). |
| Result listing and chronological ordering | Rewrite | Preserve listing, but read records produced by result-bearing `ack` and keep results opaque ([states](../spec/protocol.md#states), [INV-1](invariants.md)). |
| Failure and result record validators | Rewrite | Validate every durable shape produced by the port and fail closed on missing, unknown, or mistyped fields ([protocol](../spec/protocol.md#commands)). |
| Reclaim scan and transition | Rewrite | Keep age calculation and fencing, but unreadable renewal state and removal failures must fail loudly; the command is specified even though its driver is open ([states](../spec/protocol.md#states)). |
| Status counters and JSON/text encoders | Translate | Preserve the documented `status [--json]` command while naming only Spool state ([commands](../spec/protocol.md#commands)). |
| Work configuration parser, defaults, and `--show` | Keep the mechanism | Executable, arguments, timeout, payload, concurrency, renewal, and complete environment are specified in [Workers](../spec/protocol.md#workers). |
| Executable existence and permission checks | Rewrite | Preserve validation but test refused metadata reads separately from absence so I/O refusal cannot masquerade as a missing program ([Workers](../spec/protocol.md#workers)). |
| Work scheduler and concurrency semaphore | Keep the mechanism | Pulling only available work up to configured concurrency preserves [INV-2](invariants.md) and [INV-4](invariants.md). |
| Capability lookup and payload-size refusal | Keep the mechanism | The worker owner controls installed capabilities and limits, while Spool treats names and payloads as opaque ([INV-1](invariants.md), [INV-4](invariants.md)). |
| Temporary working directory lifecycle | Rewrite | Preserve a fresh working directory, but cleanup failure must be visible and later attachments stop at their open design boundary ([Workers](../spec/protocol.md#workers), [open questions](open-questions.md#protocol)). |
| Renewal thread around an executable | Rewrite | Preserve periodic renewal, but a rejected renewal must not be silently ignored because a stale lease may resolve nothing ([INV-6](invariants.md)). |
| Capability process launch with exact environment | Keep the mechanism | Configured executable, fixed arguments, fresh cwd, payload stdin, and complete environment implement [INV-4](invariants.md) and [Workers](../spec/protocol.md#workers). |
| Timeout, pipe readers, and failure shaping | Rewrite | Preserve timeout and bounded stderr, but read and termination failures must not collapse into empty output; unimplemented behaviour fails loudly ([Workers](../spec/protocol.md#workers), [AGENTS.md](../AGENTS.md#how-to-work)). |
| Worker success completion | Rewrite | The worker calls the same result-bearing `ack` path as the CLI so the result survives end to end ([states](../spec/protocol.md#states)). |
| Worker failure completion | Rewrite | The worker calls the same fenced `fail` transition and surfaces stale or I/O rejection rather than only logging it ([INV-6](invariants.md)). |

## Command units

| Command | Disposition | Reason and authority |
|---|---|---|
| `init` | Translate | Initialize the explicit spool directory using the protocol command name ([commands](../spec/protocol.md#commands)). |
| `put` | Keep the mechanism | Full-envelope equality is a no-op and unequal reuse is a conflict ([INV-7](invariants.md)). |
| `lease` | Rewrite | Keep local pull and count with explicit I/O failures; remote identity fixing is deferred to the grant design ([INV-2](invariants.md), [open questions](open-questions.md#access)). |
| `ack` | Rewrite | Input now includes the opaque result and persistence belongs to the transition ([states](../spec/protocol.md#states)). |
| `renew` | Keep the mechanism | Only the current fenced lease may refresh its reclaim time ([INV-6](invariants.md)). |
| `fail` | Rewrite | Preserve retry and `--no-retry`, but make record/state changes robust and fenced ([states](../spec/protocol.md#states)). |
| `failures` | Translate | Retain ordered retry-ledger output under the documented interface ([commands](../spec/protocol.md#commands)). |
| `results` | Rewrite | Read results recorded by `ack`, not by a separate worker-only write ([states](../spec/protocol.md#states)). |
| `reclaim` | Keep the mechanism | Manual age-based reclaim is specified and fences the old lease ([states](../spec/protocol.md#states), [INV-6](invariants.md)). |
| `status` | Translate | Preserve text and JSON forms exactly as documented ([commands](../spec/protocol.md#commands)). |
| `work` | Rewrite | Keep the configured executor lifecycle, but route success through result-bearing `ack` and make rejected transitions loud ([Workers](../spec/protocol.md#workers)). |
| `work --show` | Keep the mechanism | Printing resolved local worker configuration supports owner control without touching task meaning ([INV-4](invariants.md)). |
| `grant` / `revoke` | Defer | Their format, expiry location, and exact remote command are explicit access open questions ([open questions](open-questions.md#access)). |
| Remote command | Defer | Its safe fixed-word interface is deliberately undecided ([open questions](open-questions.md#access)). |
| Attachment fetch | Defer | Envelope declaration and SSH transfer shape are deliberately undecided ([open questions](open-questions.md#protocol)). |
| Reclaim driver | Defer | What invokes `reclaim` and with what threshold is deliberately undecided ([open questions](open-questions.md#access)). |

## Test units

| Predecessor test | Disposition | Reason and authority |
|---|---|---|
| Source build, supplied binary, version, and `init` | Translate | Test the renamed native binary and explicit directory promised by [ADR 0001](decisions/0001-pull-protocol.md). |
| Put two tasks and report `inserted` | Keep the mechanism | Proves pending creation through the real writer ([states](../spec/protocol.md#states)). |
| Equal repeated put reports `existing` | Keep the mechanism | Direct assertion of put idempotency ([INV-7](invariants.md)). |
| Same ID with different payload conflicts | Keep the mechanism | Unequal content under one ID is a conflict ([INV-7](invariants.md)). |
| Same ID/payload with different capability conflicts | Keep the mechanism | The whole envelope defines equality ([tasks](../spec/protocol.md#tasks), [INV-7](invariants.md)). |
| Missing capability rejection | Keep the mechanism | The task envelope has exactly three required fields ([tasks](../spec/protocol.md#tasks)). |
| Capability without version rejection | Keep the mechanism | Capability grammar is `name@version` ([tasks](../spec/protocol.md#tasks)). |
| Empty capability name rejection | Keep the mechanism | Capability name has a non-empty grammar ([tasks](../spec/protocol.md#tasks)). |
| Empty capability version rejection | Keep the mechanism | Capability version has a non-empty grammar ([tasks](../spec/protocol.md#tasks)). |
| Lease count, IDs, capability, and payload envelope | Keep the mechanism | Proves the real put-to-lease chain and metadata boundary ([states](../spec/protocol.md#states)). |
| First acknowledgement | Rewrite | Add a result and assert done state plus the exact persisted result ([states](../spec/protocol.md#states)). |
| Repeated equal acknowledgement | Rewrite | Repeat the same task, lease, and result and assert a no-op ([INV-7](invariants.md)). |
| Second independent acknowledgement | Rewrite | Carry its own result through the public `ack` path ([states](../spec/protocol.md#states)). |
| Reclaim, re-lease, and changed token | Keep the mechanism | Anchor the token distinction before testing stale behaviour ([INV-6](invariants.md)). |
| Old acknowledgement after reclaim is rejected | Rewrite | Include a result and prove the stale lease changes neither done state nor results ([INV-6](invariants.md)). |
| Replacement acknowledgement succeeds | Rewrite | Include a result and prove only the live lease resolves ([INV-6](invariants.md)). |
| Renew prevents threshold reclaim | Keep the mechanism | Prove reclaim uses the later of lease and renewal times ([states](../spec/protocol.md#states)). |
| Renewed lease can acknowledge | Rewrite | Carry a result while proving the original lease remains current ([states](../spec/protocol.md#states)). |
| Renew after reclaim is exit 4 | Keep the mechanism | A stale lease acts on nothing ([INV-6](invariants.md), [exit codes](../spec/protocol.md#exit-codes)). |
| Fail with retry returns pending and records metadata | Keep the mechanism | Proves retry plus worker, capability, and reason boundary survival ([states](../spec/protocol.md#states)). |
| Fail with `--no-retry` remains off pending | Keep the mechanism | Proves terminal failure behaviour ([states](../spec/protocol.md#states)). |
| Text and JSON status count failures | Translate | Preserve both documented status forms ([commands](../spec/protocol.md#commands)). |
| Caller environment cannot supply a directory | Rewrite | Make the test generic: caller variables cannot replace mandatory `--dir` ([commands](../spec/protocol.md#commands)). |
| Invalid non-task-shaped envelope fails closed | Rewrite | Use a generic malformed envelope and retain exact-field validation ([tasks](../spec/protocol.md#tasks)). |
| Worker executable fixtures and config generator | Translate | Keep real process boundaries and rename every predecessor-specific identifier ([Workers](../spec/protocol.md#workers)). |
| Retried-task drain helper | Rewrite | Preserve scenario isolation and change its acknowledgement to carry a result ([INV-7](invariants.md)). |
| `work --show` resolved configuration | Keep the mechanism | Proves defaults and owner-selected execution settings ([Workers](../spec/protocol.md#workers), [INV-4](invariants.md)). |
| Successful `work` result and acknowledgement | Rewrite | Assert one chain from put through dispatch, program JSON, result-bearing `ack`, and `results` ([states](../spec/protocol.md#states)). |
| Non-zero executable retries with stderr reason | Keep the mechanism | Worker failures retry and report their reason ([Workers](../spec/protocol.md#workers)). |
| Unknown capability fails without retry | Keep the mechanism | The worker owner alone decides what runs ([INV-4](invariants.md)). |
| Oversize payload fails without retry | Keep the mechanism | The configured payload limit is part of the worker contract ([Workers](../spec/protocol.md#workers)). |
| Timeout retries with timeout reason | Keep the mechanism | The configured timeout governs the executable ([Workers](../spec/protocol.md#workers)). |
| Caller environment is ignored | Rewrite | Assert configured variables survive and caller-only variables do not, with generic names ([Workers](../spec/protocol.md#workers), [INV-4](invariants.md)). |
| Non-JSON stdout retries | Keep the mechanism | Exit 0 produces a result only when stdout is JSON ([Workers](../spec/protocol.md#workers)). |
| `max_concurrent: 1` prevents overlap | Keep the mechanism | A real exclusive fixture asserts the limit rather than only counting launches ([INV-4](invariants.md)). |
| `max_concurrent: 2` permits overlap | Keep the mechanism | Both real processes must be simultaneously in flight ([INV-4](invariants.md)). |
| `--max-tasks` stops after one | Keep the mechanism | Preserves the documented bounded invocation ([commands](../spec/protocol.md#commands)). |
| No pending task makes `work` exit 0 | Keep the mechanism | A non-daemon invocation drains available work and returns ([ADR 0001](decisions/0001-pull-protocol.md)). |
| Stale `fail` is exit 4 | Rewrite | Add the missing fenced-operation case so every stale transition is tested ([INV-6](invariants.md)). |
| Permission/refusal branches for existence, rename, sidecar, and cleanup | Rewrite | Add missing tests so refused I/O cannot masquerade as absence, a race, or successful cleanup ([AGENTS.md](../AGENTS.md#how-to-work)). |
| Real-writer corruption fixtures | Rewrite | Corrupt records and sidecars produced by public commands so validators are tested against the shapes the implementation actually writes ([protocol](../spec/protocol.md#commands)). |
| CLI registry-to-handler reachability | Rewrite | Add an enumerated dispatch test so every declared command reaches its handler ([AGENTS.md](../AGENTS.md#checks)). |
| Grant, remote-command, and attachment tests | Defer | Their interfaces are open questions and cannot be encoded yet ([open questions](open-questions.md)). |

## Documentation and packaging units

| Predecessor unit | Disposition | Reason and authority |
|---|---|---|
| Standalone README overview | Delete | Spool's existing [README](../README.md) is authoritative; predecessor-specific rationale and composition do not belong here. |
| CLI and envelope reference in the old README | Delete | The [protocol](../spec/protocol.md) is the sole command and envelope authority ([AGENTS.md](../AGENTS.md#how-to-work)). |
| Old worker/configuration prose | Delete | Worker behaviour belongs in [Workers](../spec/protocol.md#workers); changes land there with code. |
| Old implementation-boundary prose | Translate | Durable file and rename facts may be documented under Spool names and [ADR 0001](decisions/0001-pull-protocol.md). |
| Old verification prose | Delete | The ported suite will describe itself under Spool's repository checks ([AGENTS.md](../AGENTS.md#checks)). |
| Cabal package name | Translate | Rename the package to `spool`, matching the reference implementation named by [ADR 0001](decisions/0001-pull-protocol.md). |
| Cabal executable name | Keep the mechanism | The documented binary is already `spool` ([commands](../spec/protocol.md#commands)). |
| Cabal source and dependency stanza | Translate | Move the single executable and only needed libraries here, retaining the boring implementation ([ADR 0001](decisions/0001-pull-protocol.md)). |
| Cabal proprietary licence metadata | Rewrite | Code here is AGPL-3.0-or-later as declared by the [README](../README.md#licence) and `REUSE.toml`. |
| Parent-repository static executable derivation | Rewrite | Give Spool its own flake and statically linked default package, as required by [ADR 0001](decisions/0001-pull-protocol.md). |
| Parent package export | Delete | Spool is an independent repository and does not export through the predecessor's package set ([README](../README.md#what-spool-is)). |
| Parent binary/version smoke check | Rewrite | Move executable and version checks into Spool's own flake checks ([AGENTS.md](../AGENTS.md#checks)). |
| Parent packaged test invocation | Rewrite | Run the renamed shell suite against Spool's immutable packaged binary from its own flake ([ADR 0001](decisions/0001-pull-protocol.md)). |
| Build-artifact ignore rules | Keep the mechanism | Ignore local Cabal and Nix outputs without changing protocol semantics. |

## Open-question boundaries

No implementation unit in the local-mechanism phase depends on an open
question. Work stops before attachment declaration and transfer, result
retention and large results, protocol negotiation, hard cancellation, remote
command input, grant representation and expiry, alternative identity or public
access, and the process or timer that invokes `reclaim`. These boundaries are
listed in [open questions](open-questions.md); predecessor behaviour is not
evidence for an answer.

## Document gaps found during inventory

1. Phase 2 added exit 70 for corrupt durable state to the
   [protocol exit-code table](../spec/protocol.md#exit-codes) and tests it with
   records made by the real writers.
2. The meaning of `status.failed` is now explicit in proposed
   [ADR 0009](decisions/0009-status-counts-coordination-records.md). The
   proposal documents the ported behaviour but remains unaccepted as protocol
   authority until the proposal gate is resolved.
3. Phase 2 specifies and tests that an equal repeated `ack` is a no-op while a
   different result under the resolved lease is exit 4 and cannot replace the
   stored result.
