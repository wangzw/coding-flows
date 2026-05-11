#!/usr/bin/env bash
# Tests for scripts/lib/filter-reviewer.sh.
set -uo pipefail

TEST_FILE="test_filter_reviewer.sh"
TEST_PASS=0
TEST_FAIL=0

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$THIS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$THIS_DIR/lib/assert.sh"
# shellcheck source=../scripts/lib/common.sh
source "$SKILL_DIR/scripts/lib/common.sh"
# shellcheck source=../scripts/lib/filter-reviewer.sh
source "$SKILL_DIR/scripts/lib/filter-reviewer.sh"

FIX="$THIS_DIR/fixtures/pr-views"

# Test 1: filter as r1 → keeps r1's LGTM, drops r2's LGTM, keeps plain comments.
input="$(cat "$FIX/lgtm-dual.json")"
out="$(filter_pr_view_for_reviewer "$input" "r1")"
# r1 LGTM should still be present (find marker reviewer=r1)
assert_contains "as r1: keeps r1 LGTM" "reviewer=r1" "$out"
# r2 LGTM should be gone
assert_not_contains "as r1: drops r2 LGTM" "reviewer=r2" "$out"
# Comment counts
in_count="$(jq '.comments | length' <<<"$input")"
out_count="$(jq '.comments | length' <<<"$out")"
assert_eq "as r1: one comment dropped" "$((in_count - 1))" "$out_count"

# Test 2: filter as r2 → keeps r2 LGTM, drops r1 LGTM.
out="$(filter_pr_view_for_reviewer "$input" "r2")"
assert_contains "as r2: keeps r2 LGTM" "reviewer=r2" "$out"
assert_not_contains "as r2: drops r1 LGTM" "reviewer=r1" "$out"

# Test 3: filter as unknown reviewer → drops all coding-flows-marked comments
out="$(filter_pr_view_for_reviewer "$input" "rX")"
assert_not_contains "as rX: drops r1 LGTM" "reviewer=r1" "$out"
assert_not_contains "as rX: drops r2 LGTM" "reviewer=r2" "$out"

# Test 4: comments without coding-flows markers are preserved.
# no-lgtm.json has one ordinary comment ("Looks interesting...").
input="$(cat "$FIX/no-lgtm.json")"
out="$(filter_pr_view_for_reviewer "$input" "r1")"
assert_contains "no-marker comments preserved" "Looks interesting" "$out"

# Test 5: reviews left untouched (documented limitation).
input="$(cat "$FIX/merge-changes-requested.json")"
out="$(filter_pr_view_for_reviewer "$input" "r1")"
in_reviews="$(jq '.reviews | length' <<<"$input")"
out_reviews="$(jq '.reviews | length' <<<"$out")"
assert_eq "reviews count unchanged" "$in_reviews" "$out_reviews"

# Test 6: empty reviewer id → exit 64.
filter_pr_view_for_reviewer "$input" "" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "empty reviewer id: exit 64" 64 "$rc"

test_summary
