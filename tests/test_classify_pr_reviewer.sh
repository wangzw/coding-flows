#!/usr/bin/env bash
# Tests for scripts/coding-flows-classify-pr-reviewer. Runs the actual
# CLI against pr-view fixtures + a tmpdir with default.json, so the
# inner `coding-flows-merge --dry-run` call can resolve config.
set -uo pipefail

TEST_FILE="test_classify_pr_reviewer.sh"
TEST_PASS=0
TEST_FAIL=0

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$THIS_DIR/.." && pwd)"

source "$THIS_DIR/lib/assert.sh"

CLI="$SKILL_DIR/scripts/coding-flows-classify-pr-reviewer"
FIX="$THIS_DIR/fixtures/pr-views"
CFG="$THIS_DIR/fixtures/configs/default.json"

# All tests run in a tmpdir with .coding-flows.json so the inner merge
# --dry-run can find config.
TMPDIR_TEST="$(mktemp -d)"
cp "$CFG" "$TMPDIR_TEST/.coding-flows.json"
cd "$TMPDIR_TEST"
trap 'cd /; rm -rf "$TMPDIR_TEST"' EXIT

state_of() {
  "$CLI" --from-file "$1" 2>/dev/null | grep -E '^PR_REVIEWER_STATE=' | head -n1 | cut -d= -f2
}
reason_of() {
  "$CLI" --from-file "$1" 2>/dev/null | grep -E '^REASON=' | head -n1 | cut -d= -f2
}

# Test 1: no LGTM at all → needs-review
assert_eq "no-lgtm: state"  "needs-review"   "$(state_of "$FIX/no-lgtm.json")"
assert_eq "no-lgtm: reason" "no-lgtm-marker" "$(reason_of "$FIX/no-lgtm.json")"

# Test 2: LGTM bound to older SHA → needs-review (head-changed-since-lgtm)
assert_eq "stale-lgtm: state"  "needs-review"            "$(state_of "$FIX/lgtm-stale.json")"
assert_eq "stale-lgtm: reason" "head-changed-since-lgtm" "$(reason_of "$FIX/lgtm-stale.json")"

# Test 3: /lgtm without marker is treated as no LGTM → needs-review
assert_eq "no-marker: state" "needs-review" "$(state_of "$FIX/lgtm-no-marker.json")"

# Test 4: coverage-missing-ac (LGTM at head but claims AC-1,AC-2 while body
# declares AC-1,AC-2,AC-3) → needs-resign
assert_eq "missing-ac: state"  "needs-resign"             "$(state_of "$FIX/coverage-missing-ac.json")"
assert_eq "missing-ac: reason" "lgtm-coverage-incomplete" "$(reason_of "$FIX/coverage-missing-ac.json")"

# Test 5: coverage-missing-invariant (LGTM doesn't claim triggered invariant)
# → needs-resign
assert_eq "missing-inv: state"  "needs-resign"             "$(state_of "$FIX/coverage-missing-invariant.json")"
assert_eq "missing-inv: reason" "lgtm-coverage-incomplete" "$(reason_of "$FIX/coverage-missing-invariant.json")"

# Test 6: coverage-complete (single-reviewer, all gates pass) →
# idle-merge-ready
assert_eq "complete: state"  "idle-merge-ready" "$(state_of "$FIX/coverage-complete.json")"
assert_eq "complete: reason" "all-gates-pass"   "$(reason_of "$FIX/coverage-complete.json")"

# Test 7: high-risk PR with dual LGTM at head → idle-merge-ready
TMP="$(mktemp)"
jq '. + {body: "Resolves #777.\n\n## AC mapping\n\n| AC | Description | Test | Code | Commit |\n|----|-------------|------|------|--------|\n| AC-1 | x | docs/auth-flow.md:T1 | docs/auth-flow.md:1 | abc1aaa |\n| AC-2 | y | docs/auth-flow.md:T2 | docs/auth-flow.md:2 | abc1aaa |\n\n## Risks\n\n<!-- coding-flows:risks categories= -->\n\n| Category | Description | Mitigation |\n|----------|-------------|------------|\n| none | — | — |\n", commits:[{oid:"abc1aaa0000"}]}' "$FIX/lgtm-dual.json" > "$TMP"
assert_eq "dual-lgtm-high-risk: state" "idle-merge-ready" "$(state_of "$TMP")"
rm -f "$TMP"

# Test 8: high-risk PR with single LGTM only → needs-second-lgtm
TMP="$(mktemp)"
jq '. + {labels:[{name:"high-risk:auth"}], body: "Closes #888.\n\n## AC mapping\n\n| AC | Description | Test | Code | Commit |\n|----|-------------|------|------|--------|\n| AC-1 | x | docs/foo.md:T | docs/foo.md:1 | abc1234 |\n\n## Risks\n\n<!-- coding-flows:risks categories= -->\n\n| Category | Description | Mitigation |\n|----------|-------------|------------|\n| none | — | — |\n", commits:[{oid:"abc1234aaaa"}], files:[{path:"docs/foo.md",additions:5,deletions:1}]}' "$FIX/lgtm-current.json" > "$TMP"
assert_eq "high-risk single-lgtm: state"  "needs-second-lgtm"   "$(state_of "$TMP")"
assert_eq "high-risk single-lgtm: reason" "dual-lgtm-missing"   "$(reason_of "$TMP")"
rm -f "$TMP"

# Test 9: CI failing PR → idle-coder-blocked, reason=ci-failing
assert_eq "ci-fail: state"  "idle-coder-blocked" "$(state_of "$FIX/merge-ci-fail.json")"
assert_eq "ci-fail: reason" "ci-failing"          "$(reason_of "$FIX/merge-ci-fail.json")"

# Test 10: linked-issue missing → idle-coder-blocked
assert_eq "no-issue: state"  "idle-coder-blocked"      "$(state_of "$FIX/merge-no-issue.json")"
assert_eq "no-issue: reason" "linked-issue-missing"    "$(reason_of "$FIX/merge-no-issue.json")"


# Draft PRs → idle-coder-blocked (Reviewer skips drafts)
TMP="$(mktemp)"
jq '. + {isDraft: true}' "$FIX/lgtm-current.json" > "$TMP"
assert_eq "draft PR: state"  "idle-coder-blocked" "$(state_of "$TMP")"
assert_eq "draft PR: reason" "pr-is-draft"        "$(reason_of "$TMP")"
rm -f "$TMP"

# Even drafts with stale or missing LGTMs are still idle-coder-blocked.
TMP="$(mktemp)"
jq '. + {isDraft: true}' "$FIX/no-lgtm.json" > "$TMP"
assert_eq "draft PR no-lgtm: state" "idle-coder-blocked" "$(state_of "$TMP")"
rm -f "$TMP"

test_summary
