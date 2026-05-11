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

# Test 12.5: draft PR → wip (regardless of LGTM, CI, etc.)
TMP="$(mktemp)"
jq '. + {isDraft: true}' "$FIX/lgtm-current.json" > "$TMP"
assert_eq "draft PR → wip" "wip" "$(run_classify "$TMP")"
rm -f "$TMP"

TMP="$(mktemp)"
jq '. + {isDraft: true}' "$FIX/merge-ci-fail.json" > "$TMP"
assert_eq "draft PR with CI failing → wip (drafts win)" "wip" "$(run_classify "$TMP")"
rm -f "$TMP"

TMP="$(mktemp)"
jq '. + {isDraft: true}' "$FIX/merge-changes-requested.json" > "$TMP"
assert_eq "draft PR with CHANGES_REQUESTED → wip" "wip" "$(run_classify "$TMP")"
rm -f "$TMP"

# isDraft explicitly false → no change to existing behavior
TMP="$(mktemp)"
jq '. + {isDraft: false}' "$FIX/lgtm-current.json" > "$TMP"
assert_eq "non-draft PR → ready-to-merge (unchanged)" "ready-to-merge" "$(run_classify "$TMP")"
rm -f "$TMP"

# Test 13: empty PR (no comments, no reviews, all empty arrays) — CI is empty,
# so no FAIL, no PENDING → CI considered green → no LGTM → wait-review.
TMP="$(mktemp)"
echo '{"headRefOid":"x","comments":[],"reviews":[],"statusCheckRollup":[]}' > "$TMP"
assert_eq "empty PR → wait-review" \
  "wait-review" "$(run_classify "$TMP")"
rm -f "$TMP"

# Test 14: TIMED_OUT conclusion → address-ci-fail
TMP="$(mktemp)"
jq '.statusCheckRollup = [{"name":"e2e","state":"COMPLETED","conclusion":"TIMED_OUT"}]' \
  "$FIX/no-lgtm.json" > "$TMP"
assert_eq "TIMED_OUT → address-ci-fail" \
  "address-ci-fail" "$(run_classify "$TMP")"
rm -f "$TMP"

# Test 15: STARTUP_FAILURE → address-ci-fail
TMP="$(mktemp)"
jq '.statusCheckRollup = [{"name":"ci","state":"COMPLETED","conclusion":"STARTUP_FAILURE"}]' \
  "$FIX/no-lgtm.json" > "$TMP"
assert_eq "STARTUP_FAILURE → address-ci-fail" \
  "address-ci-fail" "$(run_classify "$TMP")"
rm -f "$TMP"

# Test 16: ACTION_REQUIRED → wait-ci (someone has to do something, not us)
TMP="$(mktemp)"
jq '.statusCheckRollup = [{"name":"approval","state":"COMPLETED","conclusion":"ACTION_REQUIRED"}]' \
  "$FIX/no-lgtm.json" > "$TMP"
assert_eq "ACTION_REQUIRED → wait-ci" \
  "wait-ci" "$(run_classify "$TMP")"
rm -f "$TMP"

# Test 17: SUCCESS + NEUTRAL + SKIPPED all count as green → reaches LGTM step
TMP="$(mktemp)"
jq '.statusCheckRollup = [
  {"name":"lint","state":"SUCCESS"},
  {"name":"types","state":"COMPLETED","conclusion":"NEUTRAL"},
  {"name":"docs","state":"COMPLETED","conclusion":"SKIPPED"}
]' "$FIX/no-lgtm.json" > "$TMP"
assert_eq "SUCCESS/NEUTRAL/SKIPPED → wait-review (no LGTM)" \
  "wait-review" "$(run_classify "$TMP")"
rm -f "$TMP"

