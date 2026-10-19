#!/usr/bin/env bash
set -euo pipefail

# Say where the suite stopped. The trap also fires where a failure is expected
# and errexit is off, so it speaks only while errexit is on.
set -E
trap 'if [[ $- == *e* ]]; then echo "test.sh: line $LINENO failed: $BASH_COMMAND" >&2; fi' ERR

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

checks=0
check() { checks=$((checks + 1)); }

spool_binary=${SPOOL:-$work/spool-bin}
if [[ -z ${SPOOL:-} ]]; then
  ghc_flags=(-O1 -threaded -Wall -Werror
    -package aeson -package bytestring -package crypton -package directory
    -package filepath -package memory -package process -package text -package time
    -package unix)
  if [[ -n ${SPOOL_GHC_PACKAGE_ENV:-} ]]; then
    ghc_flags+=(-package-env "$SPOOL_GHC_PACKAGE_ENV")
  fi
  mkdir "$work/hs"
  ghc "${ghc_flags[@]}" -i"$here/src" -outputdir "$work/hs" -o "$spool_binary" \
    "$here/app/Main.hs" >/dev/null
fi
test -x "$spool_binary" || { echo "set SPOOL to a compiled spool binary" >&2; exit 2; }
test "$($spool_binary --version)" = "spool 0.0.4"; check

# Files the suite reads, beside it or where the flake check puts them.
fixtures=${SPOOL_FIXTURES:-$here/test/fixtures}
test -f "$fixtures/spool-0.0.2-layout.tar"

spool() { "$spool_binary" --dir "$work/spool" "$@"; }

# Capture an exit status without letting errexit hide the result.
expect_exit() {
  local expected=$1 actual
  shift
  set +e
  "$@" >"$work/exit.stdout" 2>"$work/exit.stderr"
  actual=$?
  set -e
  test "$actual" -eq "$expected"
  check
}

spool init

task_one='{"task_id":"task-one","capability":"classify@1","payload":{"input":"one","parameters":{"mode":"preview"}}}'
task_two='{"task_id":"task-two","capability":"classify@1","payload":{"input":"two"}}'

printf '%s\n%s\n' "$task_one" "$task_two" | spool put > "$work/put.jsonl"
test "$(jq -r '.status' "$work/put.jsonl" | tr '\n' ' ')" = "inserted inserted "; check

printf '%s\n' "$task_one" | spool put | jq -e 'select(.status == "existing" and .task_id == "task-one")' >/dev/null; check

# A conflicting body is rejected with the protocol's conflict exit code.
set +e
printf '%s\n' '{"task_id":"task-one","capability":"classify@1","payload":{"different":true}}' | spool put >/dev/null 2>&1
conflict_exit=$?
set -e
test "$conflict_exit" -eq 3; check

# The whole envelope, including capability, is part of equal-task idempotency:
# the same task_id with the same payload but a different capability conflicts.
set +e
printf '%s\n' '{"task_id":"task-one","capability":"classify@2","payload":{"input":"one","parameters":{"mode":"preview"}}}' | spool put >/dev/null 2>&1
capability_conflict_exit=$?
set -e
test "$capability_conflict_exit" -eq 3; check

# Capability grammar is checked but capability names are not interpreted.
if printf '%s\n' '{"task_id":"cap-missing","payload":{}}' | spool put >/dev/null 2>&1; then
  echo "task without a capability field was accepted" >&2; exit 1
fi
check
if printf '%s\n' '{"task_id":"cap-no-version","capability":"onlyname","payload":{}}' | spool put >/dev/null 2>&1; then
  echo "capability without a version was accepted" >&2; exit 1
fi
check
if printf '%s\n' '{"task_id":"cap-empty-name","capability":"@1","payload":{}}' | spool put >/dev/null 2>&1; then
  echo "capability with an empty name was accepted" >&2; exit 1
fi
check
if printf '%s\n' '{"task_id":"cap-empty-version","capability":"classify@","payload":{}}' | spool put >/dev/null 2>&1; then
  echo "capability with an empty version was accepted" >&2; exit 1
fi
check
if printf '%s\n' '{"task_id":"cap-space","capability":"bad name@1","payload":{}}' | spool put >/dev/null 2>&1; then
  echo "capability containing a space was accepted" >&2; exit 1
fi
check
if printf '%s\n' '{"task_id":"cap-slash","capability":"bad/name@1","payload":{}}' | spool put >/dev/null 2>&1; then
  echo "capability containing a slash was accepted" >&2; exit 1
fi
check
if printf '%s\n' '{"task_id":"cap-version-dash","capability":"name@1-2","payload":{}}' | spool put >/dev/null 2>&1; then
  echo "capability version containing a dash was accepted" >&2; exit 1
fi
check

# Every name has a length. At the limit a task is put and leased; one past it
# is malformed input. Without the limit a task can be put whose lease's file
# name is longer than a file name may be, and then never leased.
spooln() { "$spool_binary" --dir "$work/names" "$@"; }
spooln init
name_128=$(printf 'n%.0s' {1..128})
name_129=$(printf 'n%.0s' {1..129})
test "${#name_128}" -eq 128; check
test "${#name_129}" -eq 129; check
printf '{"task_id":"%s","capability":"c@1","payload":{}}\n' "$name_128" \
  | spooln put | jq -e '.status == "inserted"' >/dev/null; check
spooln lease --worker "$(printf 'w%.0s' {1..64})" \
  | jq -e --arg task "$name_128" '.task_id == $task' >/dev/null; check
set +e
printf '{"task_id":"%s","capability":"c@1","payload":{}}\n' "$name_129" \
  | spooln put >/dev/null 2>&1
long_task_exit=$?
printf '{"task_id":"t","capability":"%s@1","payload":{}}\n' "$(printf 'c%.0s' {1..127})" \
  | spooln put >/dev/null 2>&1
long_capability_exit=$?
set -e
test "$long_task_exit" -eq 2; check
test "$long_capability_exit" -eq 2; check
expect_exit 2 spooln lease --worker "$(printf 'w%.0s' {1..65})"
expect_exit 2 spooln lease --worker 'two words'
expect_exit 2 spooln lease --worker 'Ł'
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAE' \
  > "$work/names-key.pub"
expect_exit 2 env HOME="$work/names-home" "$spool_binary" --dir "$work/names" grant \
  --peer "$(printf 'p%.0s' {1..129})" --worker w --key "$work/names-key.pub"
env HOME="$work/names-home" "$spool_binary" --dir "$work/names" grant \
  --peer "$(printf 'p%.0s' {1..128})" --worker w --key "$work/names-key.pub" \
  | jq -e '.peer | length == 128' >/dev/null; check
spooln status --json | jq -e '.pending == 0 and .leased == 1' >/dev/null; check

# Payloads are opaque JSON values, including null and arrays.  This separate
# store keeps the boundary cases out of the lease-count assertions below.
spoolb() { "$spool_binary" --dir "$work/boundaries" "$@"; }
spoolb init
printf '%s\n%s\n' \
  '{"task_id":"payload-null","capability":"opaque.name@1.2","payload":null}' \
  '{"task_id":"payload-array","capability":"opaque-name@2","payload":[1,"two",false]}' \
  | spoolb put | jq -s -e 'length == 2 and all(.[]; .status == "inserted")' >/dev/null; check
spoolb lease --worker boundary-worker --count 2 > "$work/boundary-leases.jsonl"
test "$(wc -l < "$work/boundary-leases.jsonl" | tr -d ' ')" = 2; check
while IFS= read -r lease; do
  boundary_ack=$(jq -nc --arg task "$(jq -r '.task_id' <<<"$lease")" \
    --arg lease "$(jq -r '.lease_id' <<<"$lease")" \
    '{task_id:$task,lease_id:$lease,result:{boundary:true}}')
  printf '%s\n' "$boundary_ack" | spoolb ack >/dev/null
done < "$work/boundary-leases.jsonl"
spoolb results | jq -s -e 'length == 2 and all(.[]; .result == {boundary:true})' >/dev/null; check

spool lease --worker local --count 2 > "$work/leases.jsonl"
test "$(wc -l < "$work/leases.jsonl" | tr -d ' ')" = 2; check
first_lease=$(jq -r '.lease_id' "$work/leases.jsonl" | head -n 1)
first_task=$(jq -r '.task_id' "$work/leases.jsonl" | head -n 1)
second_lease=$(jq -r '.lease_id' "$work/leases.jsonl" | tail -n 1)
second_task=$(jq -r '.task_id' "$work/leases.jsonl" | tail -n 1)
test -n "$first_lease"; check
test -n "$first_task"; check
jq -se '.[0].capability == "classify@1" and .[0].payload.input == "one"' "$work/leases.jsonl" >/dev/null; check

# Ack requires its result and carries that result into the durable result.
missing_result_ack=$(jq -nc --arg task "$first_task" --arg lease "$first_lease" \
  '{task_id:$task,lease_id:$lease}')
set +e
printf '%s\n' "$missing_result_ack" | spool ack >/dev/null 2>&1
missing_result_exit=$?
set -e
test "$missing_result_exit" -eq 2; check
ack_line=$(jq -nc --arg task "$first_task" --arg lease "$first_lease" \
  '{task_id:$task,lease_id:$lease,result:{accepted:true}}')
printf '%s\n' "$ack_line" | spool ack | jq -e '.status == "acked"' >/dev/null; check
printf '%s\n' "$ack_line" | spool ack | jq -e '.status == "already_done"' >/dev/null; check
spool results | jq -s --arg task "$first_task" -e \
  'map(select(.task_id == $task)) | length == 1 and .[0].result == {accepted:true}' >/dev/null; check
# A repeated ack with a different result is not an idempotent repeat.  The
# resolved lease is fenced, and the original result remains durable.
different_ack=$(jq -nc --arg task "$first_task" --arg lease "$first_lease" \
  '{task_id:$task,lease_id:$lease,result:{accepted:false}}')
set +e
printf '%s\n' "$different_ack" | spool ack >/dev/null 2>&1
different_ack_exit=$?
set -e
test "$different_ack_exit" -eq 4; check
spool results | jq -s --arg task "$first_task" -e \
  'map(select(.task_id == $task)) | length == 1 and .[0].result == {accepted:true}' >/dev/null; check
second_ack=$(jq -nc --arg task "$second_task" --arg lease "$second_lease" \
  '{task_id:$task,lease_id:$lease,result:{accepted:true}}')
printf '%s\n' "$second_ack" | spool ack | jq -e '.status == "acked"' >/dev/null; check

# Every line is read before any is acted on, and every line is answered in
# order, a stale one too. A malformed line acts on nothing.
printf '%s\n%s\n' \
  '{"task_id":"batch-a","capability":"classify@1","payload":{}}' \
  '{"task_id":"batch-b","capability":"classify@1","payload":{}}' \
  | spool put >/dev/null
spool lease --worker batcher --count 2 > "$work/batch-leases.jsonl"
batch_a_lease=$(jq -r 'select(.task_id == "batch-a").lease_id' "$work/batch-leases.jsonl")
batch_b_lease=$(jq -r 'select(.task_id == "batch-b").lease_id' "$work/batch-leases.jsonl")
test -n "$batch_a_lease" && test -n "$batch_b_lease"; check
done_before_batch=$(spool status --json | jq -r '.done')
batch_a_ack=$(jq -nc --arg lease "$batch_a_lease" '{task_id:"batch-a",lease_id:$lease,result:1}')
batch_b_ack=$(jq -nc --arg lease "$batch_b_lease" '{task_id:"batch-b",lease_id:$lease,result:2}')
set +e
printf '%s\n%s\n' "$batch_a_ack" '{"task_id":"batch-b","lease_id":"lease_1_1_batch-b"}' \
  | spool ack > "$work/batch-malformed.out" 2>/dev/null
batch_malformed_exit=$?
set -e
test "$batch_malformed_exit" -eq 2; check
test ! -s "$work/batch-malformed.out"; check
spool status --json | jq -e --argjson n "$done_before_batch" '.done == $n' >/dev/null; check
set +e
printf '%s\n%s\n%s\n' \
  '{"task_id":"batch-a","lease_id":"lease_1_1_batch-a","result":0}' "$batch_a_ack" "$batch_b_ack" \
  | spool ack > "$work/batch.out" 2>/dev/null
batch_exit=$?
set -e
test "$batch_exit" -eq 4; check
jq -s -e --arg a "$batch_a_lease" --arg b "$batch_b_lease" \
  '. == [ {task_id:"batch-a", lease_id:"lease_1_1_batch-a", status:"stale"}
        , {task_id:"batch-a", lease_id:$a, status:"acked"}
        , {task_id:"batch-b", lease_id:$b, status:"acked"} ]' "$work/batch.out" >/dev/null; check
spool status --json | jq -e --argjson n "$done_before_batch" '.done == $n + 2' >/dev/null; check
# Every answer names its lease, including one that was already done.
printf '%s\n' "$batch_b_ack" | spool ack \
  | jq -e --arg b "$batch_b_lease" '.lease_id == $b and .status == "already_done"' >/dev/null; check

# A reclaimed lease must be re-leasable, and the old token remains fenced.
reclaim_task='{"task_id":"task-reclaim","capability":"classify@1","payload":{"input":"reclaim"}}'
printf '%s\n' "$reclaim_task" | spool put >/dev/null
spool lease --worker crash-sim > "$work/reclaim-lease.jsonl"
old_lease=$(jq -r '.lease_id' "$work/reclaim-lease.jsonl")
old_task=$(jq -r '.task_id' "$work/reclaim-lease.jsonl")
# reclaim reports each returned task as one JSON line, like every other
# command. jq -s fails on anything that is not JSON, so a bare task ID cannot
# pass.
spool reclaim --older-than 0 > "$work/reclaimed.jsonl"
jq -s -e '. == [{"status":"reclaimed","task_id":"task-reclaim"}]' \
  "$work/reclaimed.jsonl" >/dev/null; check
spool lease --worker replacement > "$work/replacement-lease.jsonl"
new_lease=$(jq -r '.lease_id' "$work/replacement-lease.jsonl")
test "$old_task" = "task-reclaim"; check
test "$new_lease" != "$old_lease"; check
old_ack=$(jq -nc --arg task "$old_task" --arg lease "$old_lease" \
  '{task_id:$task,lease_id:$lease,result:{stale:true}}')
set +e
printf '%s\n' "$old_ack" | spool ack >/dev/null 2>&1
old_ack_exit=$?
set -e
test "$old_ack_exit" -eq 4; check
new_ack=$(jq -nc --arg task "$old_task" --arg lease "$new_lease" \
  '{task_id:$task,lease_id:$lease,result:{replacement:true}}')
printf '%s\n' "$new_ack" | spool ack | jq -e '.status == "acked"' >/dev/null; check
# Resolving the replacement lease must not make the reclaimed lease look like
# an idempotent repeat.  Its token stays dead after the task is done.
set +e
printf '%s\n' "$old_ack" | spool ack >/dev/null 2>&1
late_old_ack_exit=$?
set -e
test "$late_old_ack_exit" -eq 4; check
spool results | jq -s --arg task "$old_task" --arg lease "$new_lease" -e \
  'map(select(.task_id == $task)) | length == 1
   and .[0].lease_id == $lease
   and .[0].worker == "replacement"
   and .[0].result == {replacement:true}' >/dev/null; check

# Renew resets the reclaim clock: leasing, waiting, renewing, then reclaiming
# with a threshold newer than the lease (but older than the renewal) leaves it.
renew_task='{"task_id":"task-renew","capability":"classify@1","payload":{}}'
printf '%s\n' "$renew_task" | spool put >/dev/null
spool lease --worker renewer > "$work/renew-lease.jsonl"
renew_lease=$(jq -r '.lease_id' "$work/renew-lease.jsonl")
renew_task_id=$(jq -r '.task_id' "$work/renew-lease.jsonl")
sleep 2
renew_line=$(jq -nc --arg task "$renew_task_id" --arg lease "$renew_lease" \
  '{task_id:$task,lease_id:$lease}')
printf '%s\n' "$renew_line" | spool renew | jq -e '.status == "renewed"' >/dev/null; check
spool reclaim --older-than 1 > "$work/renew-reclaimed.jsonl"
test ! -s "$work/renew-reclaimed.jsonl"; check
renew_ack=$(jq -nc --arg task "$renew_task_id" --arg lease "$renew_lease" \
  '{task_id:$task,lease_id:$lease,result:{renewed:true}}')
printf '%s\n' "$renew_ack" | spool ack | jq -e '.status == "acked"' >/dev/null; check

# A lease identifier a caller names is opaque: one that fits the grammar and
# names no lease is stale (exit 4), whatever follows "lease_"; one outside the
# grammar or longer than 200 characters is malformed (exit 2). The longest
# that fits is named too: it must be answered, not fail on its file name.
opaque_task='{"task_id":"task-opaque","capability":"classify@1","payload":{}}'
printf '%s\n' "$opaque_task" | spool put >/dev/null
for named in 'lease_x' 'lease_not-mine' "lease_$(printf 'x%.0s' {1..194})"; do
  set +e
  jq -nc --arg lease "$named" '{task_id:"task-opaque",lease_id:$lease}' \
    | spool renew >/dev/null 2>&1
  named_exit=$?
  set -e
  test "$named_exit" -eq 4; check
done
for outside in 'nolease_1' 'lease_a--b' 'lease_a/b' "lease_$(printf 'x%.0s' {1..195})"; do
  set +e
  jq -nc --arg lease "$outside" '{task_id:"task-opaque",lease_id:$lease}' \
    | spool renew >/dev/null 2>&1
  outside_exit=$?
  set -e
  test "$outside_exit" -eq 2; check
done
spool lease --worker opaque > "$work/opaque-lease.jsonl"
jq -e '.task_id == "task-opaque" and (.lease_id | test("^lease_[A-Za-z0-9._-]+$"))
  and (.leased_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))' "$work/opaque-lease.jsonl" >/dev/null; check
jq -c '{task_id, lease_id, result: {opaque: true}}' "$work/opaque-lease.jsonl" \
  | spool ack | jq -e '.status == "acked"' >/dev/null; check

# A stale renew and fail are both fenced with exit 4.
stale_renew_task='{"task_id":"task-stale-renew","capability":"classify@1","payload":{}}'
printf '%s\n' "$stale_renew_task" | spool put >/dev/null
spool lease --worker renewer2 > "$work/stale-renew-lease.jsonl"
stale_lease=$(jq -r '.lease_id' "$work/stale-renew-lease.jsonl")
stale_task_id=$(jq -r '.task_id' "$work/stale-renew-lease.jsonl")
spool reclaim --older-than 0 >/dev/null
stale_renew_line=$(jq -nc --arg task "$stale_task_id" --arg lease "$stale_lease" \
  '{task_id:$task,lease_id:$lease}')
set +e
printf '%s\n' "$stale_renew_line" | spool renew >/dev/null 2>&1
stale_renew_exit=$?
set -e
test "$stale_renew_exit" -eq 4; check
spool lease --worker renewer3 > "$work/stale-renew-release.jsonl"
stale_release=$(jq -r '.lease_id' "$work/stale-renew-release.jsonl")
stale_reack=$(jq -nc --arg task "$stale_task_id" --arg lease "$stale_release" \
  '{task_id:$task,lease_id:$lease,result:{released:true}}')
printf '%s\n' "$stale_reack" | spool ack >/dev/null

stale_fail_task='{"task_id":"task-stale-fail","capability":"classify@1","payload":{}}'
printf '%s\n' "$stale_fail_task" | spool put >/dev/null
spool lease --worker fail-old > "$work/stale-fail-lease.jsonl"
stale_fail_lease=$(jq -r '.lease_id' "$work/stale-fail-lease.jsonl")
stale_fail_task_id=$(jq -r '.task_id' "$work/stale-fail-lease.jsonl")
spool reclaim --older-than 0 >/dev/null
stale_fail_line=$(jq -nc --arg task "$stale_fail_task_id" --arg lease "$stale_fail_lease" \
  '{task_id:$task,lease_id:$lease,reason:"late"}')
set +e
printf '%s\n' "$stale_fail_line" | spool fail >/dev/null 2>&1
stale_fail_exit=$?
set -e
test "$stale_fail_exit" -eq 4; check
spool lease --worker fail-release > "$work/stale-fail-release.jsonl"
stale_fail_release=$(jq -r '.lease_id' "$work/stale-fail-release.jsonl")
stale_fail_ack=$(jq -nc --arg task "$stale_fail_task_id" --arg lease "$stale_fail_release" \
  '{task_id:$task,lease_id:$lease,result:{released:true}}')
printf '%s\n' "$stale_fail_ack" | spool ack >/dev/null

# fail with retry returns the task to pending and failures shows the reason;
# --no-retry does not return it.
fail_task='{"task_id":"task-fail","capability":"classify@1","payload":{}}'
printf '%s\n' "$fail_task" | spool put >/dev/null
spool lease --worker failer > "$work/fail-lease.jsonl"
fail_lease=$(jq -r '.lease_id' "$work/fail-lease.jsonl")
fail_task_id=$(jq -r '.task_id' "$work/fail-lease.jsonl")
fail_line=$(jq -nc --arg task "$fail_task_id" --arg lease "$fail_lease" --arg reason "boom" \
  '{task_id:$task,lease_id:$lease,reason:$reason}')
printf '%s\n' "$fail_line" | spool fail | jq -e '.status == "failed_retry"' >/dev/null; check
spool status --json | jq -e '.pending >= 1' >/dev/null; check
spool failures | jq -s --arg lease "$fail_lease" -e \
  'map(select(.lease_id == $lease)) | length == 1 and .[0].reason == "boom" and .[0].retried == true and .[0].capability == "classify@1" and .[0].worker == "failer"' \
  >/dev/null; check

spool lease --worker failer2 > "$work/fail-lease2.jsonl"
fail_lease2=$(jq -r '.lease_id' "$work/fail-lease2.jsonl")
fail_task_id2=$(jq -r '.task_id' "$work/fail-lease2.jsonl")
test "$fail_task_id2" = "task-fail"; check
pending_while_leased=$(spool status --json | jq -r '.pending')
fail_line2=$(jq -nc --arg task "$fail_task_id2" --arg lease "$fail_lease2" --arg reason "final" \
  '{task_id:$task,lease_id:$lease,reason:$reason}')
printf '%s\n' "$fail_line2" | spool fail --no-retry | jq -e '.status == "failed"' >/dev/null; check
pending_after=$(spool status --json | jq -r '.pending')
test "$pending_after" = "$pending_while_leased"; check
spool failures | jq -s --arg lease "$fail_lease2" -e \
  'map(select(.lease_id == $lease)) | length == 1 and .[0].retried == false' >/dev/null; check
# The three reclaims above each wrote a failure record too.
spool status | grep -q 'failed=5'; check
spool status --json | jq -e '.failed == 5' >/dev/null; check

# A task has three attempts (ADR 0017). Every lease that ends without a result
# is one: a retried fail, and a reclaim, which writes a failure record of its
# own. The third is not retried, whatever ends it, and says so in its reason.
spoolr() { "$spool_binary" --dir "$work/retry-cap" "$@"; }
spoolr init
cap_lease() {
  # cap_lease TASK: lease the one pending task, which must be TASK.
  spoolr lease --worker capper > "$work/cap-lease.jsonl"
  test "$(jq -r '.task_id' "$work/cap-lease.jsonl")" = "$1"
  cap_held=$(jq -r '.lease_id' "$work/cap-lease.jsonl")
}
cap_fail() {
  # cap_fail TASK REASON [--no-retry]: fail the lease cap_lease took.
  jq -nc --arg task "$1" --arg lease "$cap_held" --arg reason "$2" \
    '{task_id:$task,lease_id:$lease,reason:$reason}' | spoolr fail ${3:+"$3"} > "$work/cap-fail.jsonl"
  cap_answer=$(jq -r '.status' "$work/cap-fail.jsonl")
}
cap_reclaim() {
  spoolr reclaim --older-than 0 > "$work/cap-reclaim.jsonl"
  cap_answer=$(jq -s -c '.' "$work/cap-reclaim.jsonl")
}
cap_records() {
  # cap_records TASK: that task's failure records, oldest first, as one array.
  spoolr failures | jq -s -c --arg task "$1" 'map(select(.task_id == $task))'
}
exhausted='; retries exhausted after 3 attempts'
reclaimed='reclaimed: not renewed within 0 s'

