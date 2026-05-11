#!/usr/bin/env bash
# Tests for scripts/lib/show-coverage.sh.
set -uo pipefail

TEST_FILE="test_show_coverage.sh"
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
# shellcheck source=../scripts/lib/verify-risks.sh
source "$SKILL_DIR/scripts/lib/verify-risks.sh"
# shellcheck source=../scripts/lib/show-coverage.sh
source "$SKILL_DIR/scripts/lib/show-coverage.sh"

FIX="$THIS_DIR/fixtures/pr-views"
CFG="$THIS_DIR/fixtures/configs/default.json"

# All tests run in a tmpdir with .coding-flows.json so config is found.
TMPDIR_TEST="$(mktemp -d)"
cp "$CFG" "$TMPDIR_TEST/.coding-flows.json"
cd "$TMPDIR_TEST"
trap 'cd /; rm -rf "$TMPDIR_TEST"' EXIT

# Test 1: coverage-complete fixture (AC-1/AC-2, no risks, no invariants
# triggered — body just has the default `none` Risks row, no .go files).
out="$(show_coverage "$(cat "$FIX/coverage-complete.json")" 2>/dev/null)"
assert_contains "complete: ACS line"        "EXPECTED_ACS=AC-1,AC-2" "$out"
assert_contains "complete: no risks (none)" "EXPECTED_RISKS_REVIEWED=" "$out"

# Test 2: coverage-missing-invariant fixture (eventstore + messaging files
# → events-before-publish + no-secrets-in-logs triggered)
out="$(show_coverage "$(cat "$FIX/coverage-missing-invariant.json")" 2>/dev/null)"
assert_contains "events: invariants listed" "EXPECTED_INVARIANTS=events-before-publish,no-secrets-in-logs" "$out"
assert_contains "events: AC-1"              "EXPECTED_ACS=AC-1" "$out"

# Test 3: PR body declares migration + perf risks → values come back as-is
TMP="$(mktemp)"
risks_block='\n## Risks\n\n<!-- coding-flows:risks categories=migration,perf -->\n\n| Category | Description | Mitigation |\n|----------|-------------|------------|\n| migration | x | y |\n| perf | a | b |\n'
jq --arg block "$risks_block" '.body = "## Summary\n\nClose #1.\n\n## AC mapping\n\n| AC | Description | Test | Code | Commit |\n|----|-------------|------|------|--------|\n| AC-1 | x | t.go:T | c.go:1 | xx1 |\n" + ($block | gsub("\\\\n"; "\n")) | .commits = [{oid: "xx1aaaaaa"}] | .files = [{path: "c.go"}]' "$FIX/no-lgtm.json" > "$TMP"
out="$(show_coverage "$(cat "$TMP")" 2>/dev/null)"
assert_contains "two-risks: sorted CSV" "EXPECTED_RISKS_REVIEWED=migration,perf" "$out"
rm -f "$TMP"

# Test 4: missing AC mapping → ACS is empty but script still succeeds (helper
# is informational; verify-ac-mapping is the gate).
TMP="$(mktemp)"
jq '.body = "## Summary\n\nClose #1.\n\n(no AC mapping section)\n"' "$FIX/no-lgtm.json" > "$TMP"
out="$(show_coverage "$(cat "$TMP")" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "missing-ac: exit 0" 0 "$rc"
assert_contains  "missing-ac: empty ACS" "EXPECTED_ACS=" "$out"
rm -f "$TMP"

# Test 5: malformed input → exit 64
show_coverage "not json" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "malformed: exit 64" 64 "$rc"

test_summary
