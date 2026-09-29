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
test "$($spool_binary --version)" = "spool 0.0.1"; check

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
spool status | grep -q 'failed=2'; check
spool status --json | jq -e '.failed == 2' >/dev/null; check

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

# A fail interrupted after its record was written leaves the lease standing
# beside that record. The state is rebuilt from the real writer's own files:
# the lease is set aside, failed for real, then put back. Finishing it with
# the same reason and retry choice completes the transition; a different
# reason or choice is refused and cannot pass for having been recorded.
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
other_fail=$(jq -nc --arg lease "$interrupted_lease" \
  '{task_id:"interrupted-fail",lease_id:$lease,reason:"other reason"}')
test "$first_fail" != "$other_fail"; check
printf '%s\n' "$first_fail" | spoolf fail | jq -e '.status == "failed_retry"' >/dev/null; check
cp "$work/interrupted-saved/$interrupted_lease.json" \
  "$work/interrupted-saved/$interrupted_lease.worker" "$work/interrupted-fail/leased/"
rm "$work/interrupted-fail/pending/interrupted-fail.json"
spoolf status --json | jq -e '.pending == 0 and .leased == 1 and .failed == 1' >/dev/null; check
set +e
printf '%s\n' "$other_fail" | spoolf fail >/dev/null 2>&1
other_reason_exit=$?
printf '%s\n' "$first_fail" | spoolf fail --no-retry >/dev/null 2>&1
other_choice_exit=$?
set -e
test "$other_reason_exit" -eq 4; check
test "$other_choice_exit" -eq 4; check
spoolf status --json | jq -e '.pending == 0 and .leased == 1 and .failed == 1' >/dev/null; check
printf '%s\n' "$first_fail" | spoolf fail | jq -e '.status == "failed_retry"' >/dev/null; check
spoolf status --json | jq -e '.pending == 1 and .leased == 0 and .failed == 1' >/dev/null; check
spoolf failures | jq -s --arg lease "$interrupted_lease" -e \
  'length == 1 and .[0].lease_id == $lease and .[0].reason == "first reason"
   and .[0].retried == true' >/dev/null; check

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
  'keys == ["expires_at","grant_id","peer","public_key","spool","worker"]
   and (.grant_id | test("^grant_[0-9a-f]{32}$"))
   and .peer == "peer-one" and .worker == "granted-worker"
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

# Every lease a remote request names is checked before any line is applied.
# One line for another worker's lease refuses the whole request, and the
# grant's own lease, named first in the same request, is left as it was.
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
printf '%s\n%s\n' "$own_batch_ack" "$foreign_batch_ack" \
  | remote_primary 'ack' > "$work/remote-batch.out" 2>/dev/null
remote_batch_exit=$?
set -e
test "$remote_batch_exit" -eq 4; check
test ! -s "$work/remote-batch.out"; check
spoolg results | jq -s -e \
  'map(select(.task_id == "remote-batch" or .task_id == "other-worker")) | length == 0' \
  >/dev/null; check
test -f "$work/grant-spool/leased/$remote_batch_lease.json"; check
printf '%s\n' "$own_batch_ack" | remote_primary 'ack' \
  | jq -e '.status == "acked"' >/dev/null; check

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
remote_reject 'put'
remote_reject 'results'
remote_reject 'failures'
remote_reject 'status'
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

# A worker name survives the lease record whole. "Ł" (U+0141) and "A"
# (U+0041) share their low byte, so a record that kept one byte per character
# would hand the lease of one to the other. The wide name is set in the grant
# record because JSON is UTF-8 whatever the locale; an argument is not.
narrow_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAC'
wide_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD'
printf '%s\n' "$narrow_key" > "$work/narrow.pub"
printf '%s\n' "$wide_key" > "$work/wide.pub"
spoolg grant --peer narrow-peer --worker A --key "$work/narrow.pub" \
  > "$work/narrow-grant.json"
spoolg grant --peer wide-peer --worker wide-placeholder --key "$work/wide.pub" \
  > "$work/wide-grant.json"