# Three failures: the first two go back to pending, the third does not.
printf '%s\n' '{"task_id":"cap-fails","capability":"classify@1","payload":{}}' | spoolr put >/dev/null
for attempt in 1 2; do
  cap_lease cap-fails
  cap_fail cap-fails "boom $attempt"
  test "$cap_answer" = "failed_retry"; check
done
cap_lease cap-fails
cap_fail cap-fails "boom 3"
test "$cap_answer" = "failed"; check
expect_exit 1 spoolr lease --worker capper
cap_records cap-fails | jq -e --arg last "boom 3$exhausted" \
  'length == 3 and map(.retried) == [true, true, false]
   and map(.reason) == ["boom 1", "boom 2", $last]' >/dev/null; check
spoolr status --json | jq -e '.pending == 0 and .leased == 0 and .failed == 3' >/dev/null; check

# A task put again after it failed for good starts afresh.
printf '%s\n' '{"task_id":"cap-fails","capability":"classify@1","payload":{}}' \
  | spoolr put | jq -e '.status == "inserted"' >/dev/null; check
cap_lease cap-fails
cap_fail cap-fails "again"
test "$cap_answer" = "failed_retry"; check
cap_lease cap-fails
jq -c '{task_id, lease_id, result: {fresh: true}}' "$work/cap-lease.jsonl" | spoolr ack >/dev/null

# Three reclaims: each writes a record; the third leaves the task failed.
printf '%s\n' '{"task_id":"cap-reclaims","capability":"classify@1","payload":{}}' | spoolr put >/dev/null
for attempt in 1 2; do
  cap_lease cap-reclaims
  cap_reclaim
  test "$cap_answer" = '[{"status":"reclaimed","task_id":"cap-reclaims"}]'; check
done
cap_lease cap-reclaims
cap_reclaim
test "$cap_answer" = '[{"status":"failed","task_id":"cap-reclaims"}]'; check
expect_exit 1 spoolr lease --worker capper
cap_records cap-reclaims | jq -e --arg reason "$reclaimed" --arg last "$reclaimed$exhausted" \
  'length == 3 and map(.retried) == [true, true, false] and map(.worker) == ["capper", "capper", "capper"]
   and map(.reason) == [$reason, $reason, $last]' >/dev/null; check

# Fails and reclaims count together, in either order.
printf '%s\n' '{"task_id":"cap-mixed-a","capability":"classify@1","payload":{}}' | spoolr put >/dev/null
cap_lease cap-mixed-a; cap_fail cap-mixed-a "first"
test "$cap_answer" = "failed_retry"; check
cap_lease cap-mixed-a; cap_reclaim
test "$cap_answer" = '[{"status":"reclaimed","task_id":"cap-mixed-a"}]'; check
cap_lease cap-mixed-a; cap_fail cap-mixed-a "third"
test "$cap_answer" = "failed"; check
printf '%s\n' '{"task_id":"cap-mixed-b","capability":"classify@1","payload":{}}' | spoolr put >/dev/null
cap_lease cap-mixed-b; cap_reclaim
cap_lease cap-mixed-b; cap_fail cap-mixed-b "second"
test "$cap_answer" = "failed_retry"; check
cap_lease cap-mixed-b; cap_reclaim
test "$cap_answer" = '[{"status":"failed","task_id":"cap-mixed-b"}]'; check
expect_exit 1 spoolr lease --worker capper

# --no-retry is final at the first attempt, with its reason as given.
printf '%s\n' '{"task_id":"cap-final","capability":"classify@1","payload":{}}' | spoolr put >/dev/null
cap_lease cap-final
cap_fail cap-final "hopeless" --no-retry
test "$cap_answer" = "failed"; check
cap_records cap-final | jq -e 'length == 1 and .[0].retried == false and .[0].reason == "hopeless"' >/dev/null; check

# A lease whose worker was never recorded (a crash between the lease and its
# sidecar) was never handed out: reclaim returns it with no record.
printf '%s\n' '{"task_id":"cap-unhanded","capability":"classify@1","payload":{}}' | spoolr put >/dev/null
cap_lease cap-unhanded
rm -f "$work/retry-cap/leased/$cap_held.worker"
cap_reclaim
test "$cap_answer" = '[{"status":"reclaimed","task_id":"cap-unhanded"}]'; check
test "$(cap_records cap-unhanded)" = "[]"; check
cap_lease cap-unhanded
jq -c '{task_id, lease_id, result: {unhanded: true}}' "$work/cap-lease.jsonl" | spoolr ack >/dev/null

# The decision is in the record. A last fail interrupted after its record
# leaves the lease standing; the next command follows the record and leaves
# the task failed, not pending. The state is rebuilt from the real writer's
# own files, as above.
printf '%s\n' '{"task_id":"cap-crash","capability":"classify@1","payload":{}}' | spoolr put >/dev/null
cap_lease cap-crash; cap_fail cap-crash "one"
cap_lease cap-crash; cap_reclaim
cap_lease cap-crash
mkdir "$work/cap-saved"
cp "$work/retry-cap/leased/$cap_held.json" "$work/retry-cap/leased/$cap_held.worker" "$work/cap-saved/"
cap_fail cap-crash "three"
test "$cap_answer" = "failed"; check
cp "$work/cap-saved/$cap_held.json" "$work/cap-saved/$cap_held.worker" "$work/retry-cap/leased/"
test -f "$work/retry-cap/leased/$cap_held.json"; check
spoolr status --json | jq -e '.pending == 0 and .leased == 0' >/dev/null; check
cap_records cap-crash | jq -e 'length == 3 and map(.retried) == [true, true, false]' >/dev/null; check

# Explicit --dir is mandatory; caller environment variables cannot select data.
set +e
SPOOL_DIR="$work/should-not-be-used" "$spool_binary" status >/dev/null 2>&1
implicit_dir_exit=$?
set -e
test "$implicit_dir_exit" -eq 2; check

# Invalid task envelopes fail closed with malformed-input exit 2.
set +e
printf '%s\n' '{"id":"not-a-task"}' | spool put >/dev/null 2>&1
invalid_task_exit=$?
set -e
test "$invalid_task_exit" -eq 2; check

# Refused I/O and an unreadable record must not be silently treated as empty.
printf 'not-a-directory\n' > "$work/not-a-directory"
expect_exit 75 "$spool_binary" --dir "$work/not-a-directory" status
spoolc() { "$spool_binary" --dir "$work/corrupt" "$@"; }
spoolc init
printf '{not-json}\n' > "$work/corrupt/pending/corrupt.json"
set +e
spoolc lease --worker corrupt-reader >/dev/null 2>&1
corrupt_exit=$?
set -e
# Corrupt durable state has its own loud exit, rather than looking like an
# empty queue (exit 1) or a malformed caller input (exit 2).
test "$corrupt_exit" -eq 70; check

# Record validators consume records made by the real writers, then prove that
# removing a required field is detected when the public reader reaches it.
spoolv() { "$spool_binary" --dir "$work/validated-records" "$@"; }
spoolv init
printf '%s\n' '{"task_id":"validate-result","capability":"validate@1","payload":{}}' \
  | spoolv put >/dev/null
spoolv lease --worker validator > "$work/validate-result-lease.jsonl"
validate_result_lease=$(jq -r '.lease_id' "$work/validate-result-lease.jsonl")
validate_result_ack=$(jq -nc --arg lease "$validate_result_lease" \
  '{task_id:"validate-result",lease_id:$lease,result:{ok:true}}')
printf '%s\n' "$validate_result_ack" | spoolv ack >/dev/null
jq 'del(.worker)' "$work/validated-records/results/$validate_result_lease.json" \
  > "$work/bad-result.json"
mv "$work/bad-result.json" "$work/validated-records/results/$validate_result_lease.json"
expect_exit 70 spoolv results

printf '%s\n' '{"task_id":"validate-failure","capability":"validate@1","payload":{}}' \
  | spoolv put >/dev/null
spoolv lease --worker validator > "$work/validate-failure-lease.jsonl"
validate_failure_lease=$(jq -r '.lease_id' "$work/validate-failure-lease.jsonl")
validate_failure_line=$(jq -nc --arg lease "$validate_failure_lease" \
  '{task_id:"validate-failure",lease_id:$lease,reason:"expected"}')
printf '%s\n' "$validate_failure_line" | spoolv fail --no-retry >/dev/null
jq 'del(.reason)' "$work/validated-records/failed/$validate_failure_lease.json" \
  > "$work/bad-failure.json"
mv "$work/bad-failure.json" "$work/validated-records/failed/$validate_failure_lease.json"
expect_exit 70 spoolv failures

# The record is the commit. A fail interrupted after its record was written
# leaves the lease standing beside that record; the next command, whatever it
# is, finishes the fail before it does anything. The state is rebuilt from the
# real writer's own files: the lease is set aside, failed for real, then put
# back. A repeat of the fail afterwards finds no lease and is stale.
spoolf() { "$spool_binary" --dir "$work/interrupted-fail" "$@"; }
spoolf init
printf '%s\n' '{"task_id":"interrupted-fail","capability":"validate@1","payload":{}}' \
  | spoolf put >/dev/null
spoolf lease --worker interrupted > "$work/interrupted-lease.jsonl"
interrupted_lease=$(jq -r '.lease_id' "$work/interrupted-lease.jsonl")
mkdir "$work/interrupted-saved"
cp "$work/interrupted-fail/leased/$interrupted_lease.json" \
  "$work/interrupted-fail/leased/$interrupted_lease.worker" "$work/interrupted-saved/"
first_fail=$(jq -nc --arg lease "$interrupted_lease" \
  '{task_id:"interrupted-fail",lease_id:$lease,reason:"first reason"}')
printf '%s\n' "$first_fail" | spoolf fail | jq -e '.status == "failed_retry"' >/dev/null; check
cp "$work/interrupted-saved/$interrupted_lease.json" \
  "$work/interrupted-saved/$interrupted_lease.worker" "$work/interrupted-fail/leased/"
rm -f "$work/interrupted-fail/pending/interrupted-fail.json"
test -f "$work/interrupted-fail/leased/$interrupted_lease.json"; check
test -f "$work/interrupted-fail/failed/$interrupted_lease.json"; check
# Any command finishes it: here, status, which changes nothing itself.
spoolf status --json | jq -e '.pending == 1 and .leased == 0 and .failed == 1' >/dev/null; check
test ! -e "$work/interrupted-fail/leased/$interrupted_lease.worker"; check
set +e
printf '%s\n' "$first_fail" | spoolf fail > "$work/interrupted-repeat.out" 2>/dev/null
repeat_fail_exit=$?
set -e
test "$repeat_fail_exit" -eq 4; check
jq -e '.status == "stale"' "$work/interrupted-repeat.out" >/dev/null; check
spoolf failures | jq -s --arg lease "$interrupted_lease" -e \
  'length == 1 and .[0].lease_id == $lease and .[0].reason == "first reason"
   and .[0].retried == true' >/dev/null; check
# The same, for a fail that was not to be retried: the task stays failed.
printf '%s\n' '{"task_id":"interrupted-final","capability":"validate@1","payload":{}}' \
  | spoolf put >/dev/null
spoolf lease --worker interrupted --count 2 > "$work/interrupted-final.jsonl"
final_lease=$(jq -r 'select(.task_id == "interrupted-final").lease_id' "$work/interrupted-final.jsonl")
test -n "$final_lease"; check
cp "$work/interrupted-fail/leased/$final_lease.json" \
  "$work/interrupted-fail/leased/$final_lease.worker" "$work/interrupted-saved/"
jq -nc --arg lease "$final_lease" '{task_id:"interrupted-final",lease_id:$lease,reason:"final"}' \
  | spoolf fail --no-retry >/dev/null
cp "$work/interrupted-saved/$final_lease.json" \
  "$work/interrupted-saved/$final_lease.worker" "$work/interrupted-fail/leased/"
# reclaim finishes the fail first, so it finds only the other lease to return.
spoolf reclaim --older-than 0 > "$work/interrupted-reclaim.out"
jq -s -e '. == [{task_id:"interrupted-fail", status:"reclaimed"}]' \
  "$work/interrupted-reclaim.out" >/dev/null; check
spoolf status --json | jq -e '.pending == 1 and .leased == 0 and .failed == 3' >/dev/null; check
test ! -e "$work/interrupted-fail/attachments/task-interrupted-final"; check

# An ack interrupted after its result was written is finished the same way,
# and reclaim never returns a task whose result is recorded. This task has an
# attachment, which the finished ack deletes.
spoolk() { "$spool_binary" --dir "$work/interrupted-ack" "$@"; }
spoolk init
ack_source="$work/interrupted-ack-source"
mkdir -p "$ack_source"
printf 'interrupted ack bytes\n' > "$ack_source/body"
if command -v sha256sum >/dev/null 2>&1; then
  ack_digest=$(sha256sum "$ack_source/body" | awk '{print $1}')
else
  ack_digest=$(shasum -a 256 "$ack_source/body" | awk '{print $1}')
fi
ack_size=$(wc -c < "$ack_source/body" | tr -d ' ')
mv -f "$ack_source/body" "$ack_source/$ack_digest"
jq -nc --arg digest "$ack_digest" --argjson size "$ack_size" \
  '{task_id:"interrupted-ack",capability:"validate@1",payload:{},attachments:[{sha256:$digest,size:$size}]}' \
  | spoolk put --attachments "$ack_source" >/dev/null
test -f "$work/interrupted-ack/attachments/task-interrupted-ack/$ack_digest"; check
spoolk lease --worker interrupted > "$work/interrupted-ack-lease.jsonl"
ack_lease=$(jq -r '.lease_id' "$work/interrupted-ack-lease.jsonl")
mkdir "$work/interrupted-ack-saved"
cp "$work/interrupted-ack/leased/$ack_lease.json" \
  "$work/interrupted-ack/leased/$ack_lease.worker" "$work/interrupted-ack-saved/"
cp -R "$work/interrupted-ack/attachments/task-interrupted-ack" "$work/interrupted-ack-saved/"
ack_line=$(jq -nc --arg lease "$ack_lease" '{task_id:"interrupted-ack",lease_id:$lease,result:{ok:true}}')
printf '%s\n' "$ack_line" | spoolk ack | jq -e '.status == "acked"' >/dev/null; check
cp "$work/interrupted-ack-saved/$ack_lease.json" \
  "$work/interrupted-ack-saved/$ack_lease.worker" "$work/interrupted-ack/leased/"
cp -R "$work/interrupted-ack-saved/task-interrupted-ack" "$work/interrupted-ack/attachments/"
# A done task is filed under its task ID (ADR 0018).
test -f "$work/interrupted-ack/done/interrupted-ack.json"; check
rm -f "$work/interrupted-ack/done/interrupted-ack.json"
test -f "$work/interrupted-ack/results/$ack_lease.json"; check
spoolk reclaim --older-than 0 > "$work/interrupted-ack-reclaim.out"
test ! -s "$work/interrupted-ack-reclaim.out"; check
spoolk status --json | jq -e '.pending == 0 and .leased == 0 and .done == 1' >/dev/null; check
test ! -e "$work/interrupted-ack/attachments/task-interrupted-ack"; check
spoolk results | jq -s -e 'length == 1 and .[0].result == {ok:true}' >/dev/null; check
printf '%s\n' "$ack_line" | spoolk ack | jq -e '.status == "already_done"' >/dev/null; check
set +e
jq -nc --arg lease "$ack_lease" '{task_id:"interrupted-ack",lease_id:$lease,result:{ok:false}}' \
  | spoolk ack > "$work/interrupted-ack-other.out" 2>/dev/null
other_result_exit=$?
set -e
test "$other_result_exit" -eq 4; check
jq -e '.status == "stale"' "$work/interrupted-ack-other.out" >/dev/null; check

# ADR 0018: finished work is collected, or ages out. These helpers drive the
# real writers on the spool in one directory of the work area, with one task
# pending at a time, so that each lease takes the task meant.
in_spool() { local dir=$1; shift; "$spool_binary" --dir "$work/$dir" "$@"; }
put_one() { printf '{"task_id":"%s","capability":"keep@1","payload":{}}\n' "$2" | in_spool "$1" put; }
lease_one() { in_spool "$1" lease --worker keeper | jq -r '.lease_id'; }
ack_one() {
  jq -nc --arg task "$2" --arg lease "$3" '{task_id:$task,lease_id:$lease,result:{kept:$task}}' \
    | in_spool "$1" ack
}
fail_one() {
  jq -nc --arg task "$2" --arg lease "$3" '{task_id:$task,lease_id:$lease,reason:"kept"}' \
    | in_spool "$1" fail "${@:4}"
}
collect_ids() { local dir=$1; shift; printf '{"task_id":"%s"}\n' "$@" | in_spool "$dir" collect; }
# A done task with one retried failure behind it; prints the finishing lease.
finish_with_history() {
  local lease
  put_one "$1" "$2" >/dev/null
  lease=$(lease_one "$1")
  fail_one "$1" "$2" "$lease" >/dev/null
  lease=$(lease_one "$1")
  ack_one "$1" "$2" "$lease" >/dev/null
  printf '%s\n' "$lease"
}
# Make a record as old as this many seconds before now.
age_record() {
  jq -c --arg field "$2" --argjson age "$3" '.[$field] = ((now - $age) | floor | todate)' "$1" \
    > "$work/aged.json"
  mv -f "$work/aged.json" "$1"
}
records_of() { find "$work/$1/results" "$work/$1/failed" -name "*_$2.json"; }

# collect deletes a finished task, done or finally failed, with its result
# and every failure record, and answers every line; a pending or leased task
# is not finished, and an ID the spool does not hold is unknown.
in_spool kept init
kept_done_lease=$(finish_with_history kept r-done)
put_one kept r-failed >/dev/null
fail_one kept r-failed "$(lease_one kept)" --no-retry >/dev/null
put_one kept r-leased >/dev/null
kept_leased_lease=$(lease_one kept)
put_one kept r-pending >/dev/null
in_spool kept status --json | jq -e '. == {pending:1,leased:1,done:1,failed:2}' >/dev/null; check
# A malformed line acts on nothing, the lines before it included.
set +e
printf '%s\n' '{"task_id":"r-done"}' '{"task_id":"r-failed","extra":true}' \
  | in_spool kept collect > "$work/collect-malformed.out" 2>/dev/null
collect_malformed=$?
set -e
test "$collect_malformed" -eq 2; check
test ! -s "$work/collect-malformed.out"; check
in_spool kept status --json | jq -e '. == {pending:1,leased:1,done:1,failed:2}' >/dev/null; check
collect_ids kept r-done r-failed r-pending r-leased r-never r-done > "$work/collect.out"
jq -s -e '. == [ {task_id:"r-done", status:"collected"}
               , {task_id:"r-failed", status:"collected"}
               , {task_id:"r-pending", status:"not_finished"}
               , {task_id:"r-leased", status:"not_finished"}
               , {task_id:"r-never", status:"unknown"}
               , {task_id:"r-done", status:"unknown"} ]' "$work/collect.out" >/dev/null; check
in_spool kept status --json | jq -e '. == {pending:1,leased:1,done:0,failed:0}' >/dev/null; check
in_spool kept results | jq -s -e 'length == 0' >/dev/null; check
in_spool kept failures | jq -s -e 'length == 0' >/dev/null; check
test -z "$(find "$work/kept/done" "$work/kept/results" "$work/kept/failed" "$work/kept/.task-cleanup" -type f)"; check
test -f "$work/kept/pending/r-pending.json"; check
# An acknowledgement repeated after its task was collected has nothing to
# be compared with, and is stale.
set +e
ack_one kept r-done "$kept_done_lease" > "$work/collected-ack.out" 2>/dev/null
collected_ack=$?
set -e
test "$collected_ack" -eq 4; check
jq -e '.status == "stale"' "$work/collected-ack.out" >/dev/null; check
# The dedupe window is the retention window: put again, a collected task is
# a new task.
put_one kept r-done | jq -e '.status == "inserted"' >/dev/null; check
put_one kept r-failed | jq -e '.status == "inserted"' >/dev/null; check
# A task that is pending again after a retried failure keeps its history.
ack_one kept r-leased "$kept_leased_lease" | jq -e '.status == "acked"' >/dev/null; check
in_spool kept lease --worker keeper --count 3 > "$work/kept-leases.jsonl"
retrying_lease=$(jq -r 'select(.task_id == "r-done").lease_id' "$work/kept-leases.jsonl")
fail_one kept r-done "$retrying_lease" >/dev/null
collect_ids kept r-done r-leased > "$work/collect-retrying.out"
jq -s -e '. == [ {task_id:"r-done", status:"not_finished"}
               , {task_id:"r-leased", status:"collected"} ]' "$work/collect-retrying.out" >/dev/null; check
in_spool kept failures | jq -s -e 'length == 1 and .[0].task_id == "r-done" and .[0].retried' >/dev/null; check

# gc deletes the finished tasks that finished at least so long ago, oldest
# first, and never a pending or leased task, whatever its history. Times
# are made by editing the real records against a now computed here.
in_spool aging init
put_one aging a-new >/dev/null
a_new_lease=$(lease_one aging)
ack_one aging a-new "$a_new_lease" >/dev/null
put_one aging a-old >/dev/null
a_old_lease=$(lease_one aging)
ack_one aging a-old "$a_old_lease" >/dev/null
put_one aging f-old >/dev/null
f_old_lease=$(lease_one aging)
fail_one aging f-old "$f_old_lease" --no-retry >/dev/null
put_one aging l-old >/dev/null
lease_one aging >/dev/null
put_one aging z-retrying >/dev/null
z_lease=$(lease_one aging)
fail_one aging z-retrying "$z_lease" >/dev/null
# A task that failed finally long ago and has been put again is pending.
put_one aging f-again >/dev/null
f_again_lease=$(lease_one aging)
fail_one aging f-again "$f_again_lease" --no-retry >/dev/null
put_one aging f-again | jq -e '.status == "inserted"' >/dev/null; check
age_record "$work/aging/results/$a_new_lease.json" finished_at 60
age_record "$work/aging/results/$a_old_lease.json" finished_at 3600
age_record "$work/aging/failed/$f_old_lease.json" failed_at 3000
age_record "$work/aging/failed/$z_lease.json" failed_at 7200
age_record "$work/aging/failed/$f_again_lease.json" failed_at 5000
in_spool aging gc --older-than 1800 > "$work/gc.out"
jq -s -e '. == [ {task_id:"a-old", status:"expired"}
               , {task_id:"f-old", status:"expired"} ]' "$work/gc.out" >/dev/null; check
in_spool aging status --json | jq -e '. == {pending:2,leased:1,done:1,failed:2}' >/dev/null; check
in_spool aging results | jq -s -e 'map(.task_id) == ["a-new"]' >/dev/null; check
in_spool aging failures | jq -s -e 'map(.task_id) == ["z-retrying","f-again"]' >/dev/null; check
test -f "$work/aging/pending/f-again.json"; check
test -z "$(records_of aging a-old)$(records_of aging f-old)"; check
in_spool aging gc --older-than 1800 > "$work/gc-again.out"
test ! -s "$work/gc-again.out"; check
put_one aging a-old | jq -e '.status == "inserted"' >/dev/null; check
in_spool aging gc --older-than 0 | jq -s -e '. == [{task_id:"a-new", status:"expired"}]' >/dev/null; check
in_spool aging status --json | jq -e '. == {pending:3,leased:1,done:0,failed:2}' >/dev/null; check
expect_exit 2 in_spool aging gc --older-than -1
expect_exit 2 in_spool aging gc

# put reads no done task but the one under its own ID: its cost does not
# grow with history. Every other done file is unreadable here, so a put
# that read one would fail; acknowledging, and repeating one, read none.
in_spool bomb init
for name in b-one b-two b-three; do
  put_one bomb "$name" >/dev/null
  ack_one bomb "$name" "$(lease_one bomb)" >/dev/null
