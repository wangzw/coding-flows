#!/usr/bin/env bash
# Tests for scripts/lib/verify-ac-mapping.sh.
set -uo pipefail

TEST_FILE="test_verify_ac_mapping.sh"
TEST_PASS=0
TEST_FAIL=0

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$THIS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$THIS_DIR/lib/assert.sh"
# shellcheck source=../scripts/lib/common.sh
source "$SKILL_DIR/scripts/lib/common.sh"
# shellcheck source=../scripts/lib/verify-ac-mapping.sh
source "$SKILL_DIR/scripts/lib/verify-ac-mapping.sh"

PB="$THIS_DIR/fixtures/pr-bodies"

# Test 1: valid table → exit 0
body="$(cat "$PB/valid.md")"
out="$(verify_ac_mapping "$body" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "valid: exit 0" 0 "$rc"
assert_contains  "valid: 3 rows" "AC_ROWS=3" "$out"
assert_contains  "valid: ids" "AC-1,AC-2,AC-3" "$out"

# Test 2: no AC mapping section → exit 1
body="$(cat "$PB/no-section.md")"
verify_ac_mapping "$body">/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "no-section: exit 1" 1 "$rc"

# Test 3: row with TBD placeholder → exit 1
body="$(cat "$PB/placeholder-row.md")"
verify_ac_mapping "$body">/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "placeholder-row: exit 1" 1 "$rc"

# Test 4: required column missing → exit 1
body="$(cat "$PB/missing-column.md")"
verify_ac_mapping "$body">/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "missing-column: exit 1" 1 "$rc"

# Test 5: duplicate AC ID → exit 1
body="$(cat "$PB/dup-id.md")"
verify_ac_mapping "$body">/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "dup-id: exit 1" 1 "$rc"

# Test 6: commit SHA validation when json provided
# valid.md references abc1234 and e5f6g7h; fake PR view has only abc1234.
pr_json='{"commits":[{"oid":"abc1234aaaa"}]}'
body="$(cat "$PB/valid.md")"
verify_ac_mapping "$body" "$pr_json">/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "commit-not-in-pr: exit 1" 1 "$rc"

# Test 7: commit SHA validation passes when both commits present
# valid.md references "a1b2c3d" and "e5f6g7h" — provide commits whose oids
# carry those as prefixes.
pr_json='{"commits":[{"oid":"a1b2c3deeee"},{"oid":"e5f6g7h0000"}]}'
verify_ac_mapping "$body" "$pr_json">/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "commits-in-pr: exit 0" 0 "$rc"

# Test 8: angle-bracketed placeholder (from template)
body='## Summary
Closes #1.
## AC mapping
| AC | Description | Test | Code | Commit |
|----|-------------|------|------|--------|
| AC-1 | <copy AC text> | <test_file.go> | <impl_file.go> | <SHA> |
'
verify_ac_mapping "$body">/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "angle-placeholder: exit 1" 1 "$rc"

# Test 9: case-insensitive section header "## ACs"
body='## ACs
| AC | Description | Test | Code | Commit |
|----|-------------|------|------|--------|
| AC-1 | thing | t.go | c.go | abc1 |
'
verify_ac_mapping "$body">/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "alt-header: exit 0" 0 "$rc"

# Test 10: empty body → exit 1
verify_ac_mapping "">/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "empty-body: exit 1" 1 "$rc"

# Test 11: comma in Test cell → exit 1 (one path per row)
body='## AC mapping
| AC | Description | Test | Code | Commit |
|----|-------------|------|------|--------|
| AC-1 | thing | foo_test.go:T, bar_test.go:T | foo.go:1 | abc1 |
'
verify_ac_mapping "$body" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "comma-in-test: exit 1" 1 "$rc"

# Test 12: comma in Code cell → exit 1
body='## AC mapping
| AC | Description | Test | Code | Commit |
|----|-------------|------|------|--------|
| AC-1 | thing | t.go:T | foo.go:1, bar.go:1 | abc1 |
'
verify_ac_mapping "$body" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "comma-in-code: exit 1" 1 "$rc"

test_summary
