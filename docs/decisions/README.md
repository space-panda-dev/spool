# Decision records

Each record states a decision, why it was needed, and what it rejected. To
change one, add a record that supersedes it. Undecided matters belong in
[open-questions.md](../open-questions.md).

A proposed record is a decision put forward and not made. The protocol
document and the implementation say nothing of it until it is accepted.

| # | Decision |
|---|---|
| [0001](0001-pull-protocol.md) | A pull protocol with one reference implementation |
| [0002](0002-a-spool-is-an-audience.md) | A spool is an audience |
| [0003](0003-ssh-first.md) | SSH first, through a dedicated account |
| [0004](0004-attachments.md) | Attachments live and die with their task |
| [0005](0005-attachment-declaration-and-fetch.md) | Declare attachments by digest and fetch one verified stream |
| [0006](0006-grants-are-account-records.md) | Grants are account records with expiry in the record |
| [0007](0007-remote-command-is-an-exact-byte-grammar.md) | The remote command is an exact byte grammar |
| [0008](0008-reclaim-is-caller-driven.md) | Reclaim is caller-driven |
| [0009](0009-status-counts-coordination-records.md) | Status counts coordination records, not an exclusive partition |
| [0010](0010-names-have-one-grammar-and-a-length.md) | Names have one grammar and a length |
| [0011](0011-a-lease-id-is-opaque-to-its-holder.md) | A lease identifier is opaque to its holder |
| [0012](0012-every-line-is-read-first-and-answered.md) | Every line is read first, and every line is answered |
| [0013](0013-the-record-commits-and-recovery-finishes.md) | The record commits the transition, and recovery finishes it |
| [0014](0014-durable-means-through-a-power-loss.md) | Durable means through a power loss |
| [0015](0015-a-grant-may-let-its-holder-put.md) | A grant may let its holder put |
| [0016](0016-a-grant-that-may-put-may-read-what-came-of-it.md) | A grant that may put may read what came of it |
| [0017](0017-a-task-has-three-attempts.md) | A task has three attempts, and a program can say it is hopeless |
| [0018](0018-finished-work-is-collected-or-ages-out.md) | Finished work is collected, or ages out |
| [0019](0019-a-worker-may-follow-its-spool.md) | A worker may follow its spool |
| [0020](0020-a-result-may-carry-attachments.md) | A result may carry attachments |
| [0021](0021-a-send-refused-for-room-waits.md) | A send refused for room waits |
| [0022](0022-a-binary-names-its-commit.md) | A binary names the commit it was built from |
| [0023](0023-a-task-may-be-withdrawn.md) | A task may be withdrawn |
| [0024](0024-status-lists-each-task.md) | Status lists each task pending or leased |
| [0025](0025-leases-follow-put-order-and-priority.md) | Leases follow put order, and a task may be put above others |
| [0026](0026-a-worker-may-fetch-ahead.md) | A worker may fetch ahead, above a floor of free disk |
| [0027](0027-a-worker-survives-its-link.md) | A worker survives its link |
