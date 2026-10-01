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