done
chmod 000 "$work/bomb/done/b-one.json" "$work/bomb/done/b-three.json"
test ! -r "$work/bomb/done/b-one.json"; check
put_one bomb b-four | jq -e '.status == "inserted"' >/dev/null; check
put_one bomb b-two | jq -e '.status == "existing"' >/dev/null; check
b_four_lease=$(lease_one bomb)
ack_one bomb b-four "$b_four_lease" | jq -e '.status == "acked"' >/dev/null; check
ack_one bomb b-four "$b_four_lease" | jq -e '.status == "already_done"' >/dev/null; check
chmod 644 "$work/bomb/done/b-one.json" "$work/bomb/done/b-three.json"

# Deleting a task is committed by its marker and finished by recovery. Each
# step is made to fail on the real writer by refusing writes to the
# directory it changes: the command fails, and the next command finishes
# what the marker committed.
in_spool crash init
mkdir "$work/refused"
chmod 555 "$work/refused"
if touch "$work/refused/probe" 2>/dev/null; then
  echo "test.sh: a refused write was allowed; do not run this suite as root" >&2
  exit 1
fi
check
chmod 755 "$work/refused"
for step in done results failed; do
  finish_with_history crash "c-$step" >/dev/null
  chmod 555 "$work/crash/$step"
  expect_exit 75 collect_ids crash "c-$step"
  chmod 755 "$work/crash/$step"
  test -e "$work/crash/.task-cleanup/c-$step"; check
  in_spool crash status >/dev/null
  test ! -e "$work/crash/.task-cleanup/c-$step"; check
  test ! -e "$work/crash/done/c-$step.json"; check
  test -z "$(records_of crash "c-$step")"; check
  collect_ids crash "c-$step" | jq -e '.status == "unknown"' >/dev/null; check
done
# Before the marker, nothing has happened.
finish_with_history crash c-marker >/dev/null
chmod 555 "$work/crash/.task-cleanup"
expect_exit 75 collect_ids crash c-marker
chmod 755 "$work/crash/.task-cleanup"
test -f "$work/crash/done/c-marker.json"; check
in_spool crash results | jq -s -e 'map(select(.task_id == "c-marker")) | length == 1' >/dev/null; check
in_spool crash failures | jq -s -e 'map(select(.task_id == "c-marker")) | length == 1' >/dev/null; check
collect_ids crash c-marker | jq -e '.status == "collected"' >/dev/null; check
# Removing the marker is the last step, and recovery repeats it.
finish_with_history crash c-last >/dev/null
chmod 555 "$work/crash/done"
expect_exit 75 collect_ids crash c-last
chmod 755 "$work/crash/done"
chmod 555 "$work/crash/.task-cleanup"
expect_exit 75 in_spool crash status
chmod 755 "$work/crash/.task-cleanup"
test -e "$work/crash/.task-cleanup/c-last"; check
test ! -e "$work/crash/done/c-last.json"; check
test -z "$(records_of crash c-last)"; check
in_spool crash status --json | jq -e '. == {pending:0,leased:0,done:0,failed:0}' >/dev/null; check
test ! -e "$work/crash/.task-cleanup/c-last"; check

# A spool written by 0.0.2 files a done task under the lease that finished
# it. The fixture is such a spool, made by scripts/make-layout-fixture.sh
# running the 0.0.2 binary; the first command migrates it.
mkdir "$work/migrated"
tar -xf "$fixtures/spool-0.0.2-layout.tar" -C "$work/migrated"
test ! -e "$work/migrated/.spool-layout"; check
test "$(find "$work/migrated/done" -name 'lease_*' | wc -l | tr -d ' ')" = 3; check
in_spool migrated status --json | jq -e '. == {pending:1,leased:1,done:3,failed:2}' >/dev/null; check
test -f "$work/migrated/.spool-layout"; check
test "$(cd "$work/migrated/done" && ls | tr '\n' ' ')" = "lease_1_2_x.json m-done.json m-retried.json "; check
# An equal task is still a repeat, and a different one a conflict.
printf '%s\n' '{"task_id":"m-done","capability":"fixture@1","payload":{"for":"m-done"}}' \
  | in_spool migrated put | jq -e '.status == "existing"' >/dev/null; check
printf '%s\n' '{"task_id":"lease_1_2_x","capability":"fixture@1","payload":{"for":"lease_1_2_x"}}' \
  | in_spool migrated put | jq -e '.status == "existing"' >/dev/null; check
set +e
printf '%s\n' '{"task_id":"m-done","capability":"fixture@1","payload":{}}' \
  | in_spool migrated put >/dev/null 2>&1
migrated_conflict=$?
set -e
test "$migrated_conflict" -eq 3; check
# The acknowledgement that finished a task is still answered as a repeat,
# and the lease in flight is acknowledged and filed under its task.
m_done_lease=$(in_spool migrated results | jq -r 'select(.task_id == "m-done").lease_id')
jq -nc --arg lease "$m_done_lease" '{task_id:"m-done",lease_id:$lease,result:{done:"m-done"}}' \
  | in_spool migrated ack | jq -e '.status == "already_done"' >/dev/null; check
m_leased_lease=$(basename "$(find "$work/migrated/leased" -name '*.json')" .json)
ack_one migrated m-leased "$m_leased_lease" | jq -e '.status == "acked"' >/dev/null; check
test -f "$work/migrated/done/m-leased.json"; check
collect_ids migrated m-done m-pending | jq -s -e \
  '. == [{task_id:"m-done", status:"collected"}, {task_id:"m-pending", status:"not_finished"}]' >/dev/null; check
in_spool migrated gc --older-than 0 | jq -s -e \
  'map(.task_id) | sort == ["lease_1_2_x","m-failed","m-leased","m-retried"]' >/dev/null; check
in_spool migrated status --json | jq -e '. == {pending:1,leased:0,done:0,failed:0}' >/dev/null; check
# What a file holds decides, so a migration run again renames nothing, not
# even the task whose ID looks like a lease's.
mkdir "$work/migrated-again"
tar -xf "$fixtures/spool-0.0.2-layout.tar" -C "$work/migrated-again"
in_spool migrated-again status >/dev/null
rm -f "$work/migrated-again/.spool-layout"
in_spool migrated-again status >/dev/null
test "$(cd "$work/migrated-again/done" && ls | tr '\n' ' ')" = "lease_1_2_x.json m-done.json m-retried.json "; check
# A layout this binary does not know is corrupt state.
printf 'unknown\n' > "$work/migrated-again/.spool-layout"
expect_exit 70 in_spool migrated-again status

# results and failures are listed oldest first, by when each was recorded.
# The leases are resolved in the reverse of the order they were taken, so the
# order of the files is not the order of the times and cannot pass for it.
spoolo() { "$spool_binary" --dir "$work/ordered" "$@"; }
spoolo init
printf '%s\n' \
  '{"task_id":"order-a","capability":"validate@1","payload":{}}' \
  '{"task_id":"order-b","capability":"validate@1","payload":{}}' \
  '{"task_id":"order-c","capability":"validate@1","payload":{}}' \
  '{"task_id":"order-d","capability":"validate@1","payload":{}}' \
  | spoolo put >/dev/null
spoolo lease --worker orderly --count 4 > "$work/order-leases.jsonl"
test "$(jq -r '.task_id' "$work/order-leases.jsonl" | tr '\n' ' ')" \
  = "order-a order-b order-c order-d "; check
order_line() {
  # order_line TASK FIELD VALUE
  jq -c --arg task "$1" --arg field "$2" --argjson value "$3" \
    'select(.task_id == $task) | {task_id, lease_id, ($field): $value}' \
    "$work/order-leases.jsonl"
}
order_line order-b result '{}' | spoolo ack >/dev/null
order_line order-d reason '"later"' | spoolo fail --no-retry >/dev/null
sleep 1.1
order_line order-a result '{}' | spoolo ack >/dev/null
order_line order-c reason '"latest"' | spoolo fail --no-retry >/dev/null
test "$(ls "$work/ordered/results" | tr '\n' ' ' | sed 's/lease_[0-9]*_[0-9]*_//g')" \
  = "order-a.json order-b.json "; check
test "$(spoolo results | jq -r '.task_id' | tr '\n' ' ')" = "order-b order-a "; check
test "$(spoolo failures | jq -r '.task_id' | tr '\n' ' ')" = "order-d order-c "; check

spools() { "$spool_binary" --dir "$work/corrupt-sidecars" "$@"; }
spools init
printf '%s\n' '{"task_id":"bad-renewal","capability":"validate@1","payload":{}}' \
  | spools put >/dev/null
spools lease --worker validator > "$work/bad-renewal-lease.jsonl"
bad_renewal_lease=$(jq -r '.lease_id' "$work/bad-renewal-lease.jsonl")
printf 'not-an-integer\n' > "$work/corrupt-sidecars/leased/$bad_renewal_lease.renewed"
expect_exit 70 spools reclaim --older-than 0

#############################################################################
# The worker: spool work maps a leased capability to a configured executable.
#############################################################################

bin="$work/bin"
mkdir -p "$bin"

cat > "$bin/echo-classify" <<'SCRIPT'
#!/bin/sh
payload=$(cat)
printf '{"echoed":%s}\n' "$payload"
SCRIPT
chmod +x "$bin/echo-classify"

cat > "$bin/crash-three" <<'SCRIPT'
#!/bin/sh
cat >/dev/null
echo "deliberate crash for the spool worker test" >&2
exit 3
SCRIPT
chmod +x "$bin/crash-three"

cat > "$bin/hopeless" <<'SCRIPT'
#!/bin/sh
cat >/dev/null
echo "this payload can never be classified" >&2
exit 65
SCRIPT
chmod +x "$bin/hopeless"

grandchild_pidfile="$work/grandchild-pid"
cat > "$bin/sleeper" <<SCRIPT
#!/bin/sh
cat >/dev/null
# A grandchild in the same process group, so the timeout kill can be proven
# to reach more than the immediate child.
sh -c 'echo \$\$ > "$grandchild_pidfile"; sleep 30' &
sleep 5
printf '{"slept":true}\n'
SCRIPT
chmod +x "$bin/sleeper"

stubborn_pidfile="$work/stubborn-pid"
stubborn_finished="$work/stubborn-finished"
cat > "$bin/stubborn" <<SCRIPT
#!/bin/sh
# Ignores SIGTERM, as do the sleeps it starts, so only SIGKILL ends it early.
trap '' TERM
cat >/dev/null
echo \$\$ > "$stubborn_pidfile"
i=0
while [ "\$i" -lt 150 ]; do
  sleep 0.1
  i=\$((i + 1))
done
: > "$stubborn_finished"
printf '{"stubborn":true}\n'
SCRIPT
chmod +x "$bin/stubborn"

cat > "$bin/ignores-stdin" <<'SCRIPT'
#!/bin/sh
# Never reads its payload, so a payload too big for the pipe stays unwritten.
sleep 3
printf '{"ignored":true}\n'
SCRIPT
chmod +x "$bin/ignores-stdin"

leftover_pidfile="$work/leftover-pid"
leftover_finished="$work/leftover-finished"
cat > "$bin/leaves-one-behind" <<SCRIPT
#!/bin/sh
cat >/dev/null
# Starts a process that ignores SIGTERM and holds this script's output open,
# then answers and exits as if nothing were left running.
sh -c 'trap "" TERM; echo \$\$ > "$leftover_pidfile"
  i=0; while [ "\$i" -lt 150 ]; do sleep 0.1; i=\$((i + 1)); done
  : > "$leftover_finished"' &
i=0
while [ ! -s "$leftover_pidfile" ] && [ "\$i" -lt 50 ]; do
  sleep 0.1
  i=\$((i + 1))
done
printf '{"answered":true}\n'
SCRIPT
chmod +x "$bin/leaves-one-behind"

interrupted_pidfile="$work/interrupted-pid"
interrupted_asked="$work/interrupted-asked"
cat > "$bin/runs-until-stopped" <<SCRIPT
#!/bin/sh
# Notes that it was asked to stop, and stops.
trap ': > "$interrupted_asked"; exit 0' TERM
cat >/dev/null
echo \$\$ > "$interrupted_pidfile"
i=0
while [ "\$i" -lt 300 ]; do
  sleep 0.1
  i=\$((i + 1))
done
printf '{"finished":true}\n'
SCRIPT
chmod +x "$bin/runs-until-stopped"

cat > "$bin/big-output" <<'SCRIPT'
#!/bin/sh
cat >/dev/null
yes 0123456789 | head -c 200000
SCRIPT
chmod +x "$bin/big-output"

cat > "$bin/env-check" <<'SCRIPT'
#!/bin/sh
cat >/dev/null
if [ -n "${HOME:-}" ]; then
  printf '{"has_home":true}\n'
else
  printf '{"has_home":false}\n'
fi
SCRIPT
chmod +x "$bin/env-check"

cat > "$bin/not-json" <<'SCRIPT'
#!/bin/sh
cat >/dev/null
printf 'not json at all\n'
SCRIPT
chmod +x "$bin/not-json"

lockdir="$work/exclusive-lock"
cat > "$bin/no-overlap" <<SCRIPT
#!/bin/sh
cat >/dev/null
if ! mkdir "$lockdir" 2>/dev/null; then
  exit 9
fi
sleep 0.3
rmdir "$lockdir"
printf '{"ok":true}\n'
SCRIPT
chmod +x "$bin/no-overlap"

startdir="$work/started"
mkdir -p "$startdir"
releasefile="$work/release"
cat > "$bin/wait-for-release" <<SCRIPT
#!/bin/sh
cat >/dev/null
: > "$startdir/started-\$\$"
i=0
while [ ! -f "$releasefile" ] && [ "\$i" -lt 100 ]; do
  sleep 0.1
  i=\$((i + 1))
done
printf '{"released":true}\n'
SCRIPT
chmod +x "$bin/wait-for-release"

late_start="$work/late-started"
late_release="$work/late-release"
cat > "$bin/wait-for-late-release" <<SCRIPT
#!/bin/sh
cat >/dev/null
: > "$late_start"
i=0
while [ ! -f "$late_release" ] && [ "\$i" -lt 100 ]; do
  sleep 0.1
  i=\$((i + 1))
done
printf '{"late":true}\n'
SCRIPT
chmod +x "$bin/wait-for-late-release"

# The executables are given the tools this suite itself runs with, and
# nothing else. A fixed /usr/bin:/bin has no cat inside a Nix sandbox on
# Linux, where the tools live in the store.
worker_path=$PATH

worker_config() {
  # worker_config CAPABILITY EXEC TIMEOUT MAXBYTES [MAX_CONCURRENT] [MAX_OUTPUT_BYTES]
  jq -nc --arg cap "$1" --arg exec "$2" --argjson timeout "$3" --argjson maxbytes "$4" \
    --argjson concurrent "${5:-1}" --argjson maxoutput "${6:-65536}" \
    --arg path "$worker_path" \
    '{max_concurrent: $concurrent, renew_seconds: 30, env: {PATH: $path},
      capabilities: {($cap): {exec: $exec, args: [], timeout_seconds: $timeout,
        max_payload_bytes: $maxbytes, max_output_bytes: $maxoutput}}}'
}

spoolw() { "$spool_binary" --dir "$work/workspool" "$@"; }
spoolw init

# A retried failure returns its task to pending, so lease and acknowledge it
# before each later, isolated worker scenario.
drain_pending() {
  local expected="$1"
  spoolw lease --worker drainer --count 1 > "$work/drain.jsonl"
  local drained_task drained_lease drain_ack
  drained_task=$(jq -r '.task_id' "$work/drain.jsonl")
  drained_lease=$(jq -r '.lease_id' "$work/drain.jsonl")
  test "$drained_task" = "$expected"
  drain_ack=$(jq -nc --arg task "$drained_task" --arg lease "$drained_lease" \
    '{task_id:$task,lease_id:$lease,result:{drained:true}}')
  printf '%s\n' "$drain_ack" | spoolw ack >/dev/null
}

# work --config FILE --show prints the resolved configuration and exits 0,
# with no --dir needed.
show_config="$work/show-config.json"
worker_config "classify@1" "$bin/echo-classify" 5 1024 > "$show_config"
show_output=$("$spool_binary" work --config "$show_config" --show)
echo "$show_output" | jq -e --arg path "$worker_path" \
  '.max_concurrent == 1 and .renew_seconds == 30 and .env.PATH == $path
   and .capabilities["classify@1"].exec == "'"$bin"'/echo-classify"
   and .capabilities["classify@1"].timeout_seconds == 5
   and .capabilities["classify@1"].max_payload_bytes == 1024
   and .capabilities["classify@1"].max_output_bytes == 65536
   and .capabilities["classify@1"].args == []' >/dev/null
check

# A configured integer is used as written or refused, never wrapped. Each
# limit is accepted at its largest value and refused one above it. The files
# are written by hand because jq rounds integers this large.
limit_config() {
  # limit_config MAX_CONCURRENT RENEW TIMEOUT MAX_PAYLOAD MAX_OUTPUT
  printf '{"max_concurrent":%s,"renew_seconds":%s,"capabilities":{"classify@1":{"exec":"%s","timeout_seconds":%s,"max_payload_bytes":%s,"max_output_bytes":%s}}}\n' \
    "$1" "$2" "$bin/echo-classify" "$3" "$4" "$5" > "$work/limit-config.json"
}
int_max=9223372036854775807
int_over=9223372036854775808
seconds_max=9223372036854
seconds_over=9223372036855
test "$int_max" != "$int_over"; check
test "$seconds_max" != "$seconds_over"; check
limit_config "$int_max" "$seconds_max" "$seconds_max" "$int_max" "$int_max"
"$spool_binary" work --config "$work/limit-config.json" --show > "$work/limit-show.json"
grep -F "\"max_concurrent\":$int_max," "$work/limit-show.json" >/dev/null; check
grep -F "\"renew_seconds\":$seconds_max}" "$work/limit-show.json" >/dev/null; check
grep -F "\"timeout_seconds\":$seconds_max}" "$work/limit-show.json" >/dev/null; check
grep -F "\"max_payload_bytes\":$int_max," "$work/limit-show.json" >/dev/null; check
grep -F "\"max_output_bytes\":$int_max," "$work/limit-show.json" >/dev/null; check
limit_config "$int_over" 30 5 1024 1024
expect_exit 2 "$spool_binary" work --config "$work/limit-config.json" --show
limit_config 1 "$seconds_over" 5 1024 1024
expect_exit 2 "$spool_binary" work --config "$work/limit-config.json" --show
limit_config 1 30 "$seconds_over" 1024 1024
expect_exit 2 "$spool_binary" work --config "$work/limit-config.json" --show
limit_config 1 30 5 "$int_over" 1024
expect_exit 2 "$spool_binary" work --config "$work/limit-config.json" --show
limit_config 1 30 5 1024 "$int_over"
expect_exit 2 "$spool_binary" work --config "$work/limit-config.json" --show
# A value that wraps to a small positive number is the quiet case: 2^64 + 1
# must not become a one-second timeout.
limit_config 1 30 18446744073709551617 1024 1024
expect_exit 2 "$spool_binary" work --config "$work/limit-config.json" --show

# Success is an end-to-end chain: configured executable output becomes the
# ack result and remains available through results.
success_task='{"task_id":"work-success","capability":"classify@1","payload":{"n":1}}'
printf '%s\n' "$success_task" | spoolw put >/dev/null
worker_config "classify@1" "$bin/echo-classify" 5 1024 > "$work/success-config.json"
spoolw work --worker w1 --config "$work/success-config.json" --max-tasks 1
spoolw status --json | jq -e '.pending == 0 and .leased == 0 and .done == 1' >/dev/null; check
spoolw results | jq -s --arg task work-success -e \
  'map(select(.task_id == $task)) | length == 1 and .[0].capability == "classify@1"
   and .[0].worker == "w1" and .[0].result == {"echoed":{"n":1}}' >/dev/null
check

# A script exiting 3 fails with retry and the reason names the exit code and
# stderr.
crash_task='{"task_id":"work-crash","capability":"crash@1","payload":{}}'
printf '%s\n' "$crash_task" | spoolw put >/dev/null
worker_config "crash@1" "$bin/crash-three" 5 1024 > "$work/crash-config.json"
spoolw work --worker w1 --config "$work/crash-config.json" --max-tasks 1
spoolw status --json | jq -e '.pending == 1 and .failed >= 1' >/dev/null; check
spoolw failures | jq -s --arg task work-crash -e \
  'map(select(.task_id == $task)) | length == 1 and .[0].retried == true
   and (.[0].reason | test("exit 3")) and (.[0].reason | test("deliberate crash"))' >/dev/null
check
drain_pending "work-crash"

# Any other failing exit is retried up to the cap: three runs, then failed.
printf '%s\n' '{"task_id":"work-crash-cap","capability":"crash@1","payload":{}}' | spoolw put >/dev/null
spoolw work --worker w1 --config "$work/crash-config.json" --max-tasks 5
spoolw status --json | jq -e '.pending == 0 and .leased == 0' >/dev/null; check
spoolw failures | jq -s --arg task work-crash-cap -e \
  'map(select(.task_id == $task)) | length == 3 and map(.retried) == [true, true, false]
   and (.[2].reason | startswith("exit 3: "))
   and (.[2].reason | endswith("; retries exhausted after 3 attempts"))' >/dev/null
check

# Exit 65 says the task can never succeed: one run, failed, with its stderr.
printf '%s\n' '{"task_id":"work-hopeless","capability":"hopeless@1","payload":{}}' | spoolw put >/dev/null
worker_config "hopeless@1" "$bin/hopeless" 5 1024 > "$work/hopeless-config.json"
spoolw work --worker w1 --config "$work/hopeless-config.json" --max-tasks 5
spoolw status --json | jq -e '.pending == 0 and .leased == 0' >/dev/null; check
spoolw failures | jq -s --arg task work-hopeless -e \
  'map(select(.task_id == $task)) | length == 1 and .[0].retried == false
   and (.[0].reason | startswith("exit 65: "))
   and (.[0].reason | test("can never be classified"))' >/dev/null
check

# Unknown capability fails without retry.
unknown_task='{"task_id":"work-unknown","capability":"mystery@9","payload":{}}'
printf '%s\n' "$unknown_task" | spoolw put >/dev/null
spoolw work --worker w1 --config "$work/success-config.json" --max-tasks 1
spoolw failures | jq -s --arg task work-unknown -e \
  'map(select(.task_id == $task)) | length == 1 and .[0].retried == false
   and (.[0].reason | test("not in the worker configuration"))' >/dev/null
check
unknown_pending=$(spoolw status --json | jq -r '.pending')
test "$unknown_pending" = "0"; check

# Oversize payload fails without retry.
oversize_task='{"task_id":"work-oversize","capability":"oversize@1","payload":{"data":"0123456789abcdef"}}'
printf '%s\n' "$oversize_task" | spoolw put >/dev/null
worker_config "oversize@1" "$bin/echo-classify" 5 8 > "$work/oversize-config.json"
spoolw work --worker w1 --config "$work/oversize-config.json" --max-tasks 1
spoolw failures | jq -s --arg task work-oversize -e \
  'map(select(.task_id == $task)) | length == 1 and .[0].retried == false
   and (.[0].reason | test("max_payload_bytes"))' >/dev/null
check

# A timeout (script sleeping past timeout_seconds: 1) fails with the timeout reason.
timeout_task='{"task_id":"work-timeout","capability":"sleeper@1","payload":{}}'
printf '%s\n' "$timeout_task" | spoolw put >/dev/null
worker_config "sleeper@1" "$bin/sleeper" 1 1024 > "$work/timeout-config.json"
spoolw work --worker w1 --config "$work/timeout-config.json" --max-tasks 1
spoolw failures | jq -s --arg task work-timeout -e \
  'map(select(.task_id == $task)) | length == 1 and .[0].retried == true
   and (.[0].reason | test("timeout after 1 s"))' >/dev/null
