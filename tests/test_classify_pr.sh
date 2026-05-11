#!/usr/bin/env bash
# Tests for scripts/lib/classify-pr.sh.
set -uo pipefail

TEST_FILE="test_classify_pr.sh"
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
# shellcheck source=../scripts/lib/classify-pr.sh
source "$SKILL_DIR/scripts/lib/classify-pr.sh"

FIX="$THIS_DIR/fixtures/pr-views"

run_classify() {
  classify_pr "$(cat "$1")" 2>/dev/null | grep -oE 'PR_STATE=[a-z-]+' | cut -d= -f2
}

# Test 1: current LGTM + CI green → ready-to-merge
assert_eq "current LGTM + CI green → ready-to-merge" \
  "ready-to-merge" "$(run_classify "$FIX/lgtm-current.json")"

# Test 2: stale LGTM (older SHA) → wait-lgtm-fresh
assert_eq "stale LGTM → wait-lgtm-fresh" \
  "wait-lgtm-fresh" "$(run_classify "$FIX/lgtm-stale.json")"

# Test 3: no LGTM + CI green → wait-review
assert_eq "no LGTM, CI green → wait-review" \
  "wait-review" "$(run_classify "$FIX/no-lgtm.json")"

# Test 4: /lgtm without marker is invalid → no LGTM → wait-review
assert_eq "/lgtm no marker → wait-review" \
  "wait-review" "$(run_classify "$FIX/lgtm-no-marker.json")"

# Test 5: CI failure → address-ci-fail (overrides LGTM state)
assert_eq "CI failure → address-ci-fail" \
  "address-ci-fail" "$(run_classify "$FIX/merge-ci-fail.json")"

# Test 6: unsuperseded CHANGES_REQUESTED → address-changes
assert_eq "unsuperseded CHANGES_REQUESTED → address-changes" \
  "address-changes" "$(run_classify "$FIX/merge-changes-requested.json")"

# Test 7: CHANGES_REQUESTED superseded by later /lgtm → not address-changes;
# should fall through to ready-to-merge (CI green + current LGTM).
assert_eq "CHANGES_REQUESTED superseded → ready-to-merge" \
  "ready-to-merge" "$(run_classify "$FIX/merge-changes-superseded.json")"

# Test 8: dual LGTM both at head → ready-to-merge
assert_eq "dual LGTM at head → ready-to-merge" \
  "ready-to-merge" "$(run_classify "$FIX/lgtm-dual.json")"

# Test 9: CI in-progress
TMP="$(mktemp)"
jq '.statusCheckRollup = [{"name":"ci","state":"IN_PROGRESS"}]' "$FIX/no-lgtm.json" > "$TMP"
assert_eq "CI in-progress → wait-ci" \
  "wait-ci" "$(run_classify "$TMP")"
rm -f "$TMP"

# Test 10: CI queued
TMP="$(mktemp)"
jq '.statusCheckRollup = [{"name":"ci","state":"QUEUED"}]' "$FIX/no-lgtm.json" > "$TMP"
assert_eq "CI queued → wait-ci" \
  "wait-ci" "$(run_classify "$TMP")"
rm -f "$TMP"

# Test 11: CHANGES_REQUESTED takes priority over CI failure
TMP="$(mktemp)"
jq '.statusCheckRollup = [{"name":"unit","state":"COMPLETED","conclusion":"FAILURE"}]' \
  "$FIX/merge-changes-requested.json" > "$TMP"
assert_eq "CHANGES_REQUESTED priority > CI fail" \
  "address-changes" "$(run_classify "$TMP")"
rm -f "$TMP"

# Test 12: malformed input → exit 64
classify_pr "not json" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "malformed JSON → exit 64" 64 "$rc"

# Test 13: empty PR (no comments, no reviews, all empty arrays) — CI is empty,
# so no FAIL, no PENDING → CI considered green → no LGTM → wait-review.
TMP="$(mktemp)"
echo '{"headRefOid":"x","comments":[],"reviews":[],"statusCheckRollup":[]}' > "$TMP"
assert_eq "empty PR → wait-review" \
  "wait-review" "$(run_classify "$TMP")"
rm -f "$TMP"

test_summary
