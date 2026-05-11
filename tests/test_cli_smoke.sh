#!/usr/bin/env bash
# Smoke tests for each scripts/coding-flows-* CLI wrapper. The lib functions are
# covered thoroughly elsewhere; here we just confirm each wrapper:
#   - accepts --from-file
#   - propagates the lib's exit code
#   - emits expected KEY=VALUE lines
set -uo pipefail

TEST_FILE="test_cli_smoke.sh"
TEST_PASS=0
TEST_FAIL=0

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$THIS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$THIS_DIR/lib/assert.sh"

SCRIPTS="$SKILL_DIR/scripts"
FIX="$THIS_DIR/fixtures/pr-views"
FILES="$THIS_DIR/fixtures/pr-files"
CFG="$THIS_DIR/fixtures/configs/default.json"

# Run all CLIs from a tmpdir where .coding-flows.json is the default fixture, so
# repo_state_dir, read_config, detect-scope, etc. all see a config.
TMPDIR_TEST="$(mktemp -d)"
cp "$CFG" "$TMPDIR_TEST/.coding-flows.json"
cd "$TMPDIR_TEST"
trap 'cd /; rm -rf "$TMPDIR_TEST"' EXIT

# --- coding-flows-check-lgtm --------------------------------------------------
out="$("$SCRIPTS/coding-flows-check-lgtm" --from-file "$FIX/lgtm-current.json" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "check-lgtm current: exit 0" 0 "$rc"
assert_contains  "check-lgtm current: COUNT line" "LGTM_COUNT=1" "$out"
assert_contains  "check-lgtm current: ACS line"   "LGTM_ACS=AC-1" "$out"

"$SCRIPTS/coding-flows-check-lgtm" --from-file "$FIX/no-lgtm.json" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "check-lgtm none: exit 1" 1 "$rc"

"$SCRIPTS/coding-flows-check-lgtm" --from-file "$FIX/lgtm-stale.json" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "check-lgtm stale: exit 2" 2 "$rc"

# --- coding-flows-verify-ac-mapping ------------------------------------------
out="$("$SCRIPTS/coding-flows-verify-ac-mapping" --from-file "$FIX/coverage-complete.json" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "verify-ac-mapping ok: exit 0" 0 "$rc"
assert_contains  "verify-ac-mapping ok: rows" "AC_ROWS=2" "$out"

# --- coding-flows-verify-lgtm-coverage ---------------------------------------
"$SCRIPTS/coding-flows-verify-lgtm-coverage" --from-file "$FIX/coverage-complete.json" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "verify-lgtm-coverage complete: exit 0" 0 "$rc"

"$SCRIPTS/coding-flows-verify-lgtm-coverage" --from-file "$FIX/coverage-missing-ac.json" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "verify-lgtm-coverage missing: exit 1" 1 "$rc"

"$SCRIPTS/coding-flows-verify-lgtm-coverage" --from-file "$FIX/no-lgtm.json" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "verify-lgtm-coverage no-lgtm: exit 2" 2 "$rc"

# --- coding-flows-detect-scope -----------------------------------------------
out="$("$SCRIPTS/coding-flows-detect-scope" --from-file "$FILES/backend-only.txt" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "detect-scope backend: exit 0" 0 "$rc"
assert_contains  "detect-scope backend: backend-coding-standards" \
                 "backend-coding-standards" "$out"

out="$("$SCRIPTS/coding-flows-detect-scope" --from-file "$FILES/docs-only.txt" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "detect-scope docs: exit 0" 0 "$rc"
assert_eq        "detect-scope docs: empty"   "" "$out"

# --- coding-flows-label-risk -------------------------------------------------
# In --dry-run mode, the CLI prints the labels that WOULD be applied.
out="$("$SCRIPTS/coding-flows-label-risk" --from-file "$FIX/lgtm-dual.json" --dry-run 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "label-risk lgtm-dual: exit 0" 0 "$rc"
# lgtm-dual.json has docs/auth-flow.md — under the default config that
# doesn't match any high-risk rule, so empty.
assert_eq        "label-risk lgtm-dual: empty" "" "$out"

# Patch a fixture to actually touch auth/ so a high-risk label fires.
TMP="$(mktemp)"
jq '.files = [{path: "backend/auth/middleware.go", additions: 5, deletions: 1}]' \
  "$FIX/lgtm-dual.json" > "$TMP"
out="$("$SCRIPTS/coding-flows-label-risk" --from-file "$TMP" --dry-run 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "label-risk auth-touched: exit 0" 0 "$rc"
assert_contains  "label-risk auth-touched: high-risk:auth" "high-risk:auth" "$out"
rm -f "$TMP"

# --- coding-flows-fetch-for-reviewer ----------------------------------------
out="$("$SCRIPTS/coding-flows-fetch-for-reviewer" --from-file "$FIX/lgtm-dual.json" --reviewer r1 2>/dev/null)"
rc=$?
assert_exit_code "fetch-for-reviewer r1: exit 0" 0 "$rc"
assert_contains  "fetch-for-reviewer r1: keeps r1" "reviewer=r1" "$out"
assert_not_contains "fetch-for-reviewer r1: drops r2" "reviewer=r2" "$out"

"$SCRIPTS/coding-flows-fetch-for-reviewer" --from-file "$FIX/lgtm-dual.json" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "fetch-for-reviewer missing --reviewer: exit 64" 64 "$rc"

test_summary