check
drain_pending "work-timeout"

# The timeout kill reaches the whole process group, not just the immediate
# child: the grandchild the sleeper script forked does not outlive it.
i=0
while [ ! -s "$grandchild_pidfile" ] && [ "$i" -lt 50 ]; do
  sleep 0.1
  i=$((i + 1))
done
test -s "$grandchild_pidfile"; check
grandchild_pid=$(cat "$grandchild_pidfile")
grandchild_dead=1
i=0
while [ "$i" -lt 50 ]; do
  if ! kill -0 "$grandchild_pid" 2>/dev/null; then
    grandchild_dead=0
    break
  fi
  sleep 0.1
  i=$((i + 1))
done
test "$grandchild_dead" -eq 0; check

# The timeout holds against a program that ignores SIGTERM: it is killed
# outright after the grace period, long before its own 15 seconds are up.
# The marker it writes on a natural exit is the proof it never got there.
stubborn_task='{"task_id":"work-stubborn","capability":"stubborn@1","payload":{}}'
printf '%s\n' "$stubborn_task" | spoolw put >/dev/null
worker_config "stubborn@1" "$bin/stubborn" 1 1024 > "$work/stubborn-config.json"
spoolw work --worker w1 --config "$work/stubborn-config.json" --max-tasks 1
test -s "$stubborn_pidfile"; check
test ! -e "$stubborn_finished"; check
if kill -0 "$(cat "$stubborn_pidfile")" 2>/dev/null; then
  echo "a capability ignoring SIGTERM outlived its timeout" >&2; exit 1
fi
check
spoolw failures | jq -s --arg task work-stubborn -e \
  'map(select(.task_id == $task)) | length == 1 and .[0].retried == true
   and (.[0].reason | test("timeout after 1 s"))' >/dev/null
check
drain_pending "work-stubborn"

# The timeout holds while the payload is still being written. The program
# never reads it and it is too big for the pipe, so the write cannot finish;
# the run is timed out all the same, not held until the program lets go.
head -c 200000 /dev/zero | tr '\0' 'x' > "$work/unread-data"
jq -Rnc --rawfile data "$work/unread-data" \
  '{task_id:"work-unread",capability:"unread@1",payload:{data:$data}}' \
  | spoolw put >/dev/null
worker_config "unread@1" "$bin/ignores-stdin" 1 1000000 > "$work/unread-config.json"
spoolw work --worker w1 --config "$work/unread-config.json" --max-tasks 1
spoolw failures | jq -s --arg task work-unread -e \
  'map(select(.task_id == $task)) | length == 1 and .[0].retried == true
   and (.[0].reason | test("timeout after 1 s"))' >/dev/null
check
drain_pending "work-unread"

# A program that exits leaving a process behind has not ended. The process
# ignores SIGTERM and holds the output open; it is killed, the run fails, and
# the worker does not wait the 15 seconds the process meant to run.
leftover_task='{"task_id":"work-leftover","capability":"leftover@1","payload":{}}'
printf '%s\n' "$leftover_task" | spoolw put >/dev/null
worker_config "leftover@1" "$bin/leaves-one-behind" 30 1024 > "$work/leftover-config.json"
spoolw work --worker w1 --config "$work/leftover-config.json" --max-tasks 1
test -s "$leftover_pidfile"; check
test ! -e "$leftover_finished"; check
if kill -0 "$(cat "$leftover_pidfile")" 2>/dev/null; then
  echo "a process left behind by a capability outlived its run" >&2; exit 1
fi
check
spoolw failures | jq -s --arg task work-leftover -e \
  'map(select(.task_id == $task)) | length == 1 and .[0].retried == true
   and (.[0].reason | test("still open"))' >/dev/null
check
spoolw results | jq -s --arg task work-leftover -e \
  'map(select(.task_id == $task)) | length == 0' >/dev/null
check
drain_pending "work-leftover"

# A worker told to stop takes its programs with it. It ends with the status
# of the signal, the program is dead, its working directory is gone, and the
# lease stands, for reclaim to return.
spoolx() { "$spool_binary" --dir "$work/interrupted-work" "$@"; }
spoolx init
mkdir "$work/interrupted-tmp"
printf '%s\n' '{"task_id":"work-interrupted","capability":"long@1","payload":{}}' \
  | spoolx put >/dev/null
worker_config "long@1" "$bin/runs-until-stopped" 60 1024 > "$work/interrupted-config.json"
TMPDIR="$work/interrupted-tmp" "$spool_binary" --dir "$work/interrupted-work" \
  work --worker stopped --config "$work/interrupted-config.json" --max-tasks 1 &
interrupted_worker=$!
i=0
while [ ! -s "$interrupted_pidfile" ] && [ "$i" -lt 100 ]; do
  sleep 0.1
  i=$((i + 1))
done
test -s "$interrupted_pidfile"; check
test -n "$(ls -A "$work/interrupted-tmp")"; check
kill -TERM "$interrupted_worker"
set +e
wait "$interrupted_worker"
interrupted_exit=$?
set -e
test "$interrupted_exit" -eq 143; check
test -e "$interrupted_asked"; check
if kill -0 "$(cat "$interrupted_pidfile")" 2>/dev/null; then
  echo "a capability outlived the worker that was told to stop" >&2; exit 1
fi
check
test -z "$(ls -A "$work/interrupted-tmp")"; check
spoolx status --json | jq -e '.pending == 0 and .leased == 1 and .failed == 0' >/dev/null; check
spoolx reclaim --older-than 0 | jq -e '.task_id == "work-interrupted"' >/dev/null; check

# Output past max_output_bytes fails with retry and names the limit, rather
# than growing the worker's memory to hold a runaway capability's output.
output_task='{"task_id":"work-output-cap","capability":"bigoutput@1","payload":{}}'
printf '%s\n' "$output_task" | spoolw put >/dev/null
worker_config "bigoutput@1" "$bin/big-output" 5 1024 1 4096 > "$work/output-cap-config.json"
spoolw work --worker w1 --config "$work/output-cap-config.json" --max-tasks 1
spoolw failures | jq -s --arg task work-output-cap -e \
  'map(select(.task_id == $task)) | length == 1 and .[0].retried == true
   and (.[0].reason | test("max_output_bytes"))' >/dev/null
check
drain_pending "work-output-cap"

# The environment is exactly the configured one: no caller HOME leaks through.
envcheck_task='{"task_id":"work-envcheck","capability":"envcheck@1","payload":{}}'
printf '%s\n' "$envcheck_task" | spoolw put >/dev/null
worker_config "envcheck@1" "$bin/env-check" 5 1024 > "$work/envcheck-config.json"
HOME="$work/fake-home" spoolw work --worker w1 --config "$work/envcheck-config.json" --max-tasks 1
spoolw results | jq -s --arg task work-envcheck -e \
  'map(select(.task_id == $task)) | length == 1 and .[0].result == {"has_home":false}' >/dev/null
check

# Non-JSON stdout fails.
notjson_task='{"task_id":"work-notjson","capability":"notjson@1","payload":{}}'
printf '%s\n' "$notjson_task" | spoolw put >/dev/null
worker_config "notjson@1" "$bin/not-json" 5 1024 > "$work/notjson-config.json"
spoolw work --worker w1 --config "$work/notjson-config.json" --max-tasks 1
spoolw failures | jq -s --arg task work-notjson -e \
  'map(select(.task_id == $task)) | length == 1 and .[0].reason == "output is not JSON"' >/dev/null
check
drain_pending "work-notjson"

# max_concurrent: 1 never overlaps: two tasks racing an exclusive mkdir lock
# must never see a collision.
overlap_a='{"task_id":"work-overlap-a","capability":"nooverlap@1","payload":{}}'
overlap_b='{"task_id":"work-overlap-b","capability":"nooverlap@1","payload":{}}'
printf '%s\n%s\n' "$overlap_a" "$overlap_b" | spoolw put >/dev/null
worker_config "nooverlap@1" "$bin/no-overlap" 5 1024 1 > "$work/nooverlap-config.json"
spoolw work --worker w1 --config "$work/nooverlap-config.json" --max-tasks 2
spoolw results | jq -s -e \
  'map(select(.task_id == "work-overlap-a" or .task_id == "work-overlap-b")) | length == 2
   and all(.[]; .result == {"ok":true})' >/dev/null
check
spoolw failures | jq -s -e \
  'map(select(.task_id == "work-overlap-a" or .task_id == "work-overlap-b")) | length == 0' >/dev/null
check

