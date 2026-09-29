# 0003. SSH first, through a dedicated account

Status: accepted

Workers on other machines need to lease from a spool that lives on the
requester's machine. The predecessor's spool only worked on a shared
directory, and synced filesystems break the atomic renames and locks its
correctness depends on. SSH is everywhere and already authenticates, but it is
built for shells, so a mistake grants far more than leasing.

## Decision

**The transport is SSH, for your own machines and for friends.** A remote worker
runs the same protocol commands on the spool's host over SSH; the spool's
locks and renames stay local to that host. Friends reach the host over a
private network such as a tailnet, never the open internet.

**A dedicated account owns the spools.** Remote workers log in as a system user
that can read and write only the spool directories, so even a misconfigured
key reaches nothing else.

**Spool writes the key lines.** `spool grant` adds a peer's key to that
account's `authorized_keys` as `restrict,command="…"`, running a remote command
that accepts only lease, ack, renew, fail, and attachment fetches, for one
spool, under the worker name the grant fixes. `spool revoke` removes it. No one
writes these lines by hand.

**The transport carries the protocol; it never changes it.** The protocol is the
same JSONL commands whether run locally or over SSH, so another transport (HTTP
over a tailnet, for example) can be added later without changing any spool or
worker.

## Rejected

- **A synced or network filesystem.** Syncthing breaks atomic renames and
  locks; NFS locking is unreliable.
- **An HTTP service now.** A daemon, authentication, and TLS before any need
  that SSH does not meet.
- **Hand-written `authorized_keys` lines.** One missing `restrict` grants port
  forwarding or a shell.
- **A worker naming itself.** A peer could act as another worker; the grant
  fixes the name.
