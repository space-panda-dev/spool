#!/usr/bin/env bash
# Make test/fixtures/spool-0.0.3-records.tar: a spool and a grant account
# written by a 0.0.3 binary, before result attachments (ADR 0020), for
# test.sh to prove that its result records and grant records still load.
#
#   scripts/make-records-fixture.sh SPOOL_0.0.3_BINARY OUTPUT.tar
#
# The binary must be 0.0.3 as released: built from 77c047c, for instance.
# The tar holds spool/, with a done task and its result record and a task
# leased to a granted worker, and home/, the account holding two grants:
# old-worker, which may not put, and old-putter, which may.
set -euo pipefail

binary=$1
output=$2
test "$("$binary" --version)" = "spool 0.0.3"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home/.ssh"
spool() { HOME="$work/home" "$binary" --dir "$work/spool" "$@"; }

spool init
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJ' > "$work/worker.pub"
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAK' > "$work/putter.pub"
spool grant --peer "old worker" --worker old-worker --key "$work/worker.pub" >/dev/null
spool grant --peer "old putter" --worker old-putter --key "$work/putter.pub" --put >/dev/null
rm -f "$work/worker.pub" "$work/putter.pub"

# One task at a time is pending, so that each lease takes the task meant.
printf '%s\n' '{"task_id":"old-done","capability":"fixture@1","payload":{"for":"old-done"}}' | spool put >/dev/null
spool lease --worker old-local > "$work/lease.jsonl"
jq -c '{task_id, lease_id, result: {done: "old-done"}}' "$work/lease.jsonl" | spool ack >/dev/null
rm -f "$work/lease.jsonl"
printf '%s\n' '{"task_id":"old-leased","capability":"fixture@1","payload":{"for":"old-leased"}}' | spool put >/dev/null
spool lease --worker old-worker >/dev/null

rm -f "$work/spool/.spool.lock"
COPYFILE_DISABLE=1 tar --format ustar --numeric-owner -cf "$output" -C "$work" spool home