# max_concurrent: 2 runs two at once: both scripts must be mid-flight
# simultaneously before either is released.
concurrent_a='{"task_id":"work-concurrent-a","capability":"waitrelease@1","payload":{}}'
concurrent_b='{"task_id":"work-concurrent-b","capability":"waitrelease@1","payload":{}}'
printf '%s\n%s\n' "$concurrent_a" "$concurrent_b" | spoolw put >/dev/null
worker_config "waitrelease@1" "$bin/wait-for-release" 10 1024 2 > "$work/waitrelease-config.json"
(
  i=0
  while [ "$(find "$startdir" -type f 2>/dev/null | wc -l | tr -d ' ')" -lt 2 ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  : > "$releasefile"
) &
releaser_pid=$!
spoolw work --worker w1 --config "$work/waitrelease-config.json" --max-tasks 2
wait "$releaser_pid"
test "$(find "$startdir" -type f | wc -l | tr -d ' ')" = 2; check
spoolw results | jq -s -e \
  'map(select(.task_id == "work-concurrent-a" or .task_id == "work-concurrent-b")) | length == 2' >/dev/null
check

# A program gets its three pipes and no other descriptor, so one run from
# max_concurrent threads holds neither the spool's lock nor another program's
# pipes. Each of six programs notes its open descriptors beyond 0-2, marks its
# start, sleeps two seconds, and waits for a release. All six are running at
# once before any finishes, and the spool answers another process meanwhile.
spoolcc() { "$spool_binary" --dir "$work/cc-spool" "$@"; }
spoolcc init
cc_n=6
cc_started="$work/cc-started"
cc_release="$work/cc-release"
mkdir "$cc_started"
# Run by sh -c rather than from a script file, so the shell holds no
# descriptor of its own to be counted.
cc_probe='
cat >/dev/null
fd_dir=/dev/fd
if [ -d /proc/self/fd ]; then fd_dir=/proc/self/fd; fi
fds=
n=3
while [ "$n" -lt 256 ]; do
  if [ -e "$fd_dir/$n" ]; then fds="$fds,$n"; fi
  n=$((n + 1))
done
: > "$1/$$"
sleep 2
i=0
while [ ! -e "$2" ] && [ "$i" -lt 80 ]; do
  sleep 0.1
  i=$((i + 1))
done
set -- "$1"/*
printf "{\"fds\":[%s],\"started\":%d}\n" "${fds#,}" "$#"
'
jq -nc --arg path "$worker_path" --arg probe "$cc_probe" \
  --arg started "$cc_started" --arg release "$cc_release" --argjson n "$cc_n" \
  '{max_concurrent: $n, renew_seconds: 30, env: {PATH: $path},
    capabilities: {"probe@1": {exec: "/bin/sh",
      args: ["-c", $probe, "probe", $started, $release],
      timeout_seconds: 30, max_payload_bytes: 1024, max_output_bytes: 1024}}}' \
  > "$work/cc-config.json"
for i in $(seq 1 "$cc_n"); do
  printf '{"task_id":"cc-%s","capability":"probe@1","payload":{}}\n' "$i"
done | spoolcc put >/dev/null
cc_count() { find "$cc_started" -type f | wc -l | tr -d ' '; }
(
  i=0
  while [ "$(cc_count)" -lt 1 ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  before=$SECONDS
  spoolcc status --json > "$work/cc-status.json"
  echo $((SECONDS - before)) > "$work/cc-status-seconds"
  i=0
  while [ "$(cc_count)" -lt "$cc_n" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  : > "$cc_release"
) &
cc_releaser=$!
cc_before=$SECONDS
spoolcc work --worker w1 --config "$work/cc-config.json" --max-tasks "$cc_n"
cc_seconds=$((SECONDS - cc_before))
wait "$cc_releaser"
spoolcc failures | jq -s -e 'length == 0' >/dev/null; check
spoolcc results | jq -s -e --argjson n "$cc_n" 'length == $n' >/dev/null; check
# Every program saw all six started before it finished.
spoolcc results | jq -s -e --argjson n "$cc_n" 'all(.[]; .result.started == $n)' >/dev/null; check
# No program held a descriptor beyond its three pipes.
spoolcc results | jq -s -e 'all(.[]; .result.fds == [])' >/dev/null; check
# Six two-second programs at once take nowhere near twelve seconds.
test "$cc_seconds" -lt 6; check
# status, from another process, answered while the programs ran.
jq -e '.leased >= 1' "$work/cc-status.json" >/dev/null; check
test "$(cat "$work/cc-status-seconds")" -le 1; check

# A lease reclaimed while work is running fences the worker's eventual ack.
# The worker surfaces exit 4, stores no result, and leaves the re-pended task
# for a replacement worker.
spoollate() { "$spool_binary" --dir "$work/late-spool" "$@"; }
spoollate init
printf '%s\n' '{"task_id":"work-late","capability":"late@1","payload":{}}' \
  | spoollate put >/dev/null
worker_config "late@1" "$bin/wait-for-late-release" 10 1024 \
  > "$work/late-config.json"
set +e
spoollate work --worker old-worker --config "$work/late-config.json" --max-tasks 1 &
late_worker_pid=$!
set -e
i=0
while [ ! -f "$late_start" ] && [ "$i" -lt 100 ]; do
  sleep 0.1
  i=$((i + 1))
done
test -f "$late_start"; check
spoollate reclaim --older-than 0 >/dev/null
: > "$late_release"
set +e
wait "$late_worker_pid"
late_worker_exit=$?
set -e
test "$late_worker_exit" -eq 4; check
spoollate status --json \
  | jq -e '.pending == 1 and .leased == 0 and .done == 0' >/dev/null; check
spoollate results | jq -s -e 'length == 0' >/dev/null; check
spoollate lease --worker replacement > "$work/late-replacement.jsonl"
late_replacement_lease=$(jq -r '.lease_id' "$work/late-replacement.jsonl")
late_replacement_ack=$(jq -nc --arg lease "$late_replacement_lease" \
  '{task_id:"work-late",lease_id:$lease,result:{replacement:true}}')
printf '%s\n' "$late_replacement_ack" | spoollate ack >/dev/null

# --max-tasks stops after the requested count even with more pending work.
extra_a='{"task_id":"work-extra-a","capability":"classify@1","payload":{}}'
extra_b='{"task_id":"work-extra-b","capability":"classify@1","payload":{}}'
printf '%s\n%s\n' "$extra_a" "$extra_b" | spoolw put >/dev/null
spoolw work --worker w1 --config "$work/success-config.json" --max-tasks 1
after_one=$(spoolw status --json | jq -r '.pending')
test "$after_one" -ge 1; check

# No pending task exits 0; lease with no pending task exits 1.
spoolw work --worker w1 --config "$work/success-config.json" --max-tasks 5
spoolw status --json | jq -e '.pending == 0' >/dev/null; check
"$spool_binary" --dir "$work/workspool" work --worker w1 --config "$work/success-config.json"
expect_exit 1 spoolw lease --worker nobody

#############################################################################
# Attachments: declarations survive the envelope boundary, bytes are verified
# on staging/fetch/worker receipt, and spool-owned copies share task lifetime.
#############################################################################

spoola() { "$spool_binary" --dir "$work/attachment-spool" "$@"; }
spoola init
attachment_source="$work/attachment-source"
mkdir -p "$attachment_source"
printf 'attachment bytes\n' > "$work/attachment-body"
if command -v sha256sum >/dev/null 2>&1; then
  attachment_digest=$(sha256sum "$work/attachment-body" | awk '{print $1}')
else
  attachment_digest=$(shasum -a 256 "$work/attachment-body" | awk '{print $1}')
fi
attachment_size=$(wc -c < "$work/attachment-body" | tr -d ' ')
cp "$work/attachment-body" "$attachment_source/$attachment_digest"
attachment_task=$(jq -nc --arg digest "$attachment_digest" --argjson size "$attachment_size" \
  '{task_id:"attachment-one",capability:"attachment@1",payload:{},attachments:[{sha256:$digest,size:$size}]}')
printf '%s\n' "$attachment_task" | spoola put --attachments "$attachment_source" \
  | jq -e '.status == "inserted"' >/dev/null; check
jq -e --arg digest "$attachment_digest" --argjson size "$attachment_size" \
  '.attachments == [{sha256:$digest,size:$size}]' \
  "$work/attachment-spool/pending/attachment-one.json" >/dev/null; check

spoola lease --worker attachment-worker > "$work/attachment-lease.jsonl"
attachment_lease=$(jq -r '.lease_id' "$work/attachment-lease.jsonl")
jq -e --arg digest "$attachment_digest" --argjson size "$attachment_size" \
  '.attachments == [{sha256:$digest,size:$size}]' \
  "$work/attachment-lease.jsonl" >/dev/null; check
attachment_fetch=$(jq -nc --arg digest "$attachment_digest" --arg lease "$attachment_lease" \
  '{task_id:"attachment-one",lease_id:$lease,sha256:$digest}')
printf '%s\n' "$attachment_fetch" | spoola fetch > "$work/attachment-received"
cmp "$work/attachment-body" "$work/attachment-received"; check

# Retry and reclaim keep the task-scoped bytes; only resolution removes them.
attachment_failure=$(jq -nc --arg lease "$attachment_lease" \
  '{task_id:"attachment-one",lease_id:$lease,reason:"retry"}')
printf '%s\n' "$attachment_failure" | spoola fail >/dev/null
test -f "$work/attachment-spool/attachments/task-attachment-one/$attachment_digest"; check
spoola lease --worker attachment-worker > "$work/attachment-retry.jsonl"
attachment_retry_lease=$(jq -r '.lease_id' "$work/attachment-retry.jsonl")
spoola reclaim --older-than 0 >/dev/null
test -f "$work/attachment-spool/attachments/task-attachment-one/$attachment_digest"; check
spoola lease --worker attachment-worker > "$work/attachment-final.jsonl"
attachment_final_lease=$(jq -r '.lease_id' "$work/attachment-final.jsonl")
attachment_ack=$(jq -nc --arg lease "$attachment_final_lease" \
  '{task_id:"attachment-one",lease_id:$lease,result:{received:true}}')
printf '%s\n' "$attachment_ack" | spoola ack >/dev/null
test ! -e "$work/attachment-spool/attachments/task-attachment-one"; check
spoola results | jq -e 'select(.task_id == "attachment-one" and .result == {received:true})' >/dev/null; check

# An equal resolved put is a no-op and does not need the source files again.
rm "$attachment_source/$attachment_digest"
printf '%s\n' "$attachment_task" | spoola put \
  | jq -e '.status == "existing"' >/dev/null; check

# A declaration mismatch never publishes a pending task or staged directory.
bad_attachment=$(jq -nc --arg digest "$attachment_digest" --argjson size "$((attachment_size + 1))" \
  '{task_id:"attachment-bad",capability:"attachment@1",payload:{},attachments:[{sha256:$digest,size:$size}]}')
cp "$work/attachment-body" "$attachment_source/$attachment_digest"
set +e
printf '%s\n' "$bad_attachment" | spoola put --attachments "$attachment_source" >/dev/null 2>&1
bad_attachment_exit=$?
set -e
test "$bad_attachment_exit" -eq 2; check
test ! -e "$work/attachment-spool/pending/attachment-bad.json"; check
test ! -e "$work/attachment-spool/attachments/task-attachment-bad"; check

# The worker receives verified bytes below attachments/SHA256 and its result
# follows the ordinary result-bearing acknowledgement path.
cat > "$bin/read-attachment" <<SCRIPT
#!/bin/sh
cat >/dev/null
test "\$(cat attachments/$attachment_digest)" = "attachment bytes"
printf '{"attachment":true}\n'
SCRIPT
chmod +x "$bin/read-attachment"
worker_attachment_task=$(jq -nc --arg digest "$attachment_digest" --argjson size "$attachment_size" \
  '{task_id:"attachment-work",capability:"attachment@1",payload:{},attachments:[{sha256:$digest,size:$size}]}')
printf '%s\n' "$worker_attachment_task" | spoola put --attachments "$attachment_source" >/dev/null
worker_config "attachment@1" "$bin/read-attachment" 5 1024 > "$work/attachment-config.json"
spoola work --worker attachment-worker --config "$work/attachment-config.json" --max-tasks 1
spoola results | jq -e 'select(.task_id == "attachment-work" and .result == {attachment:true})' >/dev/null; check
test ! -e "$work/attachment-spool/attachments/task-attachment-work"; check

# Terminal failure resolves the task and removes its spool-owned attachment.
terminal_attachment=$(jq -nc --arg digest "$attachment_digest" --argjson size "$attachment_size" \
  '{task_id:"attachment-terminal",capability:"attachment@1",payload:{},attachments:[{sha256:$digest,size:$size}]}')
printf '%s\n' "$terminal_attachment" | spoola put --attachments "$attachment_source" >/dev/null
spoola lease --worker attachment-worker > "$work/attachment-terminal-lease.jsonl"
terminal_attachment_lease=$(jq -r '.lease_id' "$work/attachment-terminal-lease.jsonl")
terminal_attachment_fail=$(jq -nc --arg lease "$terminal_attachment_lease" \
  '{task_id:"attachment-terminal",lease_id:$lease,reason:"terminal"}')
printf '%s\n' "$terminal_attachment_fail" | spoola fail --no-retry >/dev/null
test ! -e "$work/attachment-spool/attachments/task-attachment-terminal"; check

# A stored-byte mismatch is corrupt durable state and emits no partial body.
corrupt_task=$(jq -nc --arg digest "$attachment_digest" --argjson size "$attachment_size" \
  '{task_id:"attachment-corrupt",capability:"attachment@1",payload:{},attachments:[{sha256:$digest,size:$size}]}')
printf '%s\n' "$corrupt_task" | spoola put --attachments "$attachment_source" >/dev/null
spoola lease --worker attachment-worker > "$work/attachment-corrupt-lease.jsonl"
corrupt_attachment_lease=$(jq -r '.lease_id' "$work/attachment-corrupt-lease.jsonl")
printf 'changed bytes\n' > "$work/attachment-spool/attachments/task-attachment-corrupt/$attachment_digest"
corrupt_fetch=$(jq -nc --arg digest "$attachment_digest" --arg lease "$corrupt_attachment_lease" \
  '{task_id:"attachment-corrupt",lease_id:$lease,sha256:$digest}')
set +e
printf '%s\n' "$corrupt_fetch" | spoola fetch > "$work/corrupt-fetch.out" 2>/dev/null
corrupt_fetch_exit=$?
set -e
test "$corrupt_fetch_exit" -eq 70; check
test ! -s "$work/corrupt-fetch.out"; check

# Old task records remain readable when the new optional field is absent.
old_task='{"task_id":"old-task-shape","capability":"old@1","payload":{}}'
printf '%s\n' "$old_task" | spoola put >/dev/null
jq 'del(.attachments)' "$work/attachment-spool/pending/old-task-shape.json" \
  > "$work/old-task-shape.json"
mv "$work/old-task-shape.json" "$work/attachment-spool/pending/old-task-shape.json"
spoola lease --worker compatibility > "$work/old-task-lease.jsonl"
jq -e '.task_id == "old-task-shape" and .attachments == []' \
  "$work/old-task-lease.jsonl" >/dev/null; check

# A put killed while staging leaves its staging directory behind, and the next
# command clears it. The leftover is the real writer's own: the source is a
# pipe held open here, so put has made the directory and is waiting for bytes
# when it is killed.
spooli() { "$spool_binary" --dir "$work/interrupted-stage" "$@"; }
spooli init
stage_source="$work/interrupted-stage-source"
mkdir -p "$stage_source"
stage_digest=$(printf '0%.0s' {1..64})
mkfifo "$stage_source/$stage_digest"
exec 9<>"$stage_source/$stage_digest"
jq -nc --arg digest "$stage_digest" \
  '{task_id:"interrupted-stage",capability:"attach@1",payload:{},attachments:[{sha256:$digest,size:1}]}' \
  > "$work/interrupted-stage-task.jsonl"
"$spool_binary" --dir "$work/interrupted-stage" put --attachments "$stage_source" \
  < "$work/interrupted-stage-task.jsonl" >/dev/null 2>&1 &
stage_put_pid=$!
i=0
while [ -z "$(ls -A "$work/interrupted-stage/attachments")" ] && [ "$i" -lt 100 ]; do
  sleep 0.1
  i=$((i + 1))
done
kill -9 "$stage_put_pid"
set +e
wait "$stage_put_pid" 2>/dev/null
set -e
exec 9>&-
test -n "$(ls -A "$work/interrupted-stage/attachments")"; check
spooli status --json | jq -e '.pending == 0 and .leased == 0' >/dev/null; check
test -z "$(ls -A "$work/interrupted-stage/attachments")"; check

# A task whose ID ends like a staging directory keeps its attachments: only
# the writer's own leftovers are cleared.
lookalike_task=$(jq -nc --arg digest "$attachment_digest" --argjson size "$attachment_size" \
  '{task_id:"lookalike.spool-attachment-stage",capability:"attach@1",payload:{},attachments:[{sha256:$digest,size:$size}]}')
printf '%s\n' "$lookalike_task" | spooli put --attachments "$attachment_source" >/dev/null
spooli status >/dev/null
test -f "$work/interrupted-stage/attachments/task-lookalike.spool-attachment-stage/$attachment_digest"; check

#############################################################################
# Grants and the SSH boundary: the account record supplies both spool and
# worker, every remote word reaches only its named handler, and revoke fences.
#############################################################################

grant_home="$work/grant-home"
mkdir -p "$grant_home/.ssh"
printf '# unrelated key material\n' > "$grant_home/.ssh/authorized_keys"
primary_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
secondary_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB'
printf '%s\n' "$primary_key" > "$work/primary.pub"
printf '%s\n' "$secondary_key" > "$work/secondary.pub"
spoolg() { HOME="$grant_home" "$spool_binary" --dir "$work/grant-spool" "$@"; }
remote_primary() {
  local requested=$1
  HOME="$grant_home" SSH_ORIGINAL_COMMAND="$requested" \
    "$spool_binary" remote --grant "$grant_id"
}
spoolg init
HOME="$grant_home" "$spool_binary" --dir "$work/grant-spool" grant \
  --peer peer-one --worker granted-worker --key "$work/primary.pub" \
  > "$work/grant.json"
grant_id=$(jq -r '.grant_id' "$work/grant.json")
jq -e --arg key "$primary_key" \
  'keys == ["expires_at","grant_id","peer","public_key","put","spool","worker"]
   and (.grant_id | test("^grant_[0-9a-f]{32}$"))
   and .peer == "peer-one" and .worker == "granted-worker" and .put == false
   and .public_key == $key and .expires_at == null' "$work/grant.json" >/dev/null; check
test -f "$grant_home/.spool/grants/$grant_id.json"; check
grep -F "restrict,command=\"" "$grant_home/.ssh/authorized_keys" \
  | grep -F " remote --grant $grant_id\" $primary_key spool-grant:$grant_id" >/dev/null; check
test "$(head -n 1 "$grant_home/.ssh/authorized_keys")" = '# unrelated key material'; check

# Duplicate active key or worker is a task-style conflict, not a second grant.
expect_exit 3 env HOME="$grant_home" "$spool_binary" --dir "$work/grant-spool" grant \
  --peer duplicate --worker another-worker --key "$work/primary.pub"
expect_exit 3 env HOME="$grant_home" "$spool_binary" --dir "$work/grant-spool" grant \
  --peer duplicate --worker granted-worker --key "$work/secondary.pub"

remote_task='{"task_id":"remote-one","capability":"remote@1","payload":{}}'
printf '%s\n' "$remote_task" | spoolg put >/dev/null
remote_primary 'lease' > "$work/remote-lease.jsonl"
remote_lease=$(jq -r '.lease_id' "$work/remote-lease.jsonl")
jq -e '.task_id == "remote-one" and .worker == "granted-worker"' \
  "$work/remote-lease.jsonl" >/dev/null; check
remote_renew=$(jq -nc --arg lease "$remote_lease" \
  '{task_id:"remote-one",lease_id:$lease}')
printf '%s\n' "$remote_renew" | remote_primary 'renew' \
  | jq -e '.status == "renewed"' >/dev/null; check
remote_ack=$(jq -nc --arg lease "$remote_lease" \
  '{task_id:"remote-one",lease_id:$lease,result:{remote:true}}')
printf '%s\n' "$remote_ack" | remote_primary 'ack' \
  | jq -e '.status == "acked"' >/dev/null; check
printf '%s\n' "$remote_ack" | remote_primary 'ack' \
  | jq -e '.status == "already_done"' >/dev/null; check
spoolg results | jq -e 'select(.task_id == "remote-one" and .result == {remote:true})' >/dev/null; check

# The counted lease form and both fail modes reach their concrete handlers.
printf '%s\n%s\n' \
  '{"task_id":"remote-count-a","capability":"remote@1","payload":{}}' \
  '{"task_id":"remote-count-b","capability":"remote@1","payload":{}}' \
  | spoolg put >/dev/null
remote_primary 'lease --count 2' > "$work/remote-count.jsonl"
test "$(wc -l < "$work/remote-count.jsonl" | tr -d ' ')" = 2; check
jq -c '{task_id,lease_id,result:{counted:true}}' "$work/remote-count.jsonl" \
  | remote_primary 'ack' >/dev/null
printf '%s\n' '{"task_id":"remote-fail","capability":"remote@1","payload":{}}' \
  | spoolg put >/dev/null
remote_primary 'lease' > "$work/remote-fail-lease.jsonl"
remote_fail_lease=$(jq -r '.lease_id' "$work/remote-fail-lease.jsonl")
remote_fail=$(jq -nc --arg lease "$remote_fail_lease" \
  '{task_id:"remote-fail",lease_id:$lease,reason:"retry"}')
printf '%s\n' "$remote_fail" | remote_primary 'fail' \
  | jq -e '.status == "failed_retry"' >/dev/null; check
remote_primary 'lease' > "$work/remote-terminal-lease.jsonl"
remote_terminal_lease=$(jq -r '.lease_id' "$work/remote-terminal-lease.jsonl")
remote_terminal_fail=$(jq -nc --arg lease "$remote_terminal_lease" \
  '{task_id:"remote-fail",lease_id:$lease,reason:"terminal"}')
printf '%s\n' "$remote_terminal_fail" | remote_primary 'fail --no-retry' \
  | jq -e '.status == "failed"' >/dev/null; check

# A remote grant cannot act on another worker's lease.
printf '%s\n' '{"task_id":"other-worker","capability":"remote@1","payload":{}}' \
  | spoolg put >/dev/null
spoolg lease --worker other-worker > "$work/other-worker-lease.jsonl"
other_worker_lease=$(jq -r '.lease_id' "$work/other-worker-lease.jsonl")
other_worker_ref=$(jq -nc --arg lease "$other_worker_lease" \
  '{task_id:"other-worker",lease_id:$lease}')
set +e
printf '%s\n' "$other_worker_ref" | remote_primary 'renew' >/dev/null 2>&1
wrong_worker_exit=$?
set -e
test "$wrong_worker_exit" -eq 4; check

# Every line of a remote request is answered. A line for another worker's
# lease is answered stale and does nothing; the grant's own lease in the same
# request is acted on. The request then exits 4.
printf '%s\n' '{"task_id":"remote-batch","capability":"remote@1","payload":{}}' \
  | spoolg put >/dev/null
remote_primary 'lease' > "$work/remote-batch-lease.jsonl"
jq -e '.task_id == "remote-batch"' "$work/remote-batch-lease.jsonl" >/dev/null; check
remote_batch_lease=$(jq -r '.lease_id' "$work/remote-batch-lease.jsonl")
own_batch_ack=$(jq -nc --arg lease "$remote_batch_lease" \
  '{task_id:"remote-batch",lease_id:$lease,result:{own:true}}')
foreign_batch_ack=$(jq -nc --arg lease "$other_worker_lease" \
  '{task_id:"other-worker",lease_id:$lease,result:{foreign:true}}')
test "$own_batch_ack" != "$foreign_batch_ack"; check
set +e
printf '%s\n%s\n' "$foreign_batch_ack" "$own_batch_ack" \
  | remote_primary 'ack' > "$work/remote-batch.out" 2>/dev/null
remote_batch_exit=$?
set -e
test "$remote_batch_exit" -eq 4; check
jq -s -e --arg own "$remote_batch_lease" --arg foreign "$other_worker_lease" \
  '. == [ {task_id:"other-worker", lease_id:$foreign, status:"stale"}
        , {task_id:"remote-batch", lease_id:$own, status:"acked"} ]' \
  "$work/remote-batch.out" >/dev/null; check
spoolg results | jq -s -e \
  'map(select(.task_id == "remote-batch")) | length == 1 and .[0].result == {own:true}' \
  >/dev/null; check
test -f "$work/grant-spool/leased/$other_worker_lease.json"; check
# A malformed line anywhere in a request acts on nothing.
printf '%s\n' '{"task_id":"remote-batch-two","capability":"remote@1","payload":{}}' \
  | spoolg put >/dev/null
remote_primary 'lease' > "$work/remote-batch-two.jsonl"
set +e
printf '%s\n%s\n' "$(jq -c '{task_id, lease_id, result: {}}' "$work/remote-batch-two.jsonl")" \
  '{not json' | remote_primary 'ack' > "$work/remote-batch-two.out" 2>/dev/null
remote_malformed_exit=$?
set -e
test "$remote_malformed_exit" -eq 2; check
test ! -s "$work/remote-batch-two.out"; check
test -f "$work/grant-spool/leased/$(jq -r '.lease_id' "$work/remote-batch-two.jsonl").json"; check
jq -c '{task_id, lease_id, result: {}}' "$work/remote-batch-two.jsonl" \
  | remote_primary 'ack' | jq -e '.status == "acked"' >/dev/null; check

# Remote fetch emits only the verified bytes and uses the grant-bound worker.
remote_attachment=$(jq -nc --arg digest "$attachment_digest" --argjson size "$attachment_size" \
  '{task_id:"remote-attachment",capability:"remote@1",payload:{},attachments:[{sha256:$digest,size:$size}]}')
printf '%s\n' "$remote_attachment" | spoolg put --attachments "$attachment_source" >/dev/null
remote_primary 'lease' > "$work/remote-attachment-lease.jsonl"
remote_attachment_lease=$(jq -r '.lease_id' "$work/remote-attachment-lease.jsonl")
remote_attachment_fetch=$(jq -nc --arg digest "$attachment_digest" --arg lease "$remote_attachment_lease" \
  '{task_id:"remote-attachment",lease_id:$lease,sha256:$digest}')
printf '%s\n' "$remote_attachment_fetch" | remote_primary 'fetch' \
  > "$work/remote-attachment-body"
cmp "$work/attachment-body" "$work/remote-attachment-body"; check
remote_attachment_ack=$(jq -nc --arg lease "$remote_attachment_lease" \
  '{task_id:"remote-attachment",lease_id:$lease,result:{fetched:true}}')
printf '%s\n' "$remote_attachment_ack" | remote_primary 'ack' >/dev/null

# The lock is not held while fetch writes. A fetch whose reader has stopped
# reading is blocked on its output, and status answers from another process
# meanwhile, locally and through the remote command; the bytes then arrive
# whole.
head -c 2000000 /dev/urandom > "$work/fetch-big"
if command -v sha256sum >/dev/null 2>&1; then
  fetch_big_digest=$(sha256sum "$work/fetch-big" | awk '{print $1}')
else
  fetch_big_digest=$(shasum -a 256 "$work/fetch-big" | awk '{print $1}')
fi
cp "$work/fetch-big" "$attachment_source/$fetch_big_digest"
slow_fetch() {
  local name=$1 status_command=$2; shift 2
  mkfifo "$work/$name-pipe"
  "$@" > "$work/$name-pipe" &
  local pid=$!
  exec 9<"$work/$name-pipe"
  dd bs=1 count=1 <&9 > "$work/$name-first" 2>/dev/null
  test -s "$work/$name-first"; check
  $status_command > /dev/null; check
  cat <&9 > "$work/$name-rest"
  exec 9<&-
  wait "$pid"; check
  cat "$work/$name-first" "$work/$name-rest" | cmp - "$work/fetch-big"; check
}
for spool_kind in local remote; do
  jq -nc --arg task "slow-fetch-$spool_kind" --arg digest "$fetch_big_digest" \
    '{task_id:$task,capability:"remote@1",payload:{},attachments:[{sha256:$digest,size:2000000}]}' \
    | spoolg put --attachments "$attachment_source" >/dev/null
done
"$spool_binary" --dir "$work/grant-spool" lease --worker slow-local > "$work/slow-local-lease.json"
jq -e '.task_id == "slow-fetch-local"' "$work/slow-local-lease.json" >/dev/null; check
slow_local_lease=$(jq -r '.lease_id' "$work/slow-local-lease.json")
slow_status_local() { timeout 5 "$spool_binary" --dir "$work/grant-spool" status --json; }
slow_fetch slow-fetch-local slow_status_local sh -c \
  "printf '%s\n' '$(jq -nc --arg l "$slow_local_lease" --arg d "$fetch_big_digest" '{task_id:"slow-fetch-local",lease_id:$l,sha256:$d}')' \
    | '$spool_binary' --dir '$work/grant-spool' fetch"
remote_primary 'lease' > "$work/slow-remote-lease.json"
jq -e '.task_id == "slow-fetch-remote"' "$work/slow-remote-lease.json" >/dev/null; check
slow_remote_lease=$(jq -r '.lease_id' "$work/slow-remote-lease.json")
slow_remote_request=$(jq -nc --arg l "$slow_remote_lease" --arg d "$fetch_big_digest" '{task_id:"slow-fetch-remote",lease_id:$l,sha256:$d}')
slow_fetch slow-fetch-remote slow_status_local sh -c \
  "printf '%s\n' '$slow_remote_request' | HOME='$grant_home' SSH_ORIGINAL_COMMAND=fetch '$spool_binary' remote --grant '$grant_id'"
for slow_lease in "$slow_local_lease" "$slow_remote_lease"; do
  jq -nc --arg l "$slow_lease" --arg t "$(jq -r .task_id "$work/grant-spool/leased/$slow_lease.json")" \
    '{task_id:$t,lease_id:$l,result:{}}' | spoolg ack >/dev/null
done

# The remote command is an exact byte grammar.  Shell metacharacters,
# whitespace variants, local-only operations, options, and non-canonical
# counts never reach a handler.  The Cabal test suite covers NUL; these
# environment values cover the bytes a shell can carry.
remote_reject() {
  local requested=$1
  expect_exit 2 remote_primary "$requested"
}
remote_reject ''
remote_reject ' lease'
remote_reject 'lease '
remote_reject 'lease  --count 1'
remote_reject $'lease\t--count\t1'
remote_reject $'lease\n'
remote_reject "'lease'"
remote_reject 'lease\\'
remote_reject 'lease;status'
remote_reject 'lease && status'
remote_reject 'lease | status'
remote_reject '$(status)'
remote_reject 'lease*'
remote_reject 'lease --worker other-worker'
remote_reject 'lease --count'
remote_reject 'lease --count 0'
remote_reject 'lease --count 01'
remote_reject 'lease --count +1'
remote_reject 'lease --count -1'
remote_reject 'lease --count 1.0'
remote_reject $'lease --count 1\n'
remote_reject 'lease --count 9223372036854775808'
remote_reject 'lease --count 111111111111111111111'
remote_reject 'lease extra'
remote_reject '--count 1'
# put is a remote word (ADR 0015); this grant may not, so it is denied, not
# malformed, and the attachments form is never a remote word.
expect_exit 5 remote_primary 'put' </dev/null
remote_reject 'put --attachments x'
# results, failures, and status are remote words for a grant that may put
# (ADR 0016); this one may not, so each is denied, and a word with anything
# more is never a word.
expect_exit 5 remote_primary 'results' </dev/null
expect_exit 5 remote_primary 'failures' </dev/null
expect_exit 5 remote_primary 'status' </dev/null
expect_exit 5 remote_primary 'status --json' </dev/null
remote_reject 'status --text'
remote_reject 'results --json'
remote_reject 'collect --all'
remote_reject 'gc --older-than 0'
remote_reject 'reclaim --older-than 0'
remote_reject 'grant --worker other'
remote_reject 'revoke --grant grant_deadbeef'
long_remote_command=$(printf 'x%.0s' {1..65})
remote_reject "$long_remote_command"

# The grant identifier is trusted only after its fixed grammar check; path
# traversal or option-like values cannot select a different account record.
expect_exit 2 env HOME="$grant_home" SSH_ORIGINAL_COMMAND=lease \
  "$spool_binary" remote --grant ../escape
expect_exit 2 env HOME="$grant_home" SSH_ORIGINAL_COMMAND=lease \
  "$spool_binary" remote --grant "$grant_id/../escape"
expect_exit 2 env HOME="$grant_home" SSH_ORIGINAL_COMMAND=lease \
  "$spool_binary" remote --grant --dir

# JSONL is stdin data, not command words.  Unknown fields and path-like
# task IDs/digests are rejected before any transition or file lookup.
bad_remote_ack=$(jq -nc --arg lease "$remote_lease" \
  '{task_id:"remote-one",lease_id:$lease,result:{remote:true},extra:true}')
set +e
printf '%s\n' "$bad_remote_ack" | remote_primary 'ack' >/dev/null 2>&1
bad_remote_ack_exit=$?
set -e
test "$bad_remote_ack_exit" -eq 2; check
bad_remote_renew=$(jq -nc --arg lease "$remote_lease" \
  '{task_id:"remote-one",lease_id:$lease,extra:true}')
set +e
printf '%s\n' "$bad_remote_renew" | remote_primary 'renew' >/dev/null 2>&1
bad_remote_renew_exit=$?
set -e
test "$bad_remote_renew_exit" -eq 2; check
bad_remote_fail=$(jq -nc --arg lease "$remote_lease" \
  '{task_id:"remote-one",lease_id:$lease,reason:"nope",extra:true}')
set +e
printf '%s\n' "$bad_remote_fail" | remote_primary 'fail' >/dev/null 2>&1
bad_remote_fail_exit=$?
set -e
test "$bad_remote_fail_exit" -eq 2; check
bad_remote_fetch=$(jq -nc --arg lease "$remote_attachment_lease" \
  --arg digest "$attachment_digest" \
  '{task_id:"remote-attachment",lease_id:$lease,sha256:$digest,extra:true}')
set +e
printf '%s\n' "$bad_remote_fetch" | remote_primary 'fetch' >/dev/null 2>&1
bad_remote_fetch_exit=$?
set -e
test "$bad_remote_fetch_exit" -eq 2; check
path_task_ack=$(jq -nc --arg lease "$remote_lease" \
  '{task_id:"../escape",lease_id:$lease,result:{bad:true}}')
set +e
printf '%s\n' "$path_task_ack" | remote_primary 'ack' >/dev/null 2>&1
path_task_ack_exit=$?
set -e
test "$path_task_ack_exit" -eq 2; check
path_digest_fetch=$(jq -nc --arg lease "$remote_attachment_lease" \
  '{task_id:"remote-attachment",lease_id:$lease,sha256:"../../etc/passwd"}')
set +e
printf '%s\n' "$path_digest_fetch" | remote_primary 'fetch' >/dev/null 2>&1
path_digest_fetch_exit=$?
set -e
test "$path_digest_fetch_exit" -eq 2; check

# A grant-bound remote command cannot select another worker.  This is distinct
# from parser rejection: the command dispatches, then the ownership fence
# returns exit 4.
wrong_worker_fail=$(jq -nc --arg lease "$other_worker_lease" \
  '{task_id:"other-worker",lease_id:$lease,reason:"late"}')
set +e
printf '%s\n' "$wrong_worker_fail" | remote_primary 'fail' >/dev/null 2>&1
wrong_worker_fail_exit=$?
set -e
test "$wrong_worker_fail_exit" -eq 4; check

# Expiry is checked from the record on every invocation.
HOME="$grant_home" "$spool_binary" --dir "$work/grant-spool" grant \
  --peer expired-peer --worker expired-worker --key "$work/secondary.pub" \
  --expires-at 1970-01-01T00:00:00Z > "$work/expired-grant.json"
expired_grant_id=$(jq -r '.grant_id' "$work/expired-grant.json")
expect_exit 5 env HOME="$grant_home" SSH_ORIGINAL_COMMAND=lease \
  "$spool_binary" remote --grant "$expired_grant_id"

# A worker is a name wherever it is read. A grant record whose worker is
# outside the grammar denies its peer and is corrupt state to the owner, until
# it is granted again under a name inside it. The record is edited because a
# name outside the grammar cannot arrive as an argument.
wide_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD'
printf '%s\n' "$wide_key" > "$work/wide.pub"
spoolg grant --peer wide-peer --worker wide-worker --key "$work/wide.pub" \
  > "$work/wide-grant.json"
wide_grant_id=$(jq -r '.grant_id' "$work/wide-grant.json")
remote_as() {
  local grant=$1 requested=$2
  HOME="$grant_home" SSH_ORIGINAL_COMMAND="$requested" \
    "$spool_binary" remote --grant "$grant"
}
printf '%s\n' '{"task_id":"wide-worker","capability":"remote@1","payload":{}}' \
  | spoolg put >/dev/null
cp "$grant_home/.spool/grants/$wide_grant_id.json" "$work/wide-grant-record.json"
for outside in 'Ł' 'two words' '' 'wwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwww'; do
  jq -c --arg worker "$outside" '.worker = $worker' "$work/wide-grant-record.json" \
    > "$work/wide-grant-edited.json"
  mv -f "$work/wide-grant-edited.json" "$grant_home/.spool/grants/$wide_grant_id.json"
  expect_exit 5 remote_as "$wide_grant_id" 'lease'
  expect_exit 70 env HOME="$grant_home" "$spool_binary" --dir "$work/grant-spool" grant \
    --peer another-peer --worker another-worker --key "$work/secondary.pub"
done
test "$(printf 'w%.0s' {1..65})" = 'wwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwww'; check
cp "$work/wide-grant-record.json" "$grant_home/.spool/grants/$wide_grant_id.json"
spoolg status >/dev/null; check
remote_as "$wide_grant_id" 'lease' > "$work/wide-lease.jsonl"
jq -e '.task_id == "wide-worker" and .worker == "wide-worker"' \
  "$work/wide-lease.jsonl" >/dev/null; check
wide_lease=$(jq -r '.lease_id' "$work/wide-lease.jsonl")
wide_ack=$(jq -nc --arg lease "$wide_lease" \
  '{task_id:"wide-worker",lease_id:$lease,result:{wide:true}}')
printf '%s\n' "$wide_ack" | remote_as "$wide_grant_id" 'ack' \
  | jq -e '.status == "acked"' >/dev/null; check

# A worker sidecar holding what is not a name is corrupt durable state.
printf '%s\n' '{"task_id":"bad-worker-name","capability":"remote@1","payload":{}}' \
  | spoolg put >/dev/null
remote_as "$wide_grant_id" 'lease' > "$work/bad-name-lease.jsonl"
bad_name_lease=$(jq -r '.lease_id' "$work/bad-name-lease.jsonl")
bad_name_ack=$(jq -nc --arg lease "$bad_name_lease" \
  '{task_id:"bad-worker-name",lease_id:$lease,result:{}}')
printf 'two words' > "$work/grant-spool/leased/$bad_name_lease.worker"
set +e
printf '%s\n' "$bad_name_ack" | spoolg ack >/dev/null 2>&1
bad_name_exit=$?
set -e
test "$bad_name_exit" -eq 70; check
printf 'wide-worker' > "$work/grant-spool/leased/$bad_name_lease.worker"
printf '%s\n' "$bad_name_ack" | spoolg ack | jq -e '.status == "acked"' >/dev/null; check

# A worker sidecar that is not UTF-8 is corrupt durable state, not a name.
printf '%s\n' '{"task_id":"bad-worker-sidecar","capability":"remote@1","payload":{}}' \
  | spoolg put >/dev/null
remote_as "$wide_grant_id" 'lease' > "$work/bad-sidecar-lease.jsonl"
bad_sidecar_lease=$(jq -r '.lease_id' "$work/bad-sidecar-lease.jsonl")
bad_sidecar_ack=$(jq -nc --arg lease "$bad_sidecar_lease" \
  '{task_id:"bad-worker-sidecar",lease_id:$lease,result:{}}')
cp "$work/grant-spool/leased/$bad_sidecar_lease.worker" "$work/good-worker-sidecar"
printf '\377' > "$work/grant-spool/leased/$bad_sidecar_lease.worker"
set +e
printf '%s\n' "$bad_sidecar_ack" | spoolg ack >/dev/null 2>&1
bad_sidecar_exit=$?
set -e
test "$bad_sidecar_exit" -eq 70; check
cp "$work/good-worker-sidecar" "$work/grant-spool/leased/$bad_sidecar_lease.worker"
printf '%s\n' "$bad_sidecar_ack" | spoolg ack | jq -e '.status == "acked"' >/dev/null; check

#############################################################################
# Another machine: a grant that may put puts through the forced command, and
# work --via runs the whole worker there, speaking the same grammar.
#############################################################################

# The transport stands in for "ssh -i KEY account@host": it is given the grant
# to act as and the one remote word Spool appends, and runs the real forced
# command with that word as SSH_ORIGINAL_COMMAND, stdin and stdout untouched.
cat > "$bin/fake-ssh" <<SCRIPT
#!/bin/sh
grant=\$1
word=\$2
HOME="$grant_home" SSH_ORIGINAL_COMMAND="\$word" exec "$spool_binary" remote --grant "\$grant"
SCRIPT
chmod +x "$bin/fake-ssh"
cat > "$bin/broken-ssh" <<'SCRIPT'
#!/bin/sh
echo "ssh: connect to host nowhere: no route" >&2
exit 255
SCRIPT
chmod +x "$bin/broken-ssh"

# Lists the attachments it was given, so a fetched attachment is proven to
# have arrived whole and under its digest.
cat > "$bin/list-attachments" <<'SCRIPT'
#!/bin/sh
cat >/dev/null
if [ -d attachments ]; then
  names=$(ls attachments | sed 's/.*/"&"/' | paste -sd, -)
else
  names=
fi
printf '{"attachments":[%s]}\n' "$names"
SCRIPT
chmod +x "$bin/list-attachments"

putter_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAF'
reader_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAG'
printf '%s\n' "$putter_key" > "$work/putter.pub"
printf '%s\n' "$reader_key" > "$work/reader.pub"
spoolg grant --peer "the other laptop" --worker putter --key "$work/putter.pub" --put \
  > "$work/putter-grant.json"
spoolg grant --peer "a friend" --worker reader --key "$work/reader.pub" \
  > "$work/reader-grant.json"
jq -e '.put == true and .peer == "the other laptop"' "$work/putter-grant.json" >/dev/null; check
jq -e '.put == false' "$work/reader-grant.json" >/dev/null; check
putter_grant=$(jq -r '.grant_id' "$work/putter-grant.json")
reader_grant=$(jq -r '.grant_id' "$work/reader-grant.json")

# The forced command names the program the owner chose, when one is chosen;
# a path that is not canonical is refused and no record is written.
stable_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAH'
printf '%s\n' "$stable_key" > "$work/stable.pub"
spoolg grant --peer "stable path" --worker stable --key "$work/stable.pub" \
  --executable /usr/local/bin/spool > "$work/stable-grant.json"
stable_grant=$(jq -r '.grant_id' "$work/stable-grant.json")
grep -F "restrict,command=\"/usr/local/bin/spool remote --grant $stable_grant\" $stable_key spool-grant:$stable_grant" \
  "$grant_home/.ssh/authorized_keys" >/dev/null; check
grants_before_bad_executable=$(ls "$grant_home/.spool/grants" | wc -l | tr -d ' ')
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAI' > "$work/unstable.pub"
expect_exit 2 env HOME="$grant_home" "$spool_binary" --dir "$work/grant-spool" grant \
  --peer "relative" --worker relative --key "$work/unstable.pub" --executable bin/spool
expect_exit 2 env HOME="$grant_home" "$spool_binary" --dir "$work/grant-spool" grant \
  --peer "dotted" --worker dotted --key "$work/unstable.pub" --executable /usr/local/../bin/spool
test "$(ls "$grant_home/.spool/grants" | wc -l | tr -d ' ')" = "$grants_before_bad_executable"; check
HOME="$grant_home" "$spool_binary" --dir "$work/grant-spool" revoke --grant "$stable_grant" >/dev/null

# A grant that may put puts; one that may not is denied before a line is read.
pending_before_remote_put=$(spoolg status --json | jq -r '.pending')
printf '%s\n%s\n' \
  '{"task_id":"remote-put-a","capability":"classify@1","payload":{"n":1}}' \
  '{"task_id":"remote-put-b","capability":"attachments@1","payload":{}}' \
  | "$bin/fake-ssh" "$putter_grant" put > "$work/remote-put.out"
jq -s -e '. == [ {task_id:"remote-put-a", status:"inserted"}
               , {task_id:"remote-put-b", status:"inserted"} ]' "$work/remote-put.out" >/dev/null; check