# Test 18: multi-reviewer — one CHANGES_REQUESTED, one COMMENTED → address-changes
TMP="$(mktemp)"
jq '. + {
  reviews: [
    {"author":{"login":"alice"},"state":"CHANGES_REQUESTED","submittedAt":"2026-05-01T10:00:00Z"},
    {"author":{"login":"bob"},"state":"COMMENTED","submittedAt":"2026-05-01T11:00:00Z"}
  ]
}' "$FIX/no-lgtm.json" > "$TMP"
assert_eq "multi-reviewer: alice CHANGES_REQUESTED → address-changes" \
  "address-changes" "$(run_classify "$TMP")"
rm -f "$TMP"

# Test 19: multi-reviewer — one CHANGES_REQUESTED (superseded by their /lgtm),
# one with no review → not address-changes; CI green + no current LGTM →
# wait-review.
TMP="$(mktemp)"
jq '. + {
  reviews: [
    {"author":{"login":"alice"},"state":"CHANGES_REQUESTED","submittedAt":"2026-05-01T10:00:00Z"}
  ],
  comments: [
    {"author":{"login":"alice"},"createdAt":"2026-05-01T11:00:00Z","body":"/lgtm\n\n<!-- coding-flows:lgtm sha=other reviewer=alice acs= invariants= risks-reviewed= -->\nresolved"}
  ]
}' "$FIX/no-lgtm.json" > "$TMP"
# alice's /lgtm at SHA "other" supersedes her CHANGES_REQUESTED, but its
# sha doesn't match head → check_lgtm returns 2 → wait-lgtm-fresh.
assert_eq "multi-reviewer: superseded CR + stale /lgtm → wait-lgtm-fresh" \
  "wait-lgtm-fresh" "$(run_classify "$TMP")"
rm -f "$TMP"

# Test 20: mergeable=CONFLICTING + CI green + valid LGTM → merge-conflict
# (overrides ready-to-merge — the merge would fail without a rebase).
TMP="$(mktemp)"
jq '. + {mergeable:"CONFLICTING"}' "$FIX/lgtm-current.json" > "$TMP"
assert_eq "mergeable=CONFLICTING + CI green + LGTM → merge-conflict" \
  "merge-conflict" "$(run_classify "$TMP")"
rm -f "$TMP"

# Test 21: mergeable=CONFLICTING but CI failing → address-ci-fail wins
# (CI fixes are usually a code change, which would rebase out the
# conflict at the same time — the failure to surface first is fine).
TMP="$(mktemp)"
jq '. + {
  mergeable:"CONFLICTING",
  statusCheckRollup:[{"name":"lint","state":"COMPLETED","conclusion":"FAILURE"}]
}' "$FIX/lgtm-current.json" > "$TMP"
assert_eq "mergeable=CONFLICTING + CI failing → address-ci-fail (ci wins)" \
  "address-ci-fail" "$(run_classify "$TMP")"
rm -f "$TMP"

# Test 22: mergeable=UNKNOWN → proceeds to LGTM-based state
# (no false-positive merge-conflict on eventual-consistency lag).
TMP="$(mktemp)"
jq '. + {mergeable:"UNKNOWN"}' "$FIX/lgtm-current.json" > "$TMP"
assert_eq "mergeable=UNKNOWN + CI green + LGTM → ready-to-merge" \
  "ready-to-merge" "$(run_classify "$TMP")"
rm -f "$TMP"

# Test 23: mergeable missing entirely → defaults to UNKNOWN (no field) → proceeds
TMP="$(mktemp)"
jq 'del(.mergeable)' "$FIX/lgtm-current.json" > "$TMP"
assert_eq "mergeable absent → ready-to-merge (unchanged)" \
  "ready-to-merge" "$(run_classify "$TMP")"
rm -f "$TMP"

# Test 24: mergeable=CONFLICTING but no LGTM → still merge-conflict
# (conflicts block more than LGTM does, so report the bigger problem).
TMP="$(mktemp)"
jq '. + {mergeable:"CONFLICTING"}' "$FIX/no-lgtm.json" > "$TMP"
assert_eq "mergeable=CONFLICTING + no LGTM → merge-conflict" \
  "merge-conflict" "$(run_classify "$TMP")"
rm -f "$TMP"

test_summary
