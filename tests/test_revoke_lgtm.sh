#!/usr/bin/env bash
# CLI smoke test for scripts/coding-flows-revoke-lgtm. Exercises arg
# parsing + --dry-run output; the actual gh pr comment call isn't tested
# (needs a live repo).
set -uo pipefail

TEST_FILE="test_revoke_lgtm.sh"
TEST_PASS=0
TEST_FAIL=0

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$THIS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$THIS_DIR/lib/assert.sh"

CLI="$SKILL_DIR/scripts/coding-flows-revoke-lgtm"

# Test 1: missing PR → usage error
"$CLI" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "no args: exit 64" 64 "$rc"

# Test 2: PR but no --reviewer → usage error
"$CLI" 123 -m "x" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "missing --reviewer: exit 64" 64 "$rc"

# Test 3: PR + --reviewer but no body → usage error
"$CLI" 123 --reviewer r1 >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "no body: exit 64" 64 "$rc"

# Test 4: --dry-run prints structured output
out="$("$CLI" 253 --reviewer r1 -m "found bug in foo.go:42" --dry-run 2>/dev/null)"
rc=$?
assert_exit_code "dry-run: exit 0" 0 "$rc"
assert_contains  "dry-run: PR= line" "PR=253" "$out"
assert_contains  "dry-run: reviewer" "REVIEWER=r1" "$out"
assert_contains  "dry-run: action" "ACTION=comment-with-revoke-marker" "$out"
assert_contains  "dry-run: byte count" "BODY_BYTES=" "$out"
assert_contains  "dry-run: marker" "DRY_RUN=yes" "$out"

# Test 5: --body-file works (just check positive byte count)
TMP="$(mktemp)"
printf 'Found bug at:\n- src/foo.go:42 — null deref.\n' > "$TMP"
out="$("$CLI" 253 --reviewer r1 --body-file "$TMP" --dry-run 2>/dev/null)"
rc=$?
assert_exit_code "body-file: exit 0" 0 "$rc"
body_bytes_line="$(printf '%s\n' "$out" | grep -E '^BODY_BYTES=')"
body_bytes_val="${body_bytes_line#BODY_BYTES=}"
if [[ "$body_bytes_val" =~ ^[1-9][0-9]*$ ]]; then
  TEST_PASS=$((TEST_PASS + 1))
else
  TEST_FAIL=$((TEST_FAIL + 1))
  echo "  FAIL [body-file: positive byte count]" >&2
  echo "    expected positive integer, got: $(printf '%q' "$body_bytes_val")" >&2
fi
rm -f "$TMP"

# Test 6: --body-file pointing nowhere → error
"$CLI" 253 --reviewer r1 --body-file /nonexistent --dry-run >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "missing-file: exit 64" 64 "$rc"

# Test 7: -m alias works
"$CLI" 253 --reviewer r1 -m "x" --dry-run >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "-m alias: exit 0" 0 "$rc"

# Test 8: --message alias works
"$CLI" 253 --reviewer r1 --message "x" --dry-run >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "--message alias: exit 0" 0 "$rc"

# Test 9: --body alias works
"$CLI" 253 --reviewer r1 --body "x" --dry-run >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "--body alias: exit 0" 0 "$rc"

# Test 10: non-numeric PR → usage error
"$CLI" abc --reviewer r1 -m "x" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "non-numeric PR: exit 64" 64 "$rc"

test_summary