spoolg status --json | jq -e --argjson n "$pending_before_remote_put" '.pending == $n + 2' >/dev/null; check
set +e
printf '%s\n' '{"task_id":"remote-put-denied","capability":"classify@1","payload":{}}' \
  | "$bin/fake-ssh" "$reader_grant" put > "$work/remote-put-denied.out" 2>/dev/null
remote_put_denied=$?
set -e
test "$remote_put_denied" -eq 5; check
test ! -s "$work/remote-put-denied.out"; check
spoolg status --json | jq -e --argjson n "$pending_before_remote_put" '.pending == $n + 2' >/dev/null; check
# A grant that may put reads what came of the tasks; one that may not is
# denied. Both read nothing on stdin: a word with input still answers.
"$bin/fake-ssh" "$putter_grant" status </dev/null | grep -E '^pending=[0-9]+ leased=[0-9]+ done=[0-9]+ failed=[0-9]+$' >/dev/null; check
"$bin/fake-ssh" "$putter_grant" 'status --json' </dev/null \
  | jq -e --argjson n "$pending_before_remote_put" '.pending == $n + 2' >/dev/null; check
diff <("$bin/fake-ssh" "$putter_grant" results </dev/null) <(spoolg results); check
diff <(printf 'ignored\n' | "$bin/fake-ssh" "$putter_grant" failures) <(spoolg failures); check
for word in results failures status 'status --json'; do
  expect_exit 5 "$bin/fake-ssh" "$reader_grant" "$word" </dev/null
  test ! -s "$work/exit.stdout"; check
done
# collect is a remote word for a grant that may put (ADR 0018); one that may
# not is denied before a line is read, and the task is still there.
printf '%s\n' '{"task_id":"000-remote-collect","capability":"classify@1","payload":{}}' \
  | spoolg put >/dev/null
spoolg lease --worker local-collector > "$work/remote-collect-lease.jsonl"
jq -e '.task_id == "000-remote-collect"' "$work/remote-collect-lease.jsonl" >/dev/null; check
jq -c '{task_id, lease_id, result: {collected: "remotely"}}' "$work/remote-collect-lease.jsonl" \
  | spoolg ack >/dev/null
remote_collect_line='{"task_id":"000-remote-collect"}'
set +e
printf '%s\n' "$remote_collect_line" | "$bin/fake-ssh" "$reader_grant" collect \
  > "$work/remote-collect-denied.out" 2>/dev/null
remote_collect_denied=$?
set -e
test "$remote_collect_denied" -eq 5; check
test ! -s "$work/remote-collect-denied.out"; check
spoolg results | jq -s -e 'map(select(.task_id == "000-remote-collect")) | length == 1' >/dev/null; check
printf '%s\n' "$remote_collect_line" | "$bin/fake-ssh" "$putter_grant" collect \
  | jq -e '. == {task_id:"000-remote-collect", status:"collected"}' >/dev/null; check
spoolg results | jq -s -e 'map(select(.task_id == "000-remote-collect")) | length == 0' >/dev/null; check
# A task with attachments cannot come this way.
set +e
jq -nc --arg digest "$attachment_digest" --argjson size "$attachment_size" \
  '{task_id:"remote-put-attached",capability:"attachments@1",payload:{},attachments:[{sha256:$digest,size:$size}]}' \
  | "$bin/fake-ssh" "$putter_grant" put >/dev/null 2>&1
remote_put_attached=$?
set -e
test "$remote_put_attached" -eq 2; check

# A task with an attachment, staged on the spool host, for the remote worker
# to fetch.
jq -nc --arg digest "$attachment_digest" --argjson size "$attachment_size" \
  '{task_id:"remote-put-c",capability:"attachments@1",payload:{},attachments:[{sha256:$digest,size:$size}]}' \
  | spoolg put --attachments "$attachment_source" >/dev/null

# work --via runs the worker through the transport: three tasks are leased
# under the grant's worker name, one fetches its attachment, and the results
# land on the spool. No --worker is given; the grant names it.
jq -nc --arg classify "$bin/echo-classify" --arg list "$bin/list-attachments" --arg path "$worker_path" \
  '{max_concurrent: 2, renew_seconds: 30, env: {PATH: $path},
    capabilities: {
      "classify@1": {exec: $classify, args: [], timeout_seconds: 10, max_payload_bytes: 1024, max_output_bytes: 4096},
      "attachments@1": {exec: $list, args: [], timeout_seconds: 10, max_payload_bytes: 1024, max_output_bytes: 4096}}}' \
  > "$work/remote-worker.json"
"$spool_binary" work --via "$bin/fake-ssh $putter_grant" --config "$work/remote-worker.json" --max-tasks 3
spoolg results | jq -s --arg digest "$attachment_digest" -e '
  (map(select(.task_id == "remote-put-a")) | length == 1 and .[0].worker == "putter"
     and .[0].result == {echoed: {n: 1}}) and
  (map(select(.task_id == "remote-put-b")) | length == 1 and .[0].result == {attachments: []}) and
  (map(select(.task_id == "remote-put-c")) | length == 1 and .[0].worker == "putter"
     and .[0].result == {attachments: [$digest]})' >/dev/null; check
test ! -e "$work/grant-spool/attachments/task-remote-put-c"; check
spoolg status --json | jq -e --argjson n "$pending_before_remote_put" '.pending == $n' >/dev/null; check

# With nothing pending the remote worker exits 0, like a local one.
"$spool_binary" work --via "$bin/fake-ssh $reader_grant" --config "$work/remote-worker.json"
check

# A failure on the remote worker is recorded on the spool, with its reason.
printf '%s\n' '{"task_id":"remote-crash","capability":"crash@1","payload":{}}' \
  | "$bin/fake-ssh" "$putter_grant" put >/dev/null
jq -c --arg crash "$bin/crash-three" \
  '.capabilities["crash@1"] = {exec: $crash, args: [], timeout_seconds: 10, max_payload_bytes: 1024, max_output_bytes: 4096}' \
  "$work/remote-worker.json" > "$work/remote-worker-crash.json"
"$spool_binary" work --via "$bin/fake-ssh $reader_grant" --config "$work/remote-worker-crash.json" --max-tasks 1
spoolg failures | jq -s --arg task remote-crash -e \
  'map(select(.task_id == $task)) | length == 1 and .[0].worker == "reader" and .[0].retried == true
   and (.[0].reason | test("exit 3"))' >/dev/null; check
"$bin/fake-ssh" "$reader_grant" lease > "$work/remote-crash-lease.jsonl"
jq -c '{task_id, lease_id, result: {drained: true}}' "$work/remote-crash-lease.jsonl" \
  | "$bin/fake-ssh" "$reader_grant" ack >/dev/null

# The cap and exit 65 hold for a remote worker as for a local one.
printf '%s\n' '{"task_id":"remote-crash-cap","capability":"crash@1","payload":{}}' \
  | "$bin/fake-ssh" "$putter_grant" put >/dev/null
# One run at a time, so each retry is pending again when the next lease is asked for.
jq -c '.max_concurrent = 1' "$work/remote-worker-crash.json" > "$work/remote-worker-crash-serial.json"
"$spool_binary" work --via "$bin/fake-ssh $reader_grant" --config "$work/remote-worker-crash-serial.json" --max-tasks 5
spoolg failures | jq -s --arg task remote-crash-cap -e \
  'map(select(.task_id == $task)) | length == 3 and map(.retried) == [true, true, false]
   and map(.worker) == ["reader", "reader", "reader"]' >/dev/null; check
printf '%s\n' '{"task_id":"remote-hopeless","capability":"hopeless@1","payload":{}}' \
  | "$bin/fake-ssh" "$putter_grant" put >/dev/null
jq -c --arg hopeless "$bin/hopeless" \
  '.capabilities["hopeless@1"] = {exec: $hopeless, args: [], timeout_seconds: 10, max_payload_bytes: 1024, max_output_bytes: 4096}' \
  "$work/remote-worker.json" > "$work/remote-worker-hopeless.json"
"$spool_binary" work --via "$bin/fake-ssh $reader_grant" --config "$work/remote-worker-hopeless.json" --max-tasks 5
spoolg failures | jq -s --arg task remote-hopeless -e \
  'map(select(.task_id == $task)) | length == 1 and .[0].retried == false
   and (.[0].reason | startswith("exit 65: "))' >/dev/null; check
# Through the remote command, the third fail is answered failed.
printf '%s\n' '{"task_id":"remote-fail-cap","capability":"crash@1","payload":{}}' \
  | "$bin/fake-ssh" "$putter_grant" put >/dev/null
for expected in failed_retry failed_retry failed; do
  "$bin/fake-ssh" "$reader_grant" lease > "$work/remote-cap-lease.jsonl"
  jq -e '.task_id == "remote-fail-cap"' "$work/remote-cap-lease.jsonl" >/dev/null; check
  jq -c '{task_id, lease_id, reason: "remote"}' "$work/remote-cap-lease.jsonl" \
    | "$bin/fake-ssh" "$reader_grant" fail | jq -e --arg s "$expected" '.status == $s' >/dev/null; check
done

# A lease reclaimed while the remote worker runs fences its acknowledgement:
# the worker exits 4 and the spool keeps no result, as locally.
printf '%s\n' '{"task_id":"remote-late","capability":"late@1","payload":{}}' \
  | "$bin/fake-ssh" "$putter_grant" put >/dev/null
jq -c --arg late "$bin/wait-for-late-release" \
  '.capabilities["late@1"] = {exec: $late, args: [], timeout_seconds: 10, max_payload_bytes: 1024, max_output_bytes: 4096}' \
  "$work/remote-worker.json" > "$work/remote-worker-late.json"
rm -f "$late_start" "$late_release"
set +e
"$spool_binary" work --via "$bin/fake-ssh $reader_grant" --config "$work/remote-worker-late.json" --max-tasks 1 &
remote_late_worker=$!
set -e
i=0
while [ ! -f "$late_start" ] && [ "$i" -lt 100 ]; do
  sleep 0.1
  i=$((i + 1))
done
test -f "$late_start"; check
spoolg reclaim --older-than 0 | jq -e '.task_id == "remote-late"' >/dev/null; check
: > "$late_release"
set +e
wait "$remote_late_worker"
remote_late_exit=$?
set -e
test "$remote_late_exit" -eq 4; check
spoolg results | jq -s -e 'map(select(.task_id == "remote-late")) | length == 0' >/dev/null; check
"$bin/fake-ssh" "$reader_grant" lease > "$work/remote-late-lease.jsonl"
jq -c '{task_id, lease_id, result: {replacement: true}}' "$work/remote-late-lease.jsonl" \
  | "$bin/fake-ssh" "$reader_grant" ack >/dev/null

# A transport that cannot reach the spool ends the worker with 75; a grant
# that has been revoked ends it with 5. Either way nothing is leased.
expect_exit 75 "$spool_binary" work --via "$bin/broken-ssh anywhere" --config "$work/remote-worker.json"
HOME="$grant_home" "$spool_binary" --dir "$work/grant-spool" revoke --grant "$reader_grant" >/dev/null
expect_exit 5 "$spool_binary" work --via "$bin/fake-ssh $reader_grant" --config "$work/remote-worker.json"

# Revoke disables access, removes only its managed line, and reclaims leases
# for the fixed worker. The old lease remains fenced after return to pending.
printf '%s\n' '{"task_id":"remote-revoke","capability":"remote@1","payload":{}}' \
  | spoolg put >/dev/null
remote_primary 'lease' > "$work/revoke-lease.jsonl"
revoke_lease=$(jq -r '.lease_id' "$work/revoke-lease.jsonl")
HOME="$grant_home" "$spool_binary" --dir "$work/grant-spool" revoke --grant "$grant_id" \
  | jq -e --arg grant "$grant_id" '.grant_id == $grant and .status == "revoked"' >/dev/null; check
test ! -e "$grant_home/.spool/grants/$grant_id.json"; check
if grep -F "spool-grant:$grant_id" "$grant_home/.ssh/authorized_keys" >/dev/null; then false; fi; check
test "$(head -n 1 "$grant_home/.ssh/authorized_keys")" = '# unrelated key material'; check
spoolg status --json | jq -e '.pending >= 1' >/dev/null; check
# The revoked lease is an attempt, recorded as a reclaim is.
spoolg failures | jq -s --arg lease "$revoke_lease" -e \
  'map(select(.lease_id == $lease)) | length == 1
   and .[0].retried == true and .[0].reason == "reclaimed: grant revoked"' >/dev/null; check
expect_exit 5 env HOME="$grant_home" SSH_ORIGINAL_COMMAND=lease \
  "$spool_binary" remote --grant "$grant_id"
late_revoke_ack=$(jq -nc --arg lease "$revoke_lease" \
  '{task_id:"remote-revoke",lease_id:$lease,result:{late:true}}')
set +e
printf '%s\n' "$late_revoke_ack" | spoolg ack >/dev/null 2>&1
late_revoke_exit=$?
set -e
test "$late_revoke_exit" -eq 4; check
HOME="$grant_home" "$spool_binary" --dir "$work/grant-spool" revoke --grant "$grant_id" \
  | jq -e '.status == "revoked"' >/dev/null; check

#############################################################################
# A worker that follows its spool (ADR 0019) waits for work instead of
# stopping, asks again after a transport failure, and stops at SIGTERM or a
# refusal.
#############################################################################

# Wait up to five seconds for a command to succeed.
eventually() {
  local i=0
  until "$@"; do
    i=$((i + 1))
    test "$i" -lt 50 || return 1
    sleep 0.1
  done
}
result_for() { spoolfo results | jq -e --arg task "$1" 'select(.task_id == $task)' >/dev/null; }

spoolfo() { "$spool_binary" --dir "$work/follow" "$@"; }
spoolfo init
worker_config "classify@1" "$bin/echo-classify" 5 1024 > "$work/follow-config.json"

# A task put after the worker went idle is done by the same worker. It has
# found nothing pending more than once before the second task is put.
printf '%s\n' '{"task_id":"follow-first","capability":"classify@1","payload":{"n":1}}' | spoolfo put >/dev/null
# The binary itself is started in the background, not a shell function
# around it, so that the signal below reaches the worker and not a subshell.
"$spool_binary" --dir "$work/follow" work --worker follower --config "$work/follow-config.json" \
  --follow --idle-seconds 1 2>"$work/follow.stderr" &
follower=$!
eventually result_for follow-first; check
sleep 1.5
kill -0 "$follower"; check
printf '%s\n' '{"task_id":"follow-later","capability":"classify@1","payload":{"n":2}}' | spoolfo put >/dev/null
eventually result_for follow-later; check
spoolfo results | jq -s -e 'map(select(.task_id == "follow-later")) | .[0].worker == "follower"
  and .[0].result == {echoed: {n: 2}}' >/dev/null; check

# SIGTERM ends a worker with the signal's status, having said nothing.
kill -TERM "$follower"
set +e
wait "$follower"
follower_exit=$?
set -e
test "$follower_exit" -eq 143; check
test ! -s "$work/follow.stderr"; check
# It ends one in the middle of a wait at once, not when the wait is over.
# Its waits are 1, 2, then 4 seconds, so 3.5 seconds in it is 0.5 seconds
# into a wait of 4.
"$spool_binary" --dir "$work/follow" work --worker sleeper --config "$work/follow-config.json" \
  --follow --idle-seconds 600 &
long_follower=$!
sleep 3.5
stop_started=${EPOCHREALTIME/./}
kill -TERM "$long_follower"
set +e
wait "$long_follower"
long_follower_exit=$?
set -e
stop_took=$(( ${EPOCHREALTIME/./} - stop_started ))
test "$long_follower_exit" -eq 143; check
test "$stop_took" -lt 1000000; check
spoolfo status --json | jq -e '.pending == 0 and .leased == 0' >/dev/null; check

# A transport that fails twice is said twice on stderr and asked again; the
# third request reaches the spool and the task is done. Every pending task is
# run, so the worker stops at its count.
cat > "$bin/flaky-ssh" <<SCRIPT
#!/bin/sh
count=\$(cat "$work/flaky-count" 2>/dev/null || echo 0)
count=\$((count + 1))
echo "\$count" >| "$work/flaky-count"
if [ "\$count" -le 2 ]; then
  echo "ssh: connect to host spool-host: network is unreachable" >&2
  exit 255
fi
exec "$bin/fake-ssh" "\$@"
SCRIPT
chmod +x "$bin/flaky-ssh"
printf '%s\n' '{"task_id":"follow-flaky","capability":"classify@1","payload":{"n":3}}' \
  | "$bin/fake-ssh" "$putter_grant" put >/dev/null
flaky_pending=$(spoolg status --json | jq -r '.pending')
test "$flaky_pending" -ge 1; check
"$spool_binary" work --via "$bin/flaky-ssh $putter_grant" --config "$work/remote-worker.json" \
  --follow --idle-seconds 1 --max-tasks "$flaky_pending" 2>"$work/flaky.stderr"
test "$(grep -c '^spool: work: lease failed, asking again in 1 s: transport .* exited 255$' "$work/flaky.stderr")" -eq 2; check
spoolg results | jq -s -e 'map(select(.task_id == "follow-flaky")) | .[0].worker == "putter"
  and .[0].result == {echoed: {n: 3}}' >/dev/null; check

# A grant that has been revoked is refused, and a following worker stops at
# once with the spool's status rather than waiting to ask again.
# A worker that kept knocking would be cut off by the timeout's 124.
expect_exit 5 timeout 10 "$spool_binary" work --via "$bin/fake-ssh $reader_grant" \
  --config "$work/remote-worker.json" --follow --idle-seconds 1
if grep -q 'asking again' "$work/exit.stderr"; then
  echo "a refused grant was asked again" >&2; exit 1
fi
check

# --idle-seconds belongs to --follow.
expect_exit 2 spoolfo work --worker w --config "$work/follow-config.json" --idle-seconds 5

#############################################################################
# The three decisions together: a task's attempts (ADR 0017), retention
# (ADR 0018), and a worker that follows its spool (ADR 0019).
#############################################################################

# lease_fail DIR TASK: lease TASK, fail it with retry, print the answer.
lease_fail() {
  local lease
  lease=$(in_spool "$1" lease --worker together | jq -r --arg task "$2" 'select(.task_id == $task) | .lease_id')
  test -n "$lease"
  jq -nc --arg task "$2" --arg lease "$lease" '{task_id:$task,lease_id:$lease,reason:"again"}' \
    | in_spool "$1" fail | jq -r '.status'
}
# lease_reclaim DIR TASK: lease TASK, reclaim it at once, print the answer.
lease_reclaim() {
  in_spool "$1" lease --worker together | jq -e --arg task "$2" '.task_id == $task' >/dev/null
  in_spool "$1" reclaim --older-than 0 | jq -r --arg task "$2" 'select(.task_id == $task) | .status'
}
attempts_of() { in_spool "$1" failures | jq -s --arg task "$2" 'map(select(.task_id == $task)) | length'; }

