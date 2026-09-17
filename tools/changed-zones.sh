#!/usr/bin/env bash
#
# Which zones does this change affect?
#
# Prints a compact JSON array on stdout, and when $GITHUB_OUTPUT is set also
# writes `zones=` and `any=` for a matrix job to fan out over.
#
#   changed-zones.sh --all                    every zone with a zone.yaml
#   changed-zones.sh --base <sha>             zones affected since <sha>
#   changed-zones.sh --zone matt-ffffff.com   validate and echo one zone
#   changed-zones.sh --zone all               same as --all
#
# Every failure mode here looks like "nothing to do" to the workflow that reads
# it, so this script treats silence as a bug: it exits non-zero rather than
# printing an empty array for anything except a change that genuinely touches
# no zone.

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# Paths that can move records in a zone whose own YAML nobody touched: the two
# implementations of the layout, the policy, and the workflows that run them.
# A change to any of these fans out to every zone.
shared_paths='^(terraform/|policy/|tools/|Makefile$|\.github/workflows/)'

mode=""
base=""
head="HEAD"
one_zone=""

die() { printf 'changed-zones: %s\n' "$*" >&2; exit 1; }
note() { printf 'changed-zones: %s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --all)  mode=all; shift ;;
    --base) mode=base; base=${2-}; shift 2 ;;
    --head) head=${2-}; shift 2 ;;
    --zone) mode=zone; one_zone=${2-}; shift 2 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$mode" ] || die "give one of --all, --base <sha> or --zone <name>"

all_zones() {
  find "$repo_root/zones" -mindepth 2 -maxdepth 2 -name zone.yaml -print 2>/dev/null \
    | while read -r f; do basename "$(dirname "$f")"; done | LC_ALL=C sort
}

# One computation for both outputs: `any` is "the array is not empty". Setting
# them independently is how a matrix ends up expanding an empty list, which is
# a hard workflow error rather than a quiet no-op.
emit() {
  local json any
  json=$(printf '%s\n' "$@" | python3 -c \
    'import json,sys; print(json.dumps([l for l in sys.stdin.read().splitlines() if l], separators=(",",":")))')
  if [ "$json" = "[]" ]; then any=false; else any=true; fi

  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'zones=%s\n' "$json" >> "$GITHUB_OUTPUT"
    printf 'any=%s\n' "$any" >> "$GITHUB_OUTPUT"
  fi
  printf '%s\n' "$json"
  exit 0
}

case "$mode" in
  all)
    # shellcheck disable=SC2046  # word splitting on zone names is the point
    emit $(all_zones)
    ;;
  zone)
    [ -n "$one_zone" ] || die "--zone needs a name"
    if [ "$one_zone" = all ]; then
      # shellcheck disable=SC2046
      emit $(all_zones)
    fi
    [ -f "$repo_root/zones/$one_zone/zone.yaml" ] \
      || die "no such zone: $one_zone (zones/$one_zone/zone.yaml does not exist)"
    emit "$one_zone"
    ;;
esac

# --- base mode ------------------------------------------------------------

cd "$repo_root"

# A base that cannot be diffed against means fanning out to everything. A run
# that plans too much is recoverable; one that silently plans nothing is not.
usable_base() {
  local b=$1
  [ -n "$b" ] || { note "no base given"; return 1; }
  case "$b" in *[!0]*) ;; *) note "base is all zeros (new branch or first push)"; return 1 ;; esac
  git cat-file -e "${b}^{commit}" 2>/dev/null || { note "base $b is not in this clone"; return 1; }
  # A force push leaves a base that exists but is no longer an ancestor. The
  # three-dot diff would still "work", against some unrelated common ancestor.
  git merge-base --is-ancestor "$b" "$head" 2>/dev/null \
    || { note "base $b is not an ancestor of $head (history was rewritten)"; return 1; }
}

if ! usable_base "$base"; then
  note "falling back to every zone"
  # shellcheck disable=SC2046
  emit $(all_zones)
fi

changed=$(git diff --name-only "$base...$head")

# Checked before anything else, so that deleting a zone cannot be hidden by
# also touching a shared path. Terraform state for a removed zone is orphaned
# and every record it owns is stranded live in Cloudflare, so this is a
# deliberate manual operation and never something a merge does on its own.
deleted=$(printf '%s\n' "$changed" \
  | sed -n 's|^zones/\([^/]*\)/zone\.yaml$|\1|p' \
  | while read -r z; do [ -f "zones/$z/zone.yaml" ] || printf '%s\n' "$z"; done)
if [ -n "$deleted" ]; then
  die "zone.yaml was removed for: $(printf '%s' "$deleted" | tr '\n' ' ')
  Removing a zone strands its records in Cloudflare and orphans its state file.
  See docs/ci.md -- it is a manual operation, not a merge."
fi

if printf '%s\n' "$changed" | grep -qE "$shared_paths"; then
  note "a shared path changed; every zone is in scope"
  # shellcheck disable=SC2046
  emit $(all_zones)
fi

# shellcheck disable=SC2046
emit $(printf '%s\n' "$changed" \
  | sed -n 's|^zones/\([^/]*\)/.*|\1|p' \
  | LC_ALL=C sort -u \
  | while read -r z; do [ -f "zones/$z/zone.yaml" ] && printf '%s\n' "$z"; done)
