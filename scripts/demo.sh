#!/usr/bin/env bash
# The protocol's happy path, and its two kinds of failure, as a transcript:
# put two tasks, lease and acknowledge one, fail the other with retry and
# then for good, read what came of both, and collect them.
#
#   scripts/demo.sh                 builds spool from this tree with cabal
#   SPOOL=/abs/path scripts/demo.sh runs that binary instead
#
# `wf prove demo --golden` compares the transcript with test/golden/demo.txt.
# What changes from run to run (lease identifiers, times, the commit) is
# printed as <lease>, <time> and <commit>, so the transcript changes only
# when what Spool answers does.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
if [[ -z ${SPOOL:-} ]]; then
  (cd "$here" && cabal build -v0 -f werror --enable-tests exe:spool)
  SPOOL=$(cd "$here" && cabal list-bin -v0 -f werror --enable-tests spool)
fi
[[ $SPOOL == /* && -x $SPOOL ]] || { echo "demo.sh: SPOOL must be an absolute path to a spool binary" >&2; exit 2; }

work=$(mktemp -d "${WF_TMP:-${TMPDIR:-/tmp}}/spool-demo.XXXXXX")
trap 'rm -rf "$work"' EXIT

# Elide what differs between runs; lines that are not JSON pass unchanged.
steady='walk(if type == "object" then with_entries(
  if .key == "lease_id" then .value = "<lease>"
  elif (.key | test("_at$")) then .value = "<time>"
  else . end) else . end)'
steady() {
  local line
  while IFS= read -r line; do
    jq -c "$steady" <<<"$line" 2>/dev/null || printf '%s\n' "$line"
  done
}
# spool ARGS...: show the command, run it on the demo spool, show its answer
# (stdout and stderr together) and any exit status but 0.
spool() {
  local status=0
  printf '\n$ spool %s\n' "$*"
  "$SPOOL" --dir "$work/spool" "$@" > "$work/out" 2>&1 < "$work/in" || status=$?
  steady < "$work/out"
  if [[ $status -ne 0 ]]; then printf '[exit %d]\n' "$status"; fi
  : > "$work/in"
}
# input LINE...: what the next command reads on stdin.
input() { printf '%s\n' "$@" > "$work/in"; }
lease_of() { jq -r '.lease_id' "$work/out"; }

: > "$work/in"
printf '$ spool --version\n%s <commit>\n' "$("$SPOOL" --version | cut -d' ' -f1,2)"

spool init
input '{"task_id":"greet-ada","capability":"greet@1","payload":{"name":"Ada"}}' \
      '{"task_id":"word-count","capability":"count@1","payload":{"words":"one two three"}}'
spool put
spool status

spool lease --worker demo
greet_lease=$(lease_of)
input "{\"task_id\":\"greet-ada\",\"lease_id\":\"$greet_lease\",\"result\":{\"greeting\":\"Hello, Ada\"}}"
spool ack

spool lease --worker demo
count_lease=$(lease_of)
input "{\"task_id\":\"word-count\",\"lease_id\":\"$count_lease\",\"reason\":\"the counter is busy\"}"
spool fail
spool status

spool lease --worker demo
count_lease=$(lease_of)
input "{\"task_id\":\"word-count\",\"lease_id\":\"$count_lease\",\"reason\":\"words are not countable\"}"
spool fail --no-retry
# A lease that has ended is fenced: its holder can no longer act on it.
input "{\"task_id\":\"word-count\",\"lease_id\":\"$count_lease\",\"result\":{}}"
spool ack
spool lease --worker demo

spool results
spool failures
input '{"task_id":"greet-ada"}' '{"task_id":"word-count"}'
spool collect
spool status --json