# Collecting a task forgets its attempts with it: a task done after two
# retried failures, collected, and put again has three attempts again.
in_spool together init
put_one together t-collected >/dev/null
test "$(lease_fail together t-collected)" = "failed_retry"; check
test "$(lease_fail together t-collected)" = "failed_retry"; check
ack_one together t-collected "$(lease_one together)" | jq -e '.status == "acked"' >/dev/null; check
put_one together t-collected | jq -e '.status == "existing"' >/dev/null; check
collect_ids together t-collected | jq -e '.status == "collected"' >/dev/null; check
put_one together t-collected | jq -e '.status == "inserted"' >/dev/null; check
test "$(lease_fail together t-collected)" = "failed_retry"; check
test "$(lease_fail together t-collected)" = "failed_retry"; check
test "$(lease_fail together t-collected)" = "failed"; check

# A task the cap failed by reclaims is finished, so gc ages it out with
# every record of its attempts, and put again it has three attempts again.
in_spool cap-gc init
put_one cap-gc t-reclaimed >/dev/null
test "$(lease_reclaim cap-gc t-reclaimed)" = "reclaimed"; check
test "$(lease_reclaim cap-gc t-reclaimed)" = "reclaimed"; check
test "$(lease_reclaim cap-gc t-reclaimed)" = "failed"; check
in_spool cap-gc status --json | jq -e '. == {pending:0,leased:0,done:0,failed:3}' >/dev/null; check
in_spool cap-gc gc --older-than 0 | jq -s -e '. == [{task_id:"t-reclaimed", status:"expired"}]' >/dev/null; check
test "$(attempts_of cap-gc t-reclaimed)" -eq 0; check
put_one cap-gc t-reclaimed | jq -e '.status == "inserted"' >/dev/null; check
test "$(lease_reclaim cap-gc t-reclaimed)" = "reclaimed"; check
test "$(attempts_of cap-gc t-reclaimed)" -eq 1; check

# After the cap fails a task by reclaims and the task is collected, nothing
# of it is left: failures lists none of its attempts, and status counts
# none of them, as it counts only what the spool holds.
in_spool cap-collect init
put_one cap-collect t-counted >/dev/null
put_one cap-collect u-waiting >/dev/null
for attempt in 1 2 3; do
  in_spool cap-collect lease --worker together | jq -e '.task_id == "t-counted"' >/dev/null
  # Only t-counted is leased, so only it is reclaimed.
  in_spool cap-collect reclaim --older-than 0 >/dev/null
done
in_spool cap-collect failures | jq -s -e 'map(.retried) == [true, true, false]' >/dev/null; check
in_spool cap-collect status --json | jq -e '. == {pending:1,leased:0,done:0,failed:3}' >/dev/null; check
collect_ids cap-collect t-counted u-waiting | jq -s -e \
  '. == [{task_id:"t-counted", status:"collected"}, {task_id:"u-waiting", status:"not_finished"}]' >/dev/null; check
test -z "$(in_spool cap-collect failures)"; check
in_spool cap-collect status --json | jq -e '. == {pending:1,leased:0,done:0,failed:0}' >/dev/null; check
collect_ids cap-collect t-counted | jq -e '.status == "unknown"' >/dev/null; check

# A following worker does not loop on a task that can never succeed: the
# cap fails one that always crashes after three runs, exit 65 fails one
# after one, and then the worker waits, running nothing more.
in_spool follow-cap init
jq -nc --arg crash "$bin/crash-three" --arg hopeless "$bin/hopeless" --arg path "$worker_path" \
  '{max_concurrent: 1, renew_seconds: 30, env: {PATH: $path},
    capabilities: {
      "crash@1": {exec: $crash, args: [], timeout_seconds: 10, max_payload_bytes: 1024, max_output_bytes: 4096},
      "hopeless@1": {exec: $hopeless, args: [], timeout_seconds: 10, max_payload_bytes: 1024, max_output_bytes: 4096}}}' \
  > "$work/follow-cap.json"
printf '%s\n%s\n' '{"task_id":"crashes","capability":"crash@1","payload":{}}' \
  '{"task_id":"hopeless","capability":"hopeless@1","payload":{}}' | in_spool follow-cap put >/dev/null
"$spool_binary" --dir "$work/follow-cap" work --worker follower --config "$work/follow-cap.json" \
  --follow --idle-seconds 1 2>"$work/follow-cap.stderr" &
cap_follower=$!
both_finished() {
  in_spool follow-cap failures | jq -s -e '
    (map(select(.task_id == "crashes")) | map(.retried)) == [true, true, false] and
    (map(select(.task_id == "hopeless")) | map(.retried)) == [false]' >/dev/null
}
eventually both_finished; check
# Two more empty leases, at 1 s and 2 s, and still nothing more is run.
sleep 2.5
both_finished; check
in_spool follow-cap status --json | jq -e '. == {pending:0,leased:0,done:0,failed:4}' >/dev/null; check
kill -0 "$cap_follower"; check
kill -TERM "$cap_follower"
set +e
wait "$cap_follower"
cap_follower_exit=$?
set -e
test "$cap_follower_exit" -eq 143; check

#############################################################################
# Result attachments (ADR 0020): a program leaves files in outputs/, named by
# their digests; the worker sends each under its lease, the ack files them
# with the task, take reads one back verified, and collect and gc delete
# them with the task.
#############################################################################

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
size_of() { wc -c < "$1" | tr -d ' '; }
# The request line of a send for this file.
send_line() {
  jq -nc --arg task "$1" --arg lease "$2" --arg sha "$(sha256_of "$3")" --argjson size "$(size_of "$3")" \
    '{task_id:$task,lease_id:$lease,sha256:$sha,size:$size}'
}
# send_file DIR TASK LEASE FILE: send the file under the lease, locally.
send_file() { { send_line "$2" "$3" "$4"; cat "$4"; } | in_spool "$1" send; }
take_line() { jq -nc --arg task "$1" --arg sha "$2" '{task_id:$task,sha256:$sha}'; }
staged_in() { find "$work/$1/result-attachments/leases" -type f | wc -l | tr -d ' '; }
filed_in() { find "$work/$1/result-attachments/tasks" -type f | wc -l | tr -d ' '; }

# Writes the bytes the payload asks for to two files in outputs/, each named
# by its digest, and a result that names them. It keeps a copy of each where
# the payload says, so that what take returns can be compared with what the
# program wrote.
cat > "$bin/stems" <<'SCRIPT'
#!/bin/sh
payload=$(cat)
keep=$(printf '%s' "$payload" | jq -r '.keep')
bytes=$(printf '%s' "$payload" | jq -r '.bytes')
digest() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
mkdir outputs
head -c "$bytes" /dev/urandom > outputs/vocals
printf 'drums of %s\n' "$payload" > outputs/drums
vocals=$(digest outputs/vocals)
drums=$(digest outputs/drums)
mkdir -p "$keep"
cp outputs/vocals "$keep/$vocals"
cp outputs/drums "$keep/$drums"
mv outputs/vocals "outputs/$vocals"
mv outputs/drums "outputs/$drums"
printf '{"vocals":"%s","drums":"%s"}\n' "$vocals" "$drums"
SCRIPT
chmod +x "$bin/stems"
# Leaves in outputs/ whatever the payload's "make" says, then answers.
cat > "$bin/leave" <<'SCRIPT'
#!/bin/sh
payload=$(cat)
mkdir outputs
sh -c "$(printf '%s' "$payload" | jq -r '.make')"
printf '{"left":true}\n'
SCRIPT
chmod +x "$bin/leave"

ra_config() {
  # ra_config CAPABILITY EXEC [MAX_RESULT_ATTACHMENT_BYTES [RENEW_SECONDS TIMEOUT_SECONDS]]
  jq -nc --arg cap "$1" --arg exec "$2" --arg limit "${3:-}" --arg path "$worker_path" \
    --argjson renew "${4:-30}" --argjson timeout "${5:-20}" \
    '{max_concurrent: 1, renew_seconds: $renew, env: {PATH: $path},
      capabilities: {($cap): ({exec: $exec, args: [], timeout_seconds: $timeout,
        max_payload_bytes: 4096, max_output_bytes: 4096}
        + (if $limit == "" then {} else {max_result_attachment_bytes: ($limit | tonumber)} end))}}'
}
ra_put() {
  jq -nc --arg task "$2" --arg cap "$3" --argjson payload "$4" \
    '{task_id:$task,capability:$cap,payload:$payload}' | in_spool "$1" put >/dev/null
}

# The whole chain, on the spool's host: two outputs are sent and filed, the
# result names them, results lists them, take returns exactly the bytes the
# program wrote, and collect leaves nothing of them in the spool directory.
in_spool ra init
ra_config stems@1 "$bin/stems" 1000000 > "$work/ra-stems.json"
ra_put ra ra-one stems@1 "$(jq -nc --arg keep "$work/ra-kept/one" '{keep:$keep,bytes:300000}')"
in_spool ra work --worker ra-local --config "$work/ra-stems.json" --max-tasks 1
in_spool ra results | jq -s -e 'length == 1 and .[0].task_id == "ra-one"' >/dev/null; check
ra_vocals=$(in_spool ra results | jq -r '.result.vocals')
ra_drums=$(in_spool ra results | jq -r '.result.drums')
test "$ra_vocals" != "$ra_drums"; check
test "$(sha256_of "$work/ra-kept/one/$ra_vocals")" = "$ra_vocals"; check
test "$(size_of "$work/ra-kept/one/$ra_vocals")" = 300000; check
in_spool ra results | jq -s -e \
  --arg v "$ra_vocals" --arg d "$ra_drums" --argjson dsize "$(size_of "$work/ra-kept/one/$ra_drums")" \
  '.[0].attachments == ([{sha256:$v,size:300000},{sha256:$d,size:$dsize}] | sort_by(.sha256))' >/dev/null; check
test -f "$work/ra/result-attachments/tasks/ra-one/$ra_vocals"; check
test -f "$work/ra/result-attachments/tasks/ra-one/$ra_drums"; check
test "$(staged_in ra)" = 0; check
for digest in "$ra_vocals" "$ra_drums"; do
  take_line ra-one "$digest" | in_spool ra take > "$work/ra-taken"
  cmp "$work/ra-taken" "$work/ra-kept/one/$digest"; check
done
collect_ids ra ra-one | jq -e '.status == "collected"' >/dev/null; check
test ! -e "$work/ra/result-attachments/tasks/ra-one"; check
test "$(find "$work/ra/result-attachments" -type f | wc -l | tr -d ' ')" = 0; check
expect_exit 2 sh -c "printf '%s\n' '$(take_line ra-one "$ra_vocals")' | '$spool_binary' --dir '$work/ra' take"
test ! -s "$work/exit.stdout"; check

# gc deletes them with the task too.
ra_put ra ra-aged stems@1 "$(jq -nc --arg keep "$work/ra-kept/aged" '{keep:$keep,bytes:10}')"
in_spool ra work --worker ra-local --config "$work/ra-stems.json" --max-tasks 1
test "$(filed_in ra)" = 2; check
in_spool ra gc --older-than 0 | jq -e '. == {task_id:"ra-aged",status:"expired"}' >/dev/null; check
test "$(find "$work/ra/result-attachments" -type f | wc -l | tr -d ' ')" = 0; check