narrow_grant_id=$(jq -r '.grant_id' "$work/narrow-grant.json")
wide_grant_id=$(jq -r '.grant_id' "$work/wide-grant.json")
jq -c '.worker = "Ł"' "$grant_home/.spool/grants/$wide_grant_id.json" \
  > "$work/wide-grant-record.json"
mv "$work/wide-grant-record.json" "$grant_home/.spool/grants/$wide_grant_id.json"
remote_as() {
  local grant=$1 requested=$2
  HOME="$grant_home" SSH_ORIGINAL_COMMAND="$requested" \
    "$spool_binary" remote --grant "$grant"
}
printf '%s\n' '{"task_id":"wide-worker","capability":"remote@1","payload":{}}' \
  | spoolg put >/dev/null
remote_as "$wide_grant_id" 'lease' > "$work/wide-lease.jsonl"
jq -e '.task_id == "wide-worker" and .worker == "Ł" and .worker != "A"' \
  "$work/wide-lease.jsonl" >/dev/null; check
wide_lease=$(jq -r '.lease_id' "$work/wide-lease.jsonl")
wide_ref=$(jq -nc --arg lease "$wide_lease" '{task_id:"wide-worker",lease_id:$lease}')
wide_ack=$(jq -nc --arg lease "$wide_lease" \
  '{task_id:"wide-worker",lease_id:$lease,result:{wide:true}}')
set +e
printf '%s\n' "$wide_ref" | remote_as "$narrow_grant_id" 'renew' >/dev/null 2>&1
narrow_renew_exit=$?
printf '%s\n' "$wide_ack" | remote_as "$narrow_grant_id" 'ack' >/dev/null 2>&1
narrow_ack_exit=$?
set -e
test "$narrow_renew_exit" -eq 4; check
test "$narrow_ack_exit" -eq 4; check
printf '%s\n' "$wide_ref" | remote_as "$wide_grant_id" 'renew' \
  | jq -e '.status == "renewed"' >/dev/null; check
printf '%s\n' "$wide_ack" | remote_as "$wide_grant_id" 'ack' \
  | jq -e '.status == "acked"' >/dev/null; check
spoolg results | jq -s -e \
  'map(select(.task_id == "wide-worker")) | length == 1 and .[0].worker == "Ł"' \
  >/dev/null; check
# The completed lease stays fenced: a repeat of the same ack is a no-op for
# its owner and still refused for the other worker.
printf '%s\n' "$wide_ack" | remote_as "$wide_grant_id" 'ack' \
  | jq -e '.status == "already_done"' >/dev/null; check
set +e
printf '%s\n' "$wide_ack" | remote_as "$narrow_grant_id" 'ack' >/dev/null 2>&1
narrow_repeat_exit=$?
set -e
test "$narrow_repeat_exit" -eq 4; check

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

# Revoke disables access, removes only its managed line, and reclaims leases
# for the fixed worker. The old lease remains fenced after return to pending.
printf '%s\n' '{"task_id":"remote-revoke","capability":"remote@1","payload":{}}' \
  | spoolg put >/dev/null
remote_primary 'lease' > "$work/revoke-lease.jsonl"
revoke_lease=$(jq -r '.lease_id' "$work/revoke-lease.jsonl")
HOME="$grant_home" "$spool_binary" --dir "$work/grant-spool" revoke --grant "$grant_id" \
  | jq -e --arg grant "$grant_id" '.grant_id == $grant and .status == "revoked"' >/dev/null; check
test ! -e "$grant_home/.spool/grants/$grant_id.json"; check
! grep -F "spool-grant:$grant_id" "$grant_home/.ssh/authorized_keys" >/dev/null; check
test "$(head -n 1 "$grant_home/.ssh/authorized_keys")" = '# unrelated key material'; check
spoolg status --json | jq -e '.pending >= 1' >/dev/null; check
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

printf 'ok: standalone JSONL spool, opaque payloads, capability boundaries, idempotency, conflict, lease fencing, renew, fail/retry, durable results, attachments, grants, exact remote dispatch, configured executor lifecycle, resource/concurrency limits (%d checks)\n' "$checks"
