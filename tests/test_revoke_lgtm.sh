#!/usr/bin/env bash
# CLI smoke test for scripts/coding-flows-revoke-lgtm. We can't easily
# exercise the real gh pr review call without a live repo, so we test
# arg parsing + --dry-run output.
set -uo pipefail

TEST_FILE="test_revoke_lgtm.sh"
TEST_PASS=0
TEST_FAIL=0

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$THIS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$THIS_DIR/lib/assert.sh"

CLI="$SKILL_DIR/scripts/coding-flows-revoke-lgtm"

# Test 1: missing PR + body → usage error
"$CLI" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "no args: exit 64" 64 "$rc"

# Test 2: PR but no body → usage error
"$CLI" 123 >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "no body: exit 64" 64 "$rc"

# Test 3: --dry-run prints structured output, no gh call
out="$("$CLI" 253 -m "Revoking — found bug in foo.go:42" --dry-run 2>/dev/null)"
rc=$?
assert_exit_code "dry-run: exit 0" 0 "$rc"
assert_contains  "dry-run: PR= line" "PR=253" "$out"
assert_contains  "dry-run: action" "ACTION=request-changes" "$out"
assert_contains  "dry-run: byte count" "BODY_BYTES=" "$out"
assert_contains  "dry-run: marker" "DRY_RUN=yes" "$out"

# Test 4: --body-file works (just check the script accepts the file path
# and emits a non-zero byte count — `$(cat ...)` strips trailing newlines
# so exact byte-count parity with `wc -c` isn't meaningful)
TMP="$(mktemp)"
printf 'Revoking. Bug at:\n- src/foo.go:42 — null deref.\n' > "$TMP"
out="$("$CLI" 253 --body-file "$TMP" --dry-run 2>/dev/null)"
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

# Test 5: --body-file pointing nowhere → error
"$CLI" 253 --body-file /nonexistent --dry-run >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "missing-file: exit 64" 64 "$rc"

# Test 6: -m alias works
"$CLI" 253 -m "x" --dry-run >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "-m alias: exit 0" 0 "$rc"

# Test 7: --message alias works
"$CLI" 253 --message "x" --dry-run >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "--message alias: exit 0" 0 "$rc"

# Test 8: --body alias works
"$CLI" 253 --body "x" --dry-run >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "--body alias: exit 0" 0 "$rc"

# Test 9: non-numeric PR → usage error
"$CLI" abc -m "x" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "non-numeric PR: exit 64" 64 "$rc"

test_summary