# A run that leaves nothing in outputs/ acknowledges as 0.0.3 did: the result
# record has no attachments field, and nothing is sent.
ra_config leave@1 "$bin/leave" 100 > "$work/ra-leave.json"
ra_put ra ra-none leave@1 '{"make":"true"}'
in_spool ra work --worker ra-local --config "$work/ra-leave.json" --max-tasks 1
jq -e 'has("attachments") | not' "$work"/ra/results/*_ra-none.json >/dev/null; check
in_spool ra results | jq -e 'select(.task_id == "ra-none") | has("attachments") | not' >/dev/null; check

# Every way outputs/ breaks the rules fails the task for good, sends nothing,
# and says why.
ra_refused() {
  # ra_refused TASK CONFIG MAKE REASON
  ra_put ra "$1" leave@1 "$(jq -nc --arg make "$3" '{make:$make}')"
  in_spool ra work --worker ra-local --config "$2" --max-tasks 1
  in_spool ra failures | jq -s -e --arg task "$1" --arg reason "$4" \
    'map(select(.task_id == $task)) | length == 1 and .[0].retried == false
     and (.[0].reason | contains($reason))' >/dev/null; check
  in_spool ra results | jq -s -e --arg task "$1" 'map(select(.task_id == $task)) | length == 0' >/dev/null; check
  test "$(staged_in ra)" = 0; check
}
abc_digest=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
ra_refused ra-link "$work/ra-leave.json" \
  "printf abc > elsewhere; ln -s \"\$PWD/elsewhere\" outputs/$abc_digest" "is a symbolic link"
ra_refused ra-dir "$work/ra-leave.json" "mkdir outputs/$abc_digest" "is a directory"
ra_refused ra-misnamed "$work/ra-leave.json" "printf abc > outputs/vocals.flac" "is not named by a sha256 digest"
ra_refused ra-unhashed "$work/ra-leave.json" "printf abd > outputs/$abc_digest" "does not hash to its name"
ra_refused ra-outputs-file "$work/ra-leave.json" "rmdir outputs; printf abc > outputs" "outputs is not a directory"
ra_config leave@1 "$bin/leave" > "$work/ra-leave-no-limit.json"
ra_refused ra-no-limit "$work/ra-leave-no-limit.json" "printf abc > outputs/$abc_digest" \
  "the capability sets no max_result_attachment_bytes"
ra_config leave@1 "$bin/leave" 2 > "$work/ra-leave-two.json"
ra_refused ra-over "$work/ra-leave-two.json" "printf abc > outputs/$abc_digest" \
  "over max_result_attachment_bytes 2"
# At the limit, it is sent.
ra_config leave@1 "$bin/leave" 3 > "$work/ra-leave-three.json"
ra_put ra ra-at-limit leave@1 "$(jq -nc --arg make "printf abc > outputs/$abc_digest" '{make:$make}')"
in_spool ra work --worker ra-local --config "$work/ra-leave-three.json" --max-tasks 1
in_spool ra results | jq -e --arg d "$abc_digest" \
  'select(.task_id == "ra-at-limit") | .attachments == [{sha256:$d,size:3}]' >/dev/null; check

# send, by hand: exactly the declared bytes, under a lease in flight. What
# it refuses, it stores nothing of.
printf 'abc' > "$work/ra-abc"
printf 'hello, stems\n' > "$work/ra-hello"
ra_put ra ra-hand leave@1 '{}'
ra_hand_lease=$(in_spool ra lease --worker ra-hand | jq -r '.lease_id')
ra_hand_dir="$work/ra/result-attachments/leases/$ra_hand_lease"
{ jq -nc --arg lease "$ra_hand_lease" --arg sha "$abc_digest" '{task_id:"ra-hand",lease_id:$lease,sha256:$sha,size:4}'
  printf 'abc'; } > "$work/ra-short"
expect_exit 2 in_spool ra send < "$work/ra-short"
{ jq -nc --arg lease "$ra_hand_lease" --arg sha "$abc_digest" '{task_id:"ra-hand",lease_id:$lease,sha256:$sha,size:3}'
  printf 'abcd'; } > "$work/ra-long"
expect_exit 2 in_spool ra send < "$work/ra-long"
# The same past the bytes read with the request line, so that the end of
# the stream is looked for in the stream itself.
head -c 5000 /dev/urandom > "$work/ra-five-thousand"
{ send_line ra-hand "$ra_hand_lease" "$work/ra-five-thousand"; cat "$work/ra-five-thousand"; printf x; } \
  > "$work/ra-longer"
expect_exit 2 in_spool ra send < "$work/ra-longer"
{ jq -nc --arg lease "$ra_hand_lease" --arg sha "$abc_digest" '{task_id:"ra-hand",lease_id:$lease,sha256:$sha,size:3}'
  printf 'abd'; } > "$work/ra-wrong"
expect_exit 2 in_spool ra send < "$work/ra-wrong"
{ jq -nc --arg lease "$ra_hand_lease" --arg sha "$abc_digest" '{task_id:"ra-hand",lease_id:$lease,sha256:$sha,size:3,name:"x.flac"}'
  printf 'abc'; } > "$work/ra-named"
expect_exit 2 in_spool ra send < "$work/ra-named"
test -z "$(ls -A "$ra_hand_dir" 2>/dev/null)"; check
send_file ra ra-hand "$ra_hand_lease" "$work/ra-abc" \
  | jq -e --arg lease "$ra_hand_lease" '. == {task_id:"ra-hand",lease_id:$lease,status:"staged"}' >/dev/null; check
cmp "$ra_hand_dir/$abc_digest" "$work/ra-abc"; check
# Sending the same file again changes nothing.
send_file ra ra-hand "$ra_hand_lease" "$work/ra-abc" | jq -e '.status == "staged"' >/dev/null; check
test "$(ls -A "$ra_hand_dir" | tr '\n' ' ')" = "$abc_digest "; check
# A send on a lease that is not in flight is stale, and stores nothing.
expect_exit 4 send_file ra ra-hand lease_1_999_ra-hand "$work/ra-abc"
test ! -e "$work/ra/result-attachments/leases/lease_1_999_ra-hand"; check
expect_exit 4 send_file ra other-task "$ra_hand_lease" "$work/ra-abc"

# An ack may name only what was staged, whole, under its lease. One that
# names more is malformed input, refused before any line is acted on.
hello_digest=$(sha256_of "$work/ra-hello")
ra_ack_line() {
  jq -nc --arg task "$1" --arg lease "$2" --argjson attachments "$3" \
    '{task_id:$task,lease_id:$lease,result:{hand:true},attachments:$attachments}'
}
ra_put ra ra-hand-two leave@1 '{}'
ra_hand_two_lease=$(in_spool ra lease --worker ra-hand | jq -r '.lease_id')
ra_abc_only=$(jq -nc --arg d "$abc_digest" '[{sha256:$d,size:3}]')
ra_unstaged=$(jq -nc --arg d "$abc_digest" --arg h "$hello_digest" \
  '[{sha256:$d,size:3},{sha256:$h,size:13}] | sort_by(.sha256)')
ra_wrong_size=$(jq -nc --arg d "$abc_digest" '[{sha256:$d,size:4}]')
{ ra_ack_line ra-hand-two "$ra_hand_two_lease" '[]'
  ra_ack_line ra-hand "$ra_hand_lease" "$ra_unstaged"; } > "$work/ra-unstaged-acks"
expect_exit 2 in_spool ra ack < "$work/ra-unstaged-acks"
test ! -s "$work/exit.stdout"; check
expect_exit 2 sh -c "printf '%s\n' '$(ra_ack_line ra-hand "$ra_hand_lease" "$ra_wrong_size")' | '$spool_binary' --dir '$work/ra' ack"
test -f "$work/ra/leased/$ra_hand_lease.json"; check
test -f "$work/ra/leased/$ra_hand_two_lease.json"; check
test -z "$(find "$work/ra/results" -name "*_ra-hand*.json")"; check
# The ack that names what was staged files it, and a repeat of it is
# already done; one naming other attachments is stale, as a different
# result is.
ra_ack_line ra-hand "$ra_hand_lease" "$ra_abc_only" | in_spool ra ack | jq -e '.status == "acked"' >/dev/null; check
ra_ack_line ra-hand "$ra_hand_lease" "$ra_abc_only" | in_spool ra ack | jq -e '.status == "already_done"' >/dev/null; check
expect_exit 4 sh -c "printf '%s\n' '$(ra_ack_line ra-hand "$ra_hand_lease" '[]')' | '$spool_binary' --dir '$work/ra' ack"
jq -e '.status == "stale"' "$work/exit.stdout" >/dev/null; check
test ! -e "$ra_hand_dir"; check
cmp "$work/ra/result-attachments/tasks/ra-hand/$abc_digest" "$work/ra-abc"; check
ra_ack_line ra-hand-two "$ra_hand_two_lease" '[]' | in_spool ra ack | jq -e '.status == "acked"' >/dev/null; check

# take reads only a done task's declared result attachments.
take_line ra-hand "$abc_digest" | in_spool ra take > "$work/ra-taken"
cmp "$work/ra-taken" "$work/ra-abc"; check
expect_exit 2 sh -c "printf '%s\n' '$(take_line ra-hand "$hello_digest")' | '$spool_binary' --dir '$work/ra' take"
test ! -s "$work/exit.stdout"; check
expect_exit 2 sh -c "printf '%s\n' '$(take_line ra-nobody "$abc_digest")' | '$spool_binary' --dir '$work/ra' take"
ra_put ra ra-pending leave@1 '{}'
expect_exit 2 sh -c "printf '%s\n' '$(take_line ra-pending "$abc_digest")' | '$spool_binary' --dir '$work/ra' take"
ra_pending_lease=$(in_spool ra lease --worker ra-hand | jq -r '.lease_id')
send_file ra ra-pending "$ra_pending_lease" "$work/ra-abc" >/dev/null
expect_exit 2 sh -c "printf '%s\n' '$(take_line ra-pending "$abc_digest")' | '$spool_binary' --dir '$work/ra' take"
test ! -s "$work/exit.stdout"; check
# A stored file that is not what it was declared to be is corrupt, and
# nothing of it is written.
printf 'abd' > "$work/ra/result-attachments/tasks/ra-hand/$abc_digest"
expect_exit 70 sh -c "printf '%s\n' '$(take_line ra-hand "$abc_digest")' | '$spool_binary' --dir '$work/ra' take"
test ! -s "$work/exit.stdout"; check

# A lease that ends without a result takes what it staged with it: fail,
# fail --no-retry, and reclaim.
test -f "$work/ra/result-attachments/leases/$ra_pending_lease/$abc_digest"; check
fail_one ra ra-pending "$ra_pending_lease" | jq -e '.status == "failed_retry"' >/dev/null; check
test ! -e "$work/ra/result-attachments/leases/$ra_pending_lease"; check
ra_pending_lease=$(in_spool ra lease --worker ra-hand | jq -r '.lease_id')
send_file ra ra-pending "$ra_pending_lease" "$work/ra-abc" >/dev/null
in_spool ra reclaim --older-than 0 | jq -e '.status == "reclaimed"' >/dev/null; check
test ! -e "$work/ra/result-attachments/leases/$ra_pending_lease"; check
ra_pending_lease=$(in_spool ra lease --worker ra-hand | jq -r '.lease_id')
send_file ra ra-pending "$ra_pending_lease" "$work/ra-abc" >/dev/null
fail_one ra ra-pending "$ra_pending_lease" --no-retry | jq -e '.status == "failed"' >/dev/null; check
test ! -e "$work/ra/result-attachments/leases/$ra_pending_lease"; check
test "$(staged_in ra)" = 0; check

# The lock is not held while bytes move. A send whose bytes are still
# coming has made its file and let the lock go: status answers from another
# process, and the lease is renewed, while it waits. A send killed there
# leaves its file, which its lease takes with it when it ends.
ra_put ra ra-slow leave@1 '{}'
ra_slow_lease=$(in_spool ra lease --worker ra-hand | jq -r '.lease_id')
# An anonymous pipe, not a named one: macOS never wakes a reader waiting on
# a FIFO when its last writer closes it, and the send must see its end.
"$spool_binary" --dir "$work/ra" send > "$work/ra-slow.out" < <(
  jq -nc --arg lease "$ra_slow_lease" --arg sha "$abc_digest" '{task_id:"ra-slow",lease_id:$lease,sha256:$sha,size:3}'
  printf 'a'
  until test -e "$work/ra-slow-go"; do sleep 0.1; done
  printf 'bc'
) &
ra_slow_pid=$!
ra_sending() { ls -A "$work/ra/result-attachments/leases/$ra_slow_lease" 2>/dev/null | grep -q '^\.send-3-'; }
eventually ra_sending; check
timeout 5 "$spool_binary" --dir "$work/ra" status --json | jq -e '.leased == 1' >/dev/null; check
jq -nc --arg lease "$ra_slow_lease" '{task_id:"ra-slow",lease_id:$lease}' \
  | timeout 5 "$spool_binary" --dir "$work/ra" renew | jq -e '.status == "renewed"' >/dev/null; check
touch "$work/ra-slow-go"
wait "$ra_slow_pid"; check
jq -e '.status == "staged"' "$work/ra-slow.out" >/dev/null; check
cmp "$work/ra/result-attachments/leases/$ra_slow_lease/$abc_digest" "$work/ra-abc"; check
mkfifo "$work/ra-slow-pipe"
"$spool_binary" --dir "$work/ra" send < "$work/ra-slow-pipe" > /dev/null 2>&1 &
ra_killed_pid=$!
exec 8>"$work/ra-slow-pipe"
jq -nc --arg lease "$ra_slow_lease" --arg sha "$hello_digest" '{task_id:"ra-slow",lease_id:$lease,sha256:$sha,size:13}' >&8
printf 'hel' >&8
ra_sending_hello() { ls -A "$work/ra/result-attachments/leases/$ra_slow_lease" 2>/dev/null | grep -q '^\.send-13-'; }
eventually ra_sending_hello; check
kill -9 "$ra_killed_pid"
set +e
wait "$ra_killed_pid" 2>/dev/null
set -e
exec 8>&-
in_spool ra status >/dev/null
ra_sending_hello; check
in_spool ra reclaim --older-than 0 >/dev/null
test ! -e "$work/ra/result-attachments/leases/$ra_slow_lease"; check

# An ack interrupted after its result was written is finished by the next
# command: here, after one file was filed and before the other was. The
# state is rebuilt from the real writer's own files: the ack is made, then
# its lease, its worker, and one staged file are put back, and its done task
# and the other filed file are taken away.
in_spool ra-crash init
ra_put ra-crash rc-one leave@1 '{}'
rc_lease=$(in_spool ra-crash lease --worker ra-hand | jq -r '.lease_id')
send_file ra-crash rc-one "$rc_lease" "$work/ra-abc" >/dev/null
send_file ra-crash rc-one "$rc_lease" "$work/ra-hello" >/dev/null
mkdir "$work/rc-saved"
cp "$work/ra-crash/leased/$rc_lease.json" "$work/ra-crash/leased/$rc_lease.worker" "$work/rc-saved/"
ra_ack_line rc-one "$rc_lease" "$ra_unstaged" | in_spool ra-crash ack | jq -e '.status == "acked"' >/dev/null; check
cp "$work/rc-saved/$rc_lease.json" "$work/rc-saved/$rc_lease.worker" "$work/ra-crash/leased/"
mkdir "$work/ra-crash/result-attachments/leases/$rc_lease"
mv -f "$work/ra-crash/result-attachments/tasks/rc-one/$hello_digest" "$work/ra-crash/result-attachments/leases/$rc_lease/"
rm -f "$work/ra-crash/done/rc-one.json"
test -f "$work/ra-crash/results/$rc_lease.json"; check
in_spool ra-crash reclaim --older-than 0 > "$work/rc-reclaim.out"
test ! -s "$work/rc-reclaim.out"; check
in_spool ra-crash status --json | jq -e '.leased == 0 and .done == 1' >/dev/null; check
test ! -e "$work/ra-crash/result-attachments/leases/$rc_lease"; check
take_line rc-one "$hello_digest" | in_spool ra-crash take | cmp - "$work/ra-hello"; check
take_line rc-one "$abc_digest" | in_spool ra-crash take | cmp - "$work/ra-abc"; check

# A collect interrupted after its marker is finished by the next command:
# here, the result attachments could not be removed.
chmod 555 "$work/ra-crash/result-attachments/tasks"
expect_exit 75 collect_ids ra-crash rc-one
chmod 755 "$work/ra-crash/result-attachments/tasks"
test -e "$work/ra-crash/.task-cleanup/rc-one"; check
in_spool ra-crash status >/dev/null
test ! -e "$work/ra-crash/.task-cleanup/rc-one"; check
test ! -e "$work/ra-crash/result-attachments/tasks/rc-one"; check
test -z "$(records_of ra-crash rc-one)"; check

# Another machine. The worker sends its outputs over its own grant, and the
# grant holds a limit on the bytes the spool keeps from it: those staged for
# its leases, and those of its results not yet collected.
ra_home="$work/ra-home"
mkdir -p "$ra_home/.ssh"
cat > "$bin/fake-ssh-ra" <<SCRIPT
#!/bin/sh
grant=\$1
word=\$2
HOME="$ra_home" SSH_ORIGINAL_COMMAND="\$word" exec "$spool_binary" remote --grant "\$grant"
SCRIPT
chmod +x "$bin/fake-ssh-ra"
# A 0.0.3 spool does not know the word send, and refuses it as malformed.
cat > "$bin/fake-ssh-old" <<SCRIPT
#!/bin/sh
if [ "\$2" = send ]; then
  echo "spool: unknown remote command" >&2
  exit 2
fi
exec "$bin/fake-ssh-ra" "\$@"
SCRIPT
chmod +x "$bin/fake-ssh-old"
in_spool ra-remote init
ra_grant() {
  # ra_grant WORKER KEYCHAR [OPTIONS...]: print the grant's ID.
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA%s\n' "$2" \
    > "$work/ra-$1.pub"
  HOME="$ra_home" "$spool_binary" --dir "$work/ra-remote" grant --peer "$1" --worker "$1" \
    --key "$work/ra-$1.pub" "${@:3}" | jq -r '.grant_id'
}
ra_putter=$(ra_grant ra-putter AA --put)
ra_worker=$(ra_grant ra-worker AB --max-result-bytes 1000000)
ra_small=$(ra_grant ra-small AC --max-result-bytes 10)
jq -e '.max_result_bytes == 1000000' "$ra_home/.spool/grants/$ra_worker.json" >/dev/null; check
jq -e 'has("max_result_bytes") | not' "$ra_home/.spool/grants/$ra_putter.json" >/dev/null; check
ra_remote_put() {
  jq -nc --arg task "$1" --arg cap "$2" --argjson payload "$3" \
    '{task_id:$task,capability:$cap,payload:$payload}' | "$bin/fake-ssh-ra" "$ra_putter" put >/dev/null
}

# The whole chain through the forced command.
ra_remote_put rr-one stems@1 "$(jq -nc --arg keep "$work/ra-kept/remote" '{keep:$keep,bytes:200000}')"
"$spool_binary" work --via "$bin/fake-ssh-ra $ra_worker" --config "$work/ra-stems.json" --max-tasks 1
"$bin/fake-ssh-ra" "$ra_putter" results </dev/null > "$work/rr-results"
jq -s -e 'length == 1 and .[0].task_id == "rr-one" and .[0].worker == "ra-worker"
  and (.[0].attachments | length) == 2' "$work/rr-results" >/dev/null; check
rr_vocals=$(jq -r '.result.vocals' "$work/rr-results")
rr_drums=$(jq -r '.result.drums' "$work/rr-results")
for digest in "$rr_vocals" "$rr_drums"; do
  take_line rr-one "$digest" | "$bin/fake-ssh-ra" "$ra_putter" take > "$work/rr-taken"
  cmp "$work/rr-taken" "$work/ra-kept/remote/$digest"; check
done
# Taking goes with reading results: a grant that may not put may not take.
expect_exit 5 sh -c "printf '%s\n' '$(take_line rr-one "$rr_vocals")' | '$bin/fake-ssh-ra' '$ra_worker' take"
test ! -s "$work/exit.stdout"; check
collect_ids_remote() { printf '{"task_id":"%s"}\n' "$1" | "$bin/fake-ssh-ra" "$ra_putter" collect; }
collect_ids_remote rr-one | jq -e '.status == "collected"' >/dev/null; check
test "$(find "$work/ra-remote/result-attachments" -type f | wc -l | tr -d ' ')" = 0; check

# The limit counts what is staged and what is done and not collected, and
# collect frees it. The grant ra-small may hold 10 bytes. A file that what
# its own lease staged leaves no room for could never fit, and is 7; one that
# others hold the room for is 6, for now (ADR 0021).
printf '123456' > "$work/ra-six"
printf '12345' > "$work/ra-five"
printf '1234' > "$work/ra-four"
printf '1' > "$work/ra-one"
ra_remote_put rs-one leave@1 '{}'
rs_lease=$("$bin/fake-ssh-ra" "$ra_small" lease | jq -r '.lease_id')
remote_send() { { send_line "$2" "$3" "$4"; cat "$4"; } | "$bin/fake-ssh-ra" "$1" send; }
remote_send "$ra_small" rs-one "$rs_lease" "$work/ra-six" | jq -e '.status == "staged"' >/dev/null; check
expect_exit 7 remote_send "$ra_small" rs-one "$rs_lease" "$work/ra-five"
grep -q "max_result_bytes" "$work/exit.stderr"; check
test "$(staged_in ra-remote)" = 1; check
remote_send "$ra_small" rs-one "$rs_lease" "$work/ra-four" | jq -e '.status == "staged"' >/dev/null; check
rs_both=$(jq -nc --arg s "$(sha256_of "$work/ra-six")" --arg f "$(sha256_of "$work/ra-four")" \
  '[{sha256:$s,size:6},{sha256:$f,size:4}] | sort_by(.sha256)')
ra_ack_line rs-one "$rs_lease" "$rs_both" | "$bin/fake-ssh-ra" "$ra_small" ack | jq -e '.status == "acked"' >/dev/null; check
ra_remote_put rs-two leave@1 '{}'
rs_two_lease=$("$bin/fake-ssh-ra" "$ra_small" lease | jq -r '.lease_id')
expect_exit 6 remote_send "$ra_small" rs-two "$rs_two_lease" "$work/ra-one"
grep -q "max_result_bytes" "$work/exit.stderr"; check
collect_ids_remote rs-one | jq -e '.status == "collected"' >/dev/null; check
remote_send "$ra_small" rs-two "$rs_two_lease" "$work/ra-one" | jq -e '.status == "staged"' >/dev/null; check
# Another worker's lease is stale to it.
expect_exit 4 remote_send "$ra_worker" rs-two "$rs_two_lease" "$work/ra-one"
# Revoking the grant takes its staged files with its leases.
HOME="$ra_home" "$spool_binary" --dir "$work/ra-remote" revoke --grant "$ra_small" >/dev/null
test ! -e "$work/ra-remote/result-attachments/leases/$rs_two_lease"; check
test "$(staged_in ra-remote)" = 0; check
rs_two_lease=$(in_spool ra-remote lease --worker ra-local | jq -r '.lease_id')
ack_one ra-remote rs-two "$rs_two_lease" >/dev/null
# A grant with no limit, as every grant was before, may send nothing, ever.
ra_remote_put rs-three leave@1 '{}'
rs_three_lease=$("$bin/fake-ssh-ra" "$ra_putter" lease | jq -r '.lease_id')
expect_exit 7 remote_send "$ra_putter" rs-three "$rs_three_lease" "$work/ra-one"
test "$(staged_in ra-remote)" = 0; check
jq -nc --arg lease "$rs_three_lease" '{task_id:"rs-three",lease_id:$lease,result:{}}' \
  | "$bin/fake-ssh-ra" "$ra_putter" ack | jq -e '.status == "acked"' >/dev/null; check

# A worker whose grant could never hold a file fails the task for good, at
# once, without waiting, and says why (ADR 0021): here a file larger than
# the grant's limit, and a grant that holds 0, as every 0.0.3 grant does.
ra_tiny=$(ra_grant ra-tiny AD --max-result-bytes 2)
ra_never() {
  # ra_never TASK GRANT CONFIG MAKE
  ra_remote_put "$1" leave@1 "$(jq -nc --arg make "$4" '{make:$make}')"
  local started=${EPOCHREALTIME/./}
  "$spool_binary" work --via "$bin/fake-ssh-ra $2" --config "$3" --max-tasks 2 2> "$work/ra-never.stderr"
  check
  test $(( ${EPOCHREALTIME/./} - started )) -lt 5000000; check
  test "$(grep -c "waits for room" "$work/ra-never.stderr")" = 0; check
  in_spool ra-remote failures | jq -s -e --arg task "$1" 'map(select(.task_id == $task)) | length == 1
    and .[0].retried == false and (.[0].reason | contains("max_result_bytes"))' >/dev/null; check
  in_spool ra-remote results | jq -s -e --arg task "$1" 'map(select(.task_id == $task)) | length == 0' >/dev/null; check
  in_spool ra-remote status --json | jq -e '.pending == 0 and .leased == 0' >/dev/null; check
  test "$(staged_in ra-remote)" = 0; check
}
ra_never rt-big "$ra_tiny" "$work/ra-leave-three.json" "printf abc > outputs/$abc_digest"
ra_never rt-zero "$ra_putter" "$work/ra-leave-three.json" "printf abc > outputs/$abc_digest"
# The same for a file far larger than a pipe holds: the spool refuses it from
# its request line and reads none of it, and the worker, whose writes then
# fail, still learns why from the spool's status.
ra_config leave@1 "$bin/leave" 4000000 > "$work/ra-leave-large.json"
ra_large_make='head -c 3000000 /dev/urandom > big; if command -v sha256sum >/dev/null 2>&1; then d=$(sha256sum big | cut -d" " -f1); else d=$(shasum -a 256 big | cut -d" " -f1); fi; mv big "outputs/$d"'
ra_never rt-large "$ra_tiny" "$work/ra-leave-large.json" "$ra_large_make"

# A send refused for want of room now waits for it, keeping its lease and
# its outputs, and sends the same file again (ADR 0021). The grant ra-wait
# may hold 4 bytes; a done task not yet collected holds 3 of them.
ra_wait=$(ra_grant ra-wait AE --max-result-bytes 4)
for bytes in c d fg hi jkl mno pqrst; do printf '%s' "$bytes" > "$work/rw-$bytes"; done
rw_make() {
  # rw_make FILE...: a make that counts its runs and leaves these files.
  local make="echo ran >> '$work/rw-count-$1'" file
  for file in "$@"; do make="$make; cp '$work/rw-$file' outputs/$(sha256_of "$work/rw-$file")"; done
  jq -nc --arg make "$make" '{make:$make}'
}
rw_failures() { in_spool ra-remote failures | jq -s -c --arg task "$1" 'map(select(.task_id == $task))'; }
rw_results() { in_spool ra-remote results | jq -s -c --arg task "$1" 'map(select(.task_id == $task))'; }
rw_leased() { grep -l "\"task_id\":\"$1\"" "$work"/ra-remote/leased/*.json >/dev/null 2>&1; }
rw_waiting() { grep -q "waits for room" "$1"; }
patiently() {
  local i=0
  until "$@"; do
    i=$((i + 1))
    test "$i" -lt 200 || return 1
    sleep 0.1
  done
}
# Take a task out of the way: lease it on the host and fail it for good.
rw_drop() {
  local lease
  lease=$(in_spool ra-remote lease --worker ra-local | jq -r --arg task "$1" 'select(.task_id == $task) | .lease_id')
  test -n "$lease"
  fail_one ra-remote "$1" "$lease" --no-retry >/dev/null
}
ra_config leave@1 "$bin/leave" 10 1 20 > "$work/ra-leave-wait.json"
ra_config leave@1 "$bin/leave" 10 1 3 > "$work/ra-leave-wait-short.json"
ra_remote_put rw-first leave@1 "$(jq -nc --arg make "printf abc > outputs/$abc_digest" '{make:$make}')"
"$spool_binary" work --via "$bin/fake-ssh-ra $ra_wait" --config "$work/ra-leave-wait.json" --max-tasks 1
test "$(rw_results rw-first | jq 'length')" = 1; check

# It waits, renewing its lease, until the earlier result is collected, and
# then sends and acknowledges without running the program again.
ra_remote_put rw-second leave@1 "$(rw_make c d)"
timeout 60 "$spool_binary" work --via "$bin/fake-ssh-ra $ra_wait" --config "$work/ra-leave-wait.json" \
  --max-tasks 1 2> "$work/rw-second.stderr" &
rw_second_pid=$!
patiently rw_waiting "$work/rw-second.stderr"; check
test "$(staged_in ra-remote)" = 1; check
sleep 4
rw_leased rw-second; check
test "$(rw_failures rw-second)" = "[]"; check
# Leased more than 3 s ago, it has been renewed since, so reclaim leaves it.
test -z "$(in_spool ra-remote reclaim --older-than 3)"; check
rw_leased rw-second; check
collect_ids_remote rw-first | jq -e '.status == "collected"' >/dev/null; check
wait "$rw_second_pid"; check
rw_results rw-second | jq -e 'length == 1 and (.[0].attachments | length) == 2' >/dev/null; check
test "$(wc -l < "$work/rw-count-c" | tr -d ' ')" = 1; check
test "$(rw_failures rw-second)" = "[]"; check
test "$(grep -c "waits for room" "$work/rw-second.stderr")" = 1; check
test "$(grep -c "room for result attachment" "$work/rw-second.stderr")" = 1; check
test "$(staged_in ra-remote)" = 0; check

# Nobody collects: past the capability's timeout_seconds, 3 here, it fails
# the lease with retry and says how long it waited, and what it staged goes
# with the lease. rw-second's result holds 2 bytes.
ra_remote_put rw-third leave@1 "$(rw_make fg hi)"
rw_started=${EPOCHREALTIME/./}
timeout 60 "$spool_binary" work --via "$bin/fake-ssh-ra $ra_wait" --config "$work/ra-leave-wait-short.json" \
  --max-tasks 1 2> "$work/rw-third.stderr"
check
rw_took=$(( ${EPOCHREALTIME/./} - rw_started ))
test "$rw_took" -ge 3000000; check
test "$rw_took" -lt 15000000; check
rw_failures rw-third | jq -e 'length == 1 and .[0].retried == true
  and (.[0].reason | contains("waited 3 s for room under max_result_bytes"))' >/dev/null; check
test "$(wc -l < "$work/rw-count-fg" | tr -d ' ')" = 1; check
test "$(staged_in ra-remote)" = 0; check
rw_drop rw-third

# A lease reclaimed while it waits ends the wait: the worker neither sends
# nor acknowledges, and the reclaim's record is the task's only failure.
ra_remote_put rw-fourth leave@1 "$(rw_make jkl)"
timeout 60 "$spool_binary" work --via "$bin/fake-ssh-ra $ra_wait" --config "$work/ra-leave-wait.json" \
  --max-tasks 1 2> "$work/rw-fourth.stderr" &
rw_fourth_pid=$!
patiently rw_waiting "$work/rw-fourth.stderr"; check
in_spool ra-remote reclaim --older-than 0 | jq -e '.task_id == "rw-fourth"' >/dev/null; check
rw_started=${EPOCHREALTIME/./}
set +e
wait "$rw_fourth_pid"
rw_fourth_exit=$?
set -e
test "$rw_fourth_exit" -eq 4; check
test $(( ${EPOCHREALTIME/./} - rw_started )) -lt 10000000; check
test "$(rw_results rw-fourth)" = "[]"; check
rw_failures rw-fourth | jq -e 'length == 1 and (.[0].reason | startswith("reclaimed"))' >/dev/null; check
test "$(staged_in ra-remote)" = 0; check
rw_drop rw-fourth

# SIGTERM ends the wait: the worker exits 143, its working directory is
# gone, and the lease stands, for reclaim to return.
ra_remote_put rw-fifth leave@1 "$(rw_make mno)"
mkdir "$work/rw-tmp"
TMPDIR="$work/rw-tmp" "$spool_binary" work --via "$bin/fake-ssh-ra $ra_wait" \
  --config "$work/ra-leave-wait.json" --max-tasks 1 2> "$work/rw-fifth.stderr" &
rw_fifth_pid=$!
patiently rw_waiting "$work/rw-fifth.stderr"; check
test -n "$(ls -A "$work/rw-tmp")"; check
rw_started=${EPOCHREALTIME/./}
kill -TERM "$rw_fifth_pid"
set +e
wait "$rw_fifth_pid"
rw_fifth_exit=$?
set -e
test "$rw_fifth_exit" -eq 143; check
test $(( ${EPOCHREALTIME/./} - rw_started )) -lt 2000000; check
test -z "$(ls -A "$work/rw-tmp")"; check
rw_leased rw-fifth; check
test "$(rw_failures rw-fifth)" = "[]"; check
in_spool ra-remote reclaim --older-than 0 | jq -e '.task_id == "rw-fifth"' >/dev/null; check
rw_drop rw-fifth

# A file larger than the grant's whole limit is not waited for.
ra_never rw-sixth "$ra_wait" "$work/ra-leave-wait.json" "$(rw_make pqrst | jq -r '.make')"

# A spool that does not know send refuses it: the worker ends with that
# status and does not acknowledge the task, whose lease stands.
ra_remote_put rt-old stems@1 "$(jq -nc --arg keep "$work/ra-kept/old" '{keep:$keep,bytes:10}')"
expect_exit 2 "$spool_binary" work --via "$bin/fake-ssh-old $ra_worker" --config "$work/ra-stems.json" --max-tasks 1
in_spool ra-remote results | jq -s -e 'map(select(.task_id == "rt-old")) | length == 0' >/dev/null; check
in_spool ra-remote status --json | jq -e '.leased == 1' >/dev/null; check

# What a 0.0.3 binary wrote still loads: its result record, read and
# written back as it was, and its grants, which hold no limit and so may
# send nothing, and otherwise work as they did. The fixture is made by
# scripts/make-records-fixture.sh running the 0.0.3 binary; only the spool
# path in each grant is changed, to where it is unpacked.
mkdir "$work/old03"
tar -xf "$fixtures/spool-0.0.3-records.tar" -C "$work/old03"
for record in "$work"/old03/home/.spool/grants/*.json; do
  jq -e 'has("max_result_bytes") | not' "$record" >/dev/null; check
  jq -c --arg spool "$work/old03/spool" '.spool = $spool' "$record" > "$work/old03-grant.json"
  mv -f "$work/old03-grant.json" "$record"
done
old_result=$(find "$work/old03/spool/results" -name '*.json')
in_spool old03/spool results > "$work/old03-results"
cmp "$work/old03-results" <(cat "$old_result"; echo); check
old_grant_of() { grep -l "\"worker\":\"$1\"" "$work"/old03/home/.spool/grants/*.json | xargs basename | sed 's/\.json$//'; }
old_worker=$(old_grant_of old-worker)
old_putter=$(old_grant_of old-putter)
cat > "$bin/fake-ssh-03" <<SCRIPT
#!/bin/sh
HOME="$work/old03/home" SSH_ORIGINAL_COMMAND="\$2" exec "$spool_binary" remote --grant "\$1"
SCRIPT
chmod +x "$bin/fake-ssh-03"
diff <("$bin/fake-ssh-03" "$old_putter" results </dev/null) "$work/old03-results"; check
old_lease=$(basename "$(find "$work/old03/spool/leased" -name '*.json')" .json)
expect_exit 7 sh -c "{ printf '%s\n' '$(send_line old-leased "$old_lease" "$work/ra-abc")'; printf abc; } | '$bin/fake-ssh-03' '$old_worker' send"
jq -nc --arg lease "$old_lease" '{task_id:"old-leased",lease_id:$lease,result:{new:true}}' \
  | "$bin/fake-ssh-03" "$old_worker" ack | jq -e '.status == "acked"' >/dev/null; check
expect_exit 2 sh -c "printf '%s\n' '$(take_line old-done "$abc_digest")' | '$bin/fake-ssh-03' '$old_putter' take"

printf 'ok: standalone JSONL spool, opaque payloads, capability boundaries, idempotency, conflict, lease fencing, renew, fail/retry, durable results, attachments, grants, exact remote dispatch, configured executor lifecycle, resource/concurrency limits, following workers, attempts with retention, result attachments (%d checks)\n' "$checks"
