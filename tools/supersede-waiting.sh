#!/usr/bin/env bash
#
# Cancel an earlier run that is still sitting at the environment approval gate,
# when this run covers every zone it is still waiting on.
#
# Why this exists: apply jobs take `concurrency: dns-<zone>` with
# cancel-in-progress false, so a run awaiting approval holds that group and
# every later apply for the zone queues behind it -- reporting that it is
# "waiting on apply (<zone>)", which reads like the job waiting on itself. The
# earlier run is also planning an older commit, so approving it applies the
# wrong thing and cancelling it is almost always right.
#
# Why not `cancel-in-progress: true`: that cannot tell "waiting for approval,
# nothing written" from "halfway through writing records to Cloudflare". This
# only ever cancels runs in the `waiting` state.
#
# Why zone-aware: the API cancels whole runs, but a run is a matrix over zones.
# Cancelling a run that is waiting on a zone this run does not cover would drop
# that zone's apply silently -- and because changed-zones.sh diffs against the
# previous commit, it would never come back into scope. A merged change would
# simply never reach DNS. So a run is only cancelled when every zone it is
# still waiting on is a zone this run will apply.
#
#   supersede-waiting.sh --zones '["a.com","b.com"]' --run-id 123 [--repo o/r]
#                        [--dry-run] [--input FILE]
#
# --input reads the candidate runs from a JSON file instead of the API, which
# is what the tests use.

set -euo pipefail

zones=""
run_id=""
repo="${GITHUB_REPOSITORY:-}"
dry_run=false
input=""

die() { printf 'supersede: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --zones)   zones=${2-}; shift 2 ;;
    --run-id)  run_id=${2-}; shift 2 ;;
    --repo)    repo=${2-}; shift 2 ;;
    --input)   input=${2-}; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$zones" ]  || die "--zones is required (a JSON array)"
[ -n "$run_id" ] || die "--run-id is required"

# Candidate runs: everything still waiting at a gate, with its jobs. Only the
# two workflows that take a dns-<zone> concurrency group can be holding one.
if [ -n "$input" ]; then
  candidates=$(cat "$input")
else
  [ -n "$repo" ] || die "--repo is required (or set GITHUB_REPOSITORY)"
  ids=$(gh api "repos/$repo/actions/runs?status=waiting&per_page=100" \
          --jq '.workflow_runs[] | select(.name == "apply" or .name == "reconcile") | .id')
  candidates="[]"
  for id in $ids; do
    [ "$id" = "$run_id" ] && continue
    jobs=$(gh api "repos/$repo/actions/runs/$id/jobs?per_page=100" \
             --jq '[.jobs[] | {name: .name, status: .status}]')
    candidates=$(printf '%s' "$candidates" | python3 -c "
import json,sys
c = json.load(sys.stdin)
c.append({'id': $id, 'jobs': json.loads('''$jobs''')})
print(json.dumps(c))
")
  done
fi

decisions=$(printf '%s' "$candidates" | python3 -c "
import json, re, sys

mine = set(json.loads('''$zones'''))
me   = int('$run_id')
runs = json.load(sys.stdin)

# 'apply (matt-ffffff.com)' -> matt-ffffff.com
zone_of = re.compile(r'^\\S+\\s+\\((.+)\\)\$')

for run in runs:
    rid = int(run['id'])
    if rid == me:
        continue

    jobs = run.get('jobs', [])
    # Anything actually executing means work may already have reached
    # Cloudflare. Never cancel that, whatever it covers.
    if any(j.get('status') == 'in_progress' for j in jobs):
        print(f'skip {rid} running -')
        continue

    pending = set()
    for j in jobs:
        if j.get('status') in ('queued', 'waiting', 'pending'):
            m = zone_of.match(j.get('name', ''))
            if m:
                pending.add(m.group(1))

    # No identifiable pending zone means we cannot reason about it. Leave it.
    if not pending:
        print(f'skip {rid} unknown -')
        continue

    uncovered = pending - mine
    if uncovered:
        print(f'skip {rid} uncovered ' + ','.join(sorted(uncovered)))
    else:
        print(f'cancel {rid} covered ' + ','.join(sorted(pending)))
")

[ -n "$decisions" ] || { echo "supersede: nothing waiting"; exit 0; }

while read -r verdict rid reason detail; do
  [ -n "$verdict" ] || continue
  case "$verdict:$reason" in
    cancel:covered)
      echo "supersede: cancelling run $rid, which waits only on $detail"
      if [ "$dry_run" = false ]; then
        gh api --method POST "repos/$repo/actions/runs/$rid/cancel" --silent 2>/dev/null \
          || echo "::warning::could not cancel run $rid"
      fi
      ;;
    skip:running)
      echo "::warning::run $rid is already applying; left alone" ;;
    skip:unknown)
      echo "::warning::run $rid is waiting but names no zone; left alone" ;;
    skip:uncovered)
      echo "::warning::run $rid also waits on $detail, which this run does not cover -- left alone, approve or cancel it by hand" ;;
  esac
done <<< "$decisions"
