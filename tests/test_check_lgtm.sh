#!/usr/bin/env bash
# Tests for scripts/lib/check-lgtm.sh.
set -uo pipefail

TEST_FILE="test_check_lgtm.sh"
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

FIX="$THIS_DIR/fixtures/pr-views"

# Test 1: no LGTM → exit 1
out="$(check_lgtm "$(cat "$FIX/no-lgtm.json")" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "no-lgtm: exit code" 1 "$rc"
assert_contains  "no-lgtm: COUNT=0" "LGTM_COUNT=0" "$out"
assert_contains  "no-lgtm: STALE=no" "STALE=no" "$out"

# Test 2: LGTM bound to current head → exit 0
out="$(check_lgtm "$(cat "$FIX/lgtm-current.json")" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "current: exit code" 0 "$rc"
assert_contains  "current: COUNT=1" "LGTM_COUNT=1" "$out"
assert_contains  "current: reviewer r1" "LGTM_REVIEWERS=r1" "$out"
assert_contains  "current: SHA matches" "LGTM_SHA=head0001sha" "$out"
assert_contains  "current: acs claim" "LGTM_ACS=AC-1" "$out"
assert_contains  "current: STALE=no" "STALE=no" "$out"

# Test 3: LGTM bound to old SHA → exit 2
out="$(check_lgtm "$(cat "$FIX/lgtm-stale.json")" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "stale: exit code" 2 "$rc"
assert_contains  "stale: COUNT=0" "LGTM_COUNT=0" "$out"
assert_contains  "stale: STALE=yes" "STALE=yes" "$out"
assert_contains  "stale: SHA reflects last seen" "LGTM_SHA=oldhead0001" "$out"

# Test 4: dual reviewers both bound to head → exit 0, count=2
out="$(check_lgtm "$(cat "$FIX/lgtm-dual.json")" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "dual: exit code" 0 "$rc"
assert_contains  "dual: COUNT=2" "LGTM_COUNT=2" "$out"
assert_contains  "dual: reviewer union r1" "r1" "$out"
assert_contains  "dual: reviewer union r2" "r2" "$out"
# acs union across the two markers
assert_contains  "dual: acs union" "LGTM_ACS=AC-1,AC-2" "$out"

# Test 5: /lgtm without marker → ignored, exit 1
out="$(check_lgtm "$(cat "$FIX/lgtm-no-marker.json")" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "no-marker: exit code" 1 "$rc"
assert_contains  "no-marker: COUNT=0" "LGTM_COUNT=0" "$out"

# Test 6: malformed headRefOid → exit 64
bad_json='{"comments": []}'
out="$(check_lgtm "$bad_json" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "no-head: exit 64" 64 "$rc"

# Test 7: marker missing acs= field → ignored
malformed='{"headRefOid":"h","comments":[{"createdAt":"2025-01-01T00:00:00Z","body":"/lgtm\n\n<!-- coding-flows:lgtm sha=h reviewer=r1 invariants= -->\nfine"}]}'
out="$(check_lgtm "$malformed" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "missing-acs: exit 1 (ignored)" 1 "$rc"

# Test 8: marker missing invariants= field → ignored
malformed='{"headRefOid":"h","comments":[{"createdAt":"2025-01-01T00:00:00Z","body":"/lgtm\n\n<!-- coding-flows:lgtm sha=h reviewer=r1 acs=AC-1 -->\nfine"}]}'
out="$(check_lgtm "$malformed" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "missing-invariants: exit 1 (ignored)" 1 "$rc"

# Test 9: empty acs / invariants accepted as long as keys present
malformed='{"headRefOid":"h2","comments":[{"createdAt":"2025-01-01T00:00:00Z","body":"/lgtm\n\n<!-- coding-flows:lgtm sha=h2 reviewer=r1 acs= invariants= -->\nfine"}]}'
out="$(check_lgtm "$malformed" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "empty-values: exit 0" 0 "$rc"
assert_contains  "empty-values: COUNT=1" "LGTM_COUNT=1" "$out"

test_summary
