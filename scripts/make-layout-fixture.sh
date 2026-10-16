#!/usr/bin/env bash
# Make test/fixtures/spool-0.0.2-layout.tar: a spool written by a 0.0.2
# binary, whose done tasks are filed under the lease that finished them, for
# test.sh to prove that this layout is migrated (ADR 0018).
#
#   scripts/make-layout-fixture.sh SPOOL_0.0.2_BINARY OUTPUT.tar
#
# The binary must be 0.0.2 as released, before ADR 0018: built from
# 2cf5b96, for instance. The spool holds a task in every state, a task with
# retried failure history, and a task whose ID looks like a lease ID.
set -euo pipefail

binary=$1
output=$2
test "$("$binary" --version)" = "spool 0.0.2"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
spool() { "$binary" --dir "$work/spool" "$@"; }

task() { printf '{"task_id":"%s","capability":"fixture@1","payload":{"for":"%s"}}\n' "$1" "$1"; }
lease_of() { spool lease --worker fixture-worker | jq -r '.lease_id'; }
ack() { jq -nc --arg task "$1" --arg lease "$2" '{task_id:$task,lease_id:$lease,result:{done:$task}}' | spool ack >/dev/null; }
fail() { jq -nc --arg task "$1" --arg lease "$2" '{task_id:$task,lease_id:$lease,reason:"fixture"}' | spool fail "${@:3}" >/dev/null; }

spool init
# One task at a time is pending, so that each lease takes the task meant.
task m-done | spool put >/dev/null
ack m-done "$(lease_of)"
task lease_1_2_x | spool put >/dev/null
ack lease_1_2_x "$(lease_of)"
task m-retried | spool put >/dev/null
fail m-retried "$(lease_of)"
ack m-retried "$(lease_of)"
task m-failed | spool put >/dev/null
fail m-failed "$(lease_of)" --no-retry
task m-leased | spool put >/dev/null
lease_of >/dev/null
task m-pending | spool put >/dev/null

rm -f "$work/spool/.spool.lock"
COPYFILE_DISABLE=1 tar --format ustar --numeric-owner -cf "$output" -C "$work/spool" .
