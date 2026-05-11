#!/usr/bin/env bash
# Tests for scripts/lib/common.sh helpers.
set -uo pipefail

TEST_FILE="test_common.sh"
TEST_PASS=0
TEST_FAIL=0

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$THIS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$THIS_DIR/lib/assert.sh"
# shellcheck source=../scripts/lib/common.sh
source "$SKILL_DIR/scripts/lib/common.sh"

# trim
assert_eq "trim spaces" "abc" "$(trim "  abc  ")"
assert_eq "trim tabs"   "abc" "$(trim $'\tabc\t')"
assert_eq "trim empty"  ""    "$(trim "   ")"

# is_placeholder
is_placeholder ""        && rc=0 || rc=$?; assert_exit_code "placeholder: empty" 0 "$rc"
is_placeholder "-"       && rc=0 || rc=$?; assert_exit_code "placeholder: dash"  0 "$rc"
is_placeholder "TBD"     && rc=0 || rc=$?; assert_exit_code "placeholder: TBD"   0 "$rc"
is_placeholder "<x>"     && rc=0 || rc=$?; assert_exit_code "placeholder: <x>"   0 "$rc"
is_placeholder "real"    && rc=0 || rc=$?; assert_exit_code "placeholder: real (not)" 1 "$rc"

# glob_match
glob_match "*.go" "foo.go"           && rc=0 || rc=$?; assert_exit_code "glob: *.go matches foo.go" 0 "$rc"
glob_match "*.go" "foo/bar.go"       && rc=0 || rc=$?; assert_exit_code "glob: *.go does NOT match path/foo.go" 1 "$rc"
glob_match "**/*.go" "foo/bar.go"    && rc=0 || rc=$?; assert_exit_code "glob: **/*.go matches path" 0 "$rc"
glob_match "**/*.go" "bar.go"        && rc=0 || rc=$?; assert_exit_code "glob: **/*.go matches root" 0 "$rc"
glob_match "backend/**" "backend/internal/x.go" && rc=0 || rc=$?
assert_exit_code "glob: backend/** matches deep" 0 "$rc"
glob_match "backend/**" "frontend/x.go" && rc=0 || rc=$?
assert_exit_code "glob: backend/** does not match frontend" 1 "$rc"
glob_match "docker-compose*.yml" "docker-compose.staging.yml" && rc=0 || rc=$?
assert_exit_code "glob: docker-compose*.yml matches staging" 0 "$rc"

# repo_state_dir with override
TMPCACHE="$(mktemp -d)"
CODING_FLOWS_CACHE_DIR="$TMPCACHE" CODING_FLOWS_REPO_NWO="acme/widget" \
  got="$(repo_state_dir 42)"
expected="$TMPCACHE/acme/widget/pr-42"
assert_eq "repo_state_dir: with PR" "$expected" "$got"

CODING_FLOWS_CACHE_DIR="$TMPCACHE" CODING_FLOWS_REPO_NWO="acme/widget" \
  got="$(repo_state_dir)"
expected="$TMPCACHE/acme/widget"
assert_eq "repo_state_dir: without PR" "$expected" "$got"
rm -rf "$TMPCACHE"

# find_repo_config
TMPREPO="$(mktemp -d)"
mkdir -p "$TMPREPO/sub/dir"
echo '{"acting_user":"test"}' > "$TMPREPO/.coding-flows.json"
got="$(cd "$TMPREPO/sub/dir" && find_repo_config)"
assert_eq "find_repo_config: walks up" "$TMPREPO/.coding-flows.json" "$got"
got="$(cd /tmp && find_repo_config 2>/dev/null || true)"
# /tmp generally won't contain a .coding-flows.json so output empty
[[ -z "$got" ]] && rc=0 || rc=1
assert_exit_code "find_repo_config: not found returns empty" 0 "$rc"
rm -rf "$TMPREPO"

# read_config with default
TMPREPO="$(mktemp -d)"
echo '{"merge":{"method":"rebase"}}' > "$TMPREPO/.coding-flows.json"
cd "$TMPREPO"
assert_eq "read_config: key present" "rebase" "$(read_config '.merge.method' 'squash')"
assert_eq "read_config: key missing → default" "squash" "$(read_config '.merge.unknown' 'squash')"
assert_eq "read_config: nested missing → default" "fallback" "$(read_config '.x.y.z' 'fallback')"
cd /
rm -rf "$TMPREPO"

# triggered_invariants
CFG="$THIS_DIR/fixtures/configs/default.json"
got="$(triggered_invariants "$(cat "$THIS_DIR/fixtures/pr-files/eventstore.txt")" "$CFG")"
# eventstore.txt has .go files → no-secrets-in-logs triggers (via **/*.go).
# It's also in eventstore/ + messaging/ → events-before-publish triggers.
assert_contains "triggered: events-before-publish" "events-before-publish" "$got"
assert_contains "triggered: no-secrets-in-logs"    "no-secrets-in-logs"    "$got"

got="$(triggered_invariants "$(cat "$THIS_DIR/fixtures/pr-files/docs-only.txt")" "$CFG")"
assert_eq       "triggered: docs only → none" "" "$got"

test_summary
