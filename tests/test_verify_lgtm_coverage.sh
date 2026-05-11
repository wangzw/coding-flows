#!/usr/bin/env bash
# Tests for scripts/lib/verify-lgtm-coverage.sh.
set -uo pipefail

TEST_FILE="test_verify_lgtm_coverage.sh"
TEST_PASS=0
TEST_FAIL=0

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$THIS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$THIS_DIR/lib/assert.sh"
# shellcheck source=../scripts/lib/common.sh
source "$SKILL_DIR/scripts/lib/common.sh"
# shellcheck source=../scripts/lib/check-lgtm.sh
source "$SKILL_DIR/scripts/lib/check-lgtm.sh"
# shellcheck source=../scripts/lib/verify-ac-mapping.sh
source "$SKILL_DIR/scripts/lib/verify-ac-mapping.sh"
# shellcheck source=../scripts/lib/verify-lgtm-coverage.sh
source "$SKILL_DIR/scripts/lib/verify-lgtm-coverage.sh"

FIX="$THIS_DIR/fixtures/pr-views"
CFG="$THIS_DIR/fixtures/configs/default.json"

# Force per-test config by pointing find_repo_config at our fixture via a
# temp directory. find_repo_config walks up from cwd, so we mkdir a temp
# dir, drop .coding-flows.json there, cd into it.
TMPDIR_TEST="$(mktemp -d)"
cp "$CFG" "$TMPDIR_TEST/.coding-flows.json"
cd "$TMPDIR_TEST"
trap 'cd /; rm -rf "$TMPDIR_TEST"' EXIT

# Test 1: coverage complete → exit 0
out="$(verify_lgtm_coverage "$(cat "$FIX/coverage-complete.json")" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "complete: exit 0" 0 "$rc"
assert_contains  "complete: no missing acs" "COVERAGE_MISSING_ACS=" "$out"
assert_contains  "complete: no missing invariants" "COVERAGE_MISSING_INVARIANTS=" "$out"

# Test 2: coverage missing an AC → exit 1, lists AC-3
out="$(verify_lgtm_coverage "$(cat "$FIX/coverage-missing-ac.json")" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "missing-ac: exit 1" 1 "$rc"
assert_contains  "missing-ac: names AC-3" "COVERAGE_MISSING_ACS=AC-3" "$out"

# Test 3: coverage missing an invariant → exit 1
# The fixture touches backend/internal/eventstore/ + messaging/ but LGTM
# doesn't claim events-before-publish. The default config also has
# no-secrets-in-logs triggered by **/*.go — that's also missing here.
out="$(verify_lgtm_coverage "$(cat "$FIX/coverage-missing-invariant.json")" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "missing-invariant: exit 1" 1 "$rc"
assert_contains  "missing-invariant: names events-before-publish" \
                 "events-before-publish" "$out"

# Test 4: no current LGTM → exit 2 (prerequisite)
out="$(verify_lgtm_coverage "$(cat "$FIX/no-lgtm.json")" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "no-lgtm: exit 2" 2 "$rc"

# Test 5: stale LGTM → exit 2
out="$(verify_lgtm_coverage "$(cat "$FIX/lgtm-stale.json")" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "stale: exit 2" 2 "$rc"

# Test 6: dual reviewers union covers (high-risk PR) → exit 0
# lgtm-dual.json touches auth/, but auth isn't in default config invariants,
# so only acs need to be covered. r1 claims AC-1, r2 claims AC-2 — together
# they cover AC-1+AC-2 which matches the AC mapping.
out="$(verify_lgtm_coverage "$(cat "$FIX/lgtm-dual.json")" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "dual-union: exit 0" 0 "$rc"

test_summary
