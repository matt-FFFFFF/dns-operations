#!/usr/bin/env bash
#
# Tests for tools/supersede-waiting.sh.
#
# The decision is "may this earlier waiting run be cancelled", and getting it
# wrong drops a merged change silently, so it is exercised against fixtures
# rather than only against the live API. --input supplies the runs the API
# would have returned; --dry-run stops at the verdict.

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
script="$root/tools/supersede-waiting.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pass=0; fail=0

# run <name> <zones-json> <runs-json> <expected substring>
run() {
  printf '%s' "$3" > "$work/in.json"
  local out
  out=$("$script" --zones "$2" --run-id 100 --repo o/r --dry-run --input "$work/in.json" 2>&1 || true)
  if printf '%s' "$out" | grep -qF "$4"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  expected to contain: %s\n  got: %s\n' "$1" "$4" "$out" >&2
  fi
}

# never <name> <zones-json> <runs-json> <forbidden substring>
never() {
  printf '%s' "$3" > "$work/in.json"
  local out
  out=$("$script" --zones "$2" --run-id 100 --repo o/r --dry-run --input "$work/in.json" 2>&1 || true)
  if printf '%s' "$out" | grep -qF "$4"; then
    fail=$((fail + 1))
    printf 'FAIL %s\n  must NOT contain: %s\n  got: %s\n' "$1" "$4" "$out" >&2
  else
    pass=$((pass + 1))
  fi
}

A='[{"id":99,"jobs":[{"name":"apply (a.com)","status":"waiting"}]}]'
AB='[{"id":99,"jobs":[{"name":"apply (a.com)","status":"waiting"},{"name":"apply (b.com)","status":"waiting"}]}]'
RUNNING='[{"id":99,"jobs":[{"name":"apply (a.com)","status":"in_progress"}]}]'
DONE='[{"id":99,"jobs":[{"name":"apply (a.com)","status":"completed"}]}]'
NOZONE='[{"id":99,"jobs":[{"name":"discover","status":"waiting"}]}]'
PARTLY='[{"id":99,"jobs":[{"name":"apply (a.com)","status":"completed"},{"name":"apply (b.com)","status":"waiting"}]}]'

run   "same single zone is superseded"        '["a.com"]'          "$A"       'cancelling run 99'
run   "superset covers both zones"            '["a.com","b.com"]'  "$AB"      'cancelling run 99'
run   "a zone we do not cover is left alone"  '["a.com"]'          "$AB"      'also waits on b.com'
never "...and is not cancelled"               '["a.com"]'          "$AB"      'cancelling run 99'
run   "a run already applying is left alone"  '["a.com"]'          "$RUNNING" 'already applying'
never "...and is not cancelled"               '["a.com"]'          "$RUNNING" 'cancelling run 99'
run   "a finished run has nothing pending"    '["a.com"]'          "$DONE"    'names no zone'
never "...and is not cancelled"               '["a.com"]'          "$DONE"    'cancelling run 99'
run   "a waiting run naming no zone is left"  '["a.com"]'          "$NOZONE"  'names no zone'
run   "only still-pending zones count"        '["b.com"]'          "$PARTLY"  'cancelling run 99'
run   "nothing waiting is not an error"       '["a.com"]'          '[]'       'nothing waiting'

# The current run must never cancel itself, whatever it looks like.
SELF='[{"id":100,"jobs":[{"name":"apply (a.com)","status":"waiting"}]}]'
never "the current run is never cancelled"    '["a.com"]'          "$SELF"    'cancelling run 100'

printf 'supersede-waiting: %d/%d\n' "$pass" "$((pass + fail))"
[ "$fail" -eq 0 ]
