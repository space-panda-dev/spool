#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: real-machine-gate.sh \
  --a-admin USER@HOST --a-worker USER@HOST \
  --b-admin USER@HOST --c-admin USER@HOST \
  --a-spool-bin ABSOLUTE_PATH --a-spool-dir ABSOLUTE_PATH \
  --b-key ABSOLUTE_PATH_ON_B --c-key ABSOLUTE_PATH_ON_C \
  --b-work-dir ABSOLUTE_PATH --c-work-dir ABSOLUTE_PATH \
  [--evidence-dir LOCAL_DIRECTORY]

The grants for B and C must already bind their keys to distinct worker names.
EOF
  exit 2
}

a_admin= a_worker= b_admin= c_admin= a_bin= a_dir=
b_key= c_key= b_dir= c_dir= evidence=
while (($#)); do
  case $1 in
    --a-admin) a_admin=${2-}; shift 2 ;;
    --a-worker) a_worker=${2-}; shift 2 ;;
    --b-admin) b_admin=${2-}; shift 2 ;;
    --c-admin) c_admin=${2-}; shift 2 ;;
    --a-spool-bin) a_bin=${2-}; shift 2 ;;
    --a-spool-dir) a_dir=${2-}; shift 2 ;;
    --b-key) b_key=${2-}; shift 2 ;;
    --c-key) c_key=${2-}; shift 2 ;;
    --b-work-dir) b_dir=${2-}; shift 2 ;;
    --c-work-dir) c_dir=${2-}; shift 2 ;;
    --evidence-dir) evidence=${2-}; shift 2 ;;
    *) usage ;;
  esac
done

for value in "$a_admin" "$a_worker" "$b_admin" "$c_admin" "$a_bin" \
  "$a_dir" "$b_key" "$c_key" "$b_dir" "$c_dir"; do
  [[ -n $value ]] || usage
done
for target in "$a_admin" "$a_worker" "$b_admin" "$c_admin"; do
  [[ $target =~ ^[A-Za-z0-9._@:-]+$ ]] || {
    echo "unsafe SSH target: $target" >&2; exit 2;
  }
done
for path in "$a_bin" "$a_dir" "$b_key" "$c_key" "$b_dir" "$c_dir"; do
  [[ $path =~ ^/[A-Za-z0-9._/-]+$ && $path != *..* ]] || {
    echo "paths must be absolute, traversal-free shell tokens: $path" >&2; exit 2;
  }
done

for command in ssh scp jq cmp wc awk date mktemp; do
  command -v "$command" >/dev/null || { echo "missing command: $command" >&2; exit 2; }
done
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
  echo "missing SHA-256 command: sha256sum or shasum" >&2
  exit 2
fi

control_ssh() { ssh -o BatchMode=yes "$@"; }
control_scp() { scp -o BatchMode=yes "$@"; }
require_remote_tools() {
  control_ssh "$1" \
    'set -eu; command -v awk >/dev/null; command -v wc >/dev/null; command -v mkdir >/dev/null; command -v rm >/dev/null; command -v rmdir >/dev/null; command -v cat >/dev/null; if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then exit 127; fi'
}

for target in "$a_admin" "$b_admin" "$c_admin"; do
  require_remote_tools "$target" || {
    echo "missing required remote tool on $target" >&2
    exit 2
  }
done
control_ssh "$b_admin" 'set -eu; command -v sleep >/dev/null; command -v kill >/dev/null' || {
  echo "missing worker-process tool on $b_admin" >&2
  exit 2
}

run_id="gate_$(date -u +%Y%m%dT%H%M%SZ)_$$"
task_one="${run_id}_one"
task_two="${run_id}_two"
a_stage="/tmp/spool-real-machine-${run_id}"
evidence=${evidence:-"$PWD/gate-evidence-$run_id"}
mkdir -p "$evidence"
local_tmp=$(mktemp -d)
trap 'rm -rf "$local_tmp"' EXIT

printf 'spool real-machine attachment %s\n' "$run_id" > "$local_tmp/body"
if command -v sha256sum >/dev/null 2>&1; then
  digest=$(sha256sum "$local_tmp/body" | awk '{print $1}')
else
  digest=$(shasum -a 256 "$local_tmp/body" | awk '{print $1}')
fi
size=$(wc -c < "$local_tmp/body" | tr -d ' ')

a_spool() { control_ssh "$a_admin" "$a_bin --dir $a_dir $*"; }
worker_b() { control_ssh "$b_admin" "ssh -i $b_key -o BatchMode=yes $a_worker $1"; }
worker_c() { control_ssh "$c_admin" "ssh -i $c_key -o BatchMode=yes $a_worker $1"; }
verify_remote_file() {
  control_ssh "$1" "set -eu; actual=\$(if command -v sha256sum >/dev/null 2>&1; then sha256sum $2 | awk '{print \$1}'; else shasum -a 256 $2 | awk '{print \$1}'; fi); test \"\$actual\" = $digest; test \$(wc -c < $2) -eq $size"
}

control_ssh "$a_admin" "mkdir -m 700 $a_stage"
control_scp -q "$local_tmp/body" "$a_admin:$a_stage/$digest"
a_spool init

task_json() {
  jq -nc --arg task "$1" --arg digest "$digest" --argjson size "$size" \
    '{task_id:$task,capability:"real-machine@1",payload:{gate:true},attachments:[{sha256:$digest,size:$size}]}'
}

