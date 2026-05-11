#!/usr/bin/env bash
# Tests for scripts/lib/verify-risks.sh.
set -uo pipefail

TEST_FILE="test_verify_risks.sh"
TEST_PASS=0
TEST_FAIL=0

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$THIS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$THIS_DIR/lib/assert.sh"
# shellcheck source=../scripts/lib/common.sh
source "$SKILL_DIR/scripts/lib/common.sh"
# shellcheck source=../scripts/lib/verify-risks.sh
source "$SKILL_DIR/scripts/lib/verify-risks.sh"

# Helper: build a Risks-only body.
body_with_risks() {
  local marker="$1" rows="$2"
  printf '## Summary\n\nClose #1.\n\n## Risks\n\n%s\n\n| Category | Description | Mitigation |\n|----------|-------------|------------|\n%s\n' \
    "$marker" "$rows"
}

# Test 1: valid migration + perf
body="$(body_with_risks \
  '<!-- coding-flows:risks categories=migration,perf -->' \
  $'| migration | adds NOT NULL col | backfill + dual-write |\n| perf | new index | run EXPLAIN |')"
out="$(verify_risks "$body" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "two-categories: exit 0" 0 "$rc"
assert_contains  "two-categories: sorted CSV" "RISKS_CATEGORIES=migration,perf" "$out"

# Test 2: none-only is valid
body="$(body_with_risks \
  '<!-- coding-flows:risks categories= -->' \
  $'| none | — | — |')"
verify_risks "$body" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "none-only: exit 0" 0 "$rc"

# Test 3: none mixed with another category → fail
body="$(body_with_risks \
  '<!-- coding-flows:risks categories=migration -->' \
  $'| migration | x | y |\n| none | — | — |')"
verify_risks "$body" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "none-mixed: exit 1" 1 "$rc"

# Test 4: unknown category → fail
body="$(body_with_risks \
  '<!-- coding-flows:risks categories=cosmic -->' \
  $'| cosmic | weird | — |')"
verify_risks "$body" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "unknown-category: exit 1" 1 "$rc"

# Test 5: marker mismatch → fail
body="$(body_with_risks \
  '<!-- coding-flows:risks categories=feature-flag -->' \
  $'| migration | x | y |')"
verify_risks "$body" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "marker-mismatch: exit 1" 1 "$rc"

# Test 6: missing marker, non-none category → fail
body="$(printf '## Summary\n\n## Risks\n\n| Category | Description | Mitigation |\n|----------|-------------|------------|\n| perf | x | y |\n')"
verify_risks "$body" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "missing-marker: exit 1" 1 "$rc"

# Test 7: missing required column → fail
body="$(printf '## Risks\n\n| Category | Description |\n|----------|-------------|\n| migration | x |\n')"
verify_risks "$body" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "missing-column: exit 1" 1 "$rc"

# Test 8: no Risks section → fail
body="$(printf '## Summary\n\nNo risks here.\n')"
verify_risks "$body" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "no-section: exit 1" 1 "$rc"

# Test 9: blank description on non-none row → fail
body="$(body_with_risks \
  '<!-- coding-flows:risks categories=migration -->' \
  $'| migration | — | — |')"
verify_risks "$body" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "blank-non-none: exit 1" 1 "$rc"

# Test 10: marker with empty value when none-only → exit 0 (handled)
body="$(body_with_risks \
  '<!-- coding-flows:risks categories= -->' \
  $'| none | — | — |')"
out="$(verify_risks "$body" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "none-empty-marker: exit 0" 0 "$rc"
# Strictly assert the value is empty (the trailing newline distinguishes
# RISKS_CATEGORIES= from RISKS_CATEGORIES=foo).
risks_value="$(printf '%s\n' "$out" | grep -E '^RISKS_CATEGORIES=' | head -n1 | sed -E 's/^RISKS_CATEGORIES=//')"
assert_eq        "none-empty-marker: empty value" "" "$risks_value"

# Test 11: pipe-in-Description is escaped correctly (round-trip test)
body="$(body_with_risks \
  '<!-- coding-flows:risks categories=migration -->' \
  $'| migration | adds col \\| renames index | backfill |')"
out="$(verify_risks "$body" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "escaped-pipe: exit 0" 0 "$rc"

test_summary
