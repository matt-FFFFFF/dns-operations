#!/usr/bin/env bash
#
# Tests for tools/changed-zones.sh.
#
# Builds a throwaway git repository, because every rule in that script is about
# what a commit range contains and none of it can be exercised without real
# history. Run with `make test-changed-zones`.

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
script="$repo_root/tools/changed-zones.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pass=0
fail=0

check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3" >&2
  fi
}

check_fails() { # check_fails <name> <command...>
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then
    fail=$((fail + 1))
    printf 'FAIL %s\n  expected a non-zero exit, got success\n' "$name" >&2
  else
    pass=$((pass + 1))
  fi
}

# --- a repository shaped like this one ------------------------------------

cd "$work"
git init -q .
git config user.email t@example.com
git config user.name t
mkdir -p tools terraform policy zones/a.example/apex zones/b.example/apex
cp "$script" tools/changed-zones.sh
for z in a.example b.example; do
  printf 'zone: %s\n' "$z" > "zones/$z/zone.yaml"
  printf 'a:\n  "@": [192.0.2.1]\n' > "zones/$z/apex/website.yaml"
done
printf 'x\n' > terraform/main.tf
printf 'x\n' > README.md
git add -A && git commit -qm base
base=$(git rev-parse HEAD)

run() { ./tools/changed-zones.sh "$@" 2>/dev/null; }

# --- one zone --------------------------------------------------------------

printf 'a:\n  "@": [192.0.2.2]\n' > zones/a.example/apex/website.yaml
git commit -qam "one zone"
check "a change to one zone plans that zone" '["a.example"]' "$(run --base "$base")"

# A single zone must be a one-element array. A bare string would make
# fromJSON hand the matrix a scalar, which errors at expansion time.
check "one zone is an array, not a scalar" "[" "$(run --base "$base" | cut -c1)"

# --- shared paths ----------------------------------------------------------

printf 'y\n' > terraform/main.tf
git commit -qam "shared path"
check "a shared path plans every zone" \
  '["a.example","b.example"]' "$(run --base "$(git rev-parse HEAD~1)")"

check "a shared path plus one zone still plans every zone" \
  '["a.example","b.example"]' "$(run --base "$base")"

# --- nothing relevant ------------------------------------------------------

after_shared=$(git rev-parse HEAD)
printf 'y\n' > README.md
git commit -qam "docs only"
check "a change touching no zone plans nothing" '[]' "$(run --base "$after_shared")"

# --- a deleted zone --------------------------------------------------------

git rm -qr zones/b.example
git commit -qam "remove a zone"
check_fails "removing a zone is refused" ./tools/changed-zones.sh --base "$after_shared"

# ...and is still refused when a shared path changes in the same commit, which
# would otherwise take the "every zone" shortcut before ever looking.
git revert --no-edit HEAD >/dev/null
before_both=$(git rev-parse HEAD)
git rm -qr zones/b.example
printf 'z\n' > terraform/main.tf
git commit -qam "remove a zone and touch a shared path"
check_fails "removing a zone is refused even alongside a shared path" \
  ./tools/changed-zones.sh --base "$before_both"
git revert --no-edit HEAD >/dev/null

# --- unusable bases fall back to everything --------------------------------

every='["a.example","b.example"]'
check "an all-zeros base plans every zone" \
  "$every" "$(run --base 0000000000000000000000000000000000000000)"
check "a base that is not in the clone plans every zone" \
  "$every" "$(run --base deadbeefdeadbeefdeadbeefdeadbeefdeadbeef)"
check "an empty base plans every zone" "$every" "$(run --base '')"

# A force push leaves a base that exists but is no longer an ancestor. The
# three-dot diff would still produce an answer -- the wrong one.
orphan=$(git commit-tree "$(git rev-parse "HEAD^{tree}")" -m orphan </dev/null)
check "a base that is not an ancestor plans every zone" "$every" "$(run --base "$orphan")"

# --- the other modes -------------------------------------------------------

check "--all lists every zone" "$every" "$(run --all)"
check "--zone all lists every zone" "$every" "$(run --zone all)"
check "--zone names one zone" '["a.example"]' "$(run --zone a.example)"
check_fails "--zone rejects a name that does not exist" \
  ./tools/changed-zones.sh --zone nope.example
check_fails "no mode is an error" ./tools/changed-zones.sh

# --- the GitHub outputs ----------------------------------------------------

GITHUB_OUTPUT="$work/out.txt" run --zone a.example >/dev/null
check "zones= is written for the matrix" 'zones=["a.example"]' "$(sed -n 1p "$work/out.txt")"
check "any= is written for the guard" 'any=true' "$(sed -n 2p "$work/out.txt")"

: > "$work/out.txt"
GITHUB_OUTPUT="$work/out.txt" run --base "$after_shared" >/dev/null
check "any= is false when no zone changed" 'any=false' "$(sed -n 2p "$work/out.txt")"
check "zones= is an empty array when no zone changed" 'zones=[]' "$(sed -n 1p "$work/out.txt")"

# ---------------------------------------------------------------------------

printf 'changed-zones: %d/%d\n' "$pass" "$((pass + fail))"
[ "$fail" -eq 0 ]