# B completes one task, including a renewal between fetch and acknowledgement.
task_json "$task_one" | a_spool "put --attachments $a_stage" > "$evidence/put-one.jsonl"
worker_b lease > "$evidence/b-lease-one.jsonl"
b_lease_one=$(jq -r --arg task "$task_one" 'select(.task_id == $task).lease_id' "$evidence/b-lease-one.jsonl")
[[ -n $b_lease_one && $b_lease_one != null ]] || { echo "B did not lease task one" >&2; exit 1; }
fetch_one=$(jq -nc --arg task "$task_one" --arg lease "$b_lease_one" --arg digest "$digest" \
  '{task_id:$task,lease_id:$lease,sha256:$digest}')
control_ssh "$b_admin" "mkdir -m 700 $b_dir"
printf '%s\n' "$fetch_one" | control_ssh "$b_admin" \
  "ssh -i $b_key -o BatchMode=yes $a_worker fetch > $b_dir/$digest"
verify_remote_file "$b_admin" "$b_dir/$digest"
renew_one=$(jq -nc --arg task "$task_one" --arg lease "$b_lease_one" \
  '{task_id:$task,lease_id:$lease}')
printf '%s\n' "$renew_one" | worker_b renew > "$evidence/b-renew-one.jsonl"
ack_one=$(jq -nc --arg task "$task_one" --arg lease "$b_lease_one" \
  --arg digest "$digest" --argjson size "$size" \
  '{task_id:$task,lease_id:$lease,result:{host:"B",sha256:$digest,size:$size}}')
printf '%s\n' "$ack_one" | worker_b ack > "$evidence/b-ack-one.jsonl"
a_spool results > "$evidence/results-after-b.jsonl"
jq -e --arg task "$task_one" --arg digest "$digest" \
  'select(.task_id == $task and .result.host == "B" and .result.sha256 == $digest)' \
  "$evidence/results-after-b.jsonl" >/dev/null
control_ssh "$a_admin" "test ! -e $a_dir/attachments/task-$task_one"

# B is killed while holding the second lease. A explicitly reclaims it; C
# completes it; B's fenced late acknowledgement must be exit 4.
task_json "$task_two" | a_spool "put --attachments $a_stage" > "$evidence/put-two.jsonl"
worker_b lease > "$evidence/b-lease-two.jsonl"
b_lease_two=$(jq -r --arg task "$task_two" 'select(.task_id == $task).lease_id' "$evidence/b-lease-two.jsonl")
[[ -n $b_lease_two && $b_lease_two != null ]] || { echo "B did not lease task two" >&2; exit 1; }
fetch_two=$(jq -nc --arg task "$task_two" --arg lease "$b_lease_two" --arg digest "$digest" \
  '{task_id:$task,lease_id:$lease,sha256:$digest}')
printf '%s\n' "$fetch_two" | control_ssh "$b_admin" \
  "ssh -i $b_key -o BatchMode=yes $a_worker fetch > $b_dir/$digest"
control_ssh "$b_admin" "sh -c 'echo \$\$ > $b_dir/running.pid; exec sleep 300'" &
b_session=$!
for _ in {1..50}; do
  control_ssh "$b_admin" "test -s $b_dir/running.pid" >/dev/null 2>&1 && break
  sleep 0.1
done
control_ssh "$b_admin" "kill -9 \$(cat $b_dir/running.pid)"
set +e
wait "$b_session"
set -e
a_spool "reclaim --older-than 0" > "$evidence/reclaim.jsonl"
worker_c lease > "$evidence/c-lease.jsonl"
c_lease=$(jq -r --arg task "$task_two" 'select(.task_id == $task).lease_id' "$evidence/c-lease.jsonl")
[[ -n $c_lease && $c_lease != null && $c_lease != "$b_lease_two" ]] || {
  echo "C did not receive a fresh lease" >&2; exit 1;
}
fetch_c=$(jq -nc --arg task "$task_two" --arg lease "$c_lease" --arg digest "$digest" \
  '{task_id:$task,lease_id:$lease,sha256:$digest}')
control_ssh "$c_admin" "mkdir -m 700 $c_dir"
printf '%s\n' "$fetch_c" | control_ssh "$c_admin" \
  "ssh -i $c_key -o BatchMode=yes $a_worker fetch > $c_dir/$digest"
verify_remote_file "$c_admin" "$c_dir/$digest"
ack_c=$(jq -nc --arg task "$task_two" --arg lease "$c_lease" \
  --arg digest "$digest" --argjson size "$size" \
  '{task_id:$task,lease_id:$lease,result:{host:"C",sha256:$digest,size:$size}}')
printf '%s\n' "$ack_c" | worker_c ack > "$evidence/c-ack.jsonl"
late_b=$(jq -nc --arg task "$task_two" --arg lease "$b_lease_two" \
  '{task_id:$task,lease_id:$lease,result:{host:"B",late:true}}')
set +e
printf '%s\n' "$late_b" | worker_b ack > "$evidence/b-late.stdout" 2> "$evidence/b-late.stderr"
late_status=$?
set -e
[[ $late_status -eq 4 ]] || { echo "B late ack exited $late_status, expected 4" >&2; exit 1; }
a_spool results > "$evidence/results-final.jsonl"
jq -e --arg task "$task_two" \
  'select(.task_id == $task and .result.host == "C" and (.result.late // false) == false)' \
  "$evidence/results-final.jsonl" >/dev/null
control_ssh "$a_admin" "test ! -e $a_dir/attachments/task-$task_two"

control_ssh "$a_admin" "rm $a_stage/$digest && rmdir $a_stage"
control_ssh "$b_admin" "rm -f $b_dir/$digest $b_dir/running.pid && rmdir $b_dir"
control_ssh "$c_admin" "rm $c_dir/$digest && rmdir $c_dir"
printf 'PASS %s evidence=%s\n' "$run_id" "$evidence"
