#!/usr/bin/env bash
# Unit tests for scripts/lib/gh-merge-result.sh — classify_gh_merge_result.
set -uo pipefail

TEST_FILE="test_gh_merge_result.sh"
TEST_PASS=0
TEST_FAIL=0

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$THIS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$THIS_DIR/lib/assert.sh"
# shellcheck source=../scripts/lib/gh-merge-result.sh
source "$SKILL_DIR/scripts/lib/gh-merge-result.sh"

run() {
  local rc="$1" state="$2" out="$3"
  GH_MERGE_VERDICT=""
  classify_gh_merge_result "$rc" "$state" "$out"
  printf '%s' "$GH_MERGE_VERDICT"
}

# 1. rc=0 → success regardless of state/output
assert_eq "rc=0 → success" "success" "$(run 0 "OPEN" "anything")"
assert_eq "rc=0 + MERGED → success" "success" "$(run 0 "MERGED" "✓ Squashed and merged pull request #123")"

# 2. rc!=0 + remote != MERGED → real-failure even if output is cosmetic
assert_eq "rc=1 + OPEN → real-failure" "real-failure" \
  "$(run 1 "OPEN" "failed to delete local branch foo")"
assert_eq "rc=1 + empty state → real-failure" "real-failure" \
  "$(run 1 "" "failed to delete local branch foo")"

# 3. rc!=0 + MERGED + only cosmetic line → cosmetic-success
assert_eq "rc=1 + MERGED + delete-branch warning → cosmetic" "cosmetic-success" \
  "$(run 1 "MERGED" "failed to delete local branch foo: used by worktree at /tmp/x")"

# 4. rc!=0 + MERGED + ! prefix on warning → cosmetic
assert_eq "rc=1 + MERGED + bang-prefix → cosmetic" "cosmetic-success" \
  "$(run 1 "MERGED" "! failed to delete local branch foo")"

# 5. rc!=0 + MERGED + success banner + warning → cosmetic
multiline=$'✓ Squashed and merged pull request #281\n! failed to delete local branch chore/foo'
assert_eq "rc=1 + MERGED + banner+warning → cosmetic" "cosmetic-success" \
  "$(run 1 "MERGED" "$multiline")"

# 6. rc!=0 + MERGED + non-cosmetic line present → real-failure
mixed=$'failed to delete local branch foo\nFATAL: something else broke'
assert_eq "rc=1 + MERGED + extra error → real-failure" "real-failure" \
  "$(run 1 "MERGED" "$mixed")"

# 7. rc!=0 + MERGED + empty output → cosmetic (degenerate but safe — remote
#    confirms merged, no error text to interpret)
assert_eq "rc=1 + MERGED + empty out → cosmetic" "cosmetic-success" \
  "$(run 1 "MERGED" "")"

# 8. rc!=0 + MERGED + only whitespace lines → cosmetic
ws=$'\n   \n\t\n'
assert_eq "rc=1 + MERGED + whitespace → cosmetic" "cosmetic-success" \
  "$(run 1 "MERGED" "$ws")"

# 9. rc!=0 + MERGED + warning with extra trailing context lines → cosmetic
trailing=$'failed to delete local branch foo: failed to run git: error: cannot delete branch'
assert_eq "rc=1 + MERGED + multi-token warning → cosmetic" "cosmetic-success" \
  "$(run 1 "MERGED" "$trailing")"

# 10. rc!=0 + CLOSED state (not MERGED) → real-failure even with cosmetic output
assert_eq "rc=1 + CLOSED → real-failure" "real-failure" \
  "$(run 1 "CLOSED" "failed to delete local branch foo")"

# 11. rc!=0 + remote API returned nothing → real-failure (can't confirm)
assert_eq "rc=1 + state=DRAFT → real-failure" "real-failure" \
  "$(run 1 "DRAFT" "failed to delete local branch foo")"

# 12. rc=2 + MERGED + cosmetic → cosmetic (any non-zero rc)
assert_eq "rc=2 + MERGED + cosmetic → cosmetic" "cosmetic-success" \
  "$(run 2 "MERGED" "failed to delete local branch foo")"

printf '%-50s %d/%d %s\n' "$TEST_FILE" "$TEST_PASS" "$((TEST_PASS+TEST_FAIL))" \
  "$([[ $TEST_FAIL -eq 0 ]] && echo OK || echo FAIL)"
exit "$TEST_FAIL"
