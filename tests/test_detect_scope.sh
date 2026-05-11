#!/usr/bin/env bash
# Tests for scripts/lib/detect-scope.sh.
set -uo pipefail

TEST_FILE="test_detect_scope.sh"
TEST_PASS=0
TEST_FAIL=0

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$THIS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$THIS_DIR/lib/assert.sh"
# shellcheck source=../scripts/lib/common.sh
source "$SKILL_DIR/scripts/lib/common.sh"
# shellcheck source=../scripts/lib/detect-scope.sh
source "$SKILL_DIR/scripts/lib/detect-scope.sh"

CFG="$THIS_DIR/fixtures/configs/default.json"
FILES="$THIS_DIR/fixtures/pr-files"

# Test 1: backend-only files → triggers backend rule only
out="$(detect_scope "$(cat "$FILES/backend-only.txt")" "$CFG" 2>/dev/null)"
assert_contains    "backend-only: hits backend rule" "RULE_0" "$out"
assert_contains    "backend-only: lists backend-coding-standards" \
                   "backend-coding-standards" "$out"
assert_not_contains "backend-only: no frontend rule" "RULE_1" "$out"

# Test 2: frontend-only files → triggers frontend rule
out="$(detect_scope "$(cat "$FILES/frontend-only.txt")" "$CFG" 2>/dev/null)"
assert_contains    "frontend-only: hits frontend rule" "RULE_1" "$out"
assert_contains    "frontend-only: lists frontend-coding-standards" \
                   "frontend-coding-standards" "$out"

# Test 3: auth-touched files → backend rule (auth is backend/)
out="$(detect_scope "$(cat "$FILES/auth-touched.txt")" "$CFG" 2>/dev/null)"
assert_contains    "auth: hits backend rule" "RULE_0" "$out"

# Test 4: docs-only files → no rules match
out="$(detect_scope "$(cat "$FILES/docs-only.txt")" "$CFG" 2>/dev/null)"
assert_eq          "docs-only: no rules" "" "$out"

# Test 5: empty files list → no rules
out="$(detect_scope "" "$CFG" 2>/dev/null)"
assert_eq          "empty: no rules" "" "$out"

# Test 6: missing config → no error, no output
out="$(detect_scope "backend/foo.go" "/nonexistent/config.json" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code   "no-config: exit 0" 0 "$rc"
assert_eq          "no-config: no output" "" "$out"

# Test 7: malformed config → exit 65
bad_cfg="$(mktemp)"
echo "not json" > "$bad_cfg"
detect_scope "backend/foo.go" "$bad_cfg" 2>/dev/null && rc=0 || rc=$?
assert_exit_code   "bad-config: exit 65" 65 "$rc"
rm -f "$bad_cfg"

# Test 8: glob_match works for ** at depth
glob_match "backend/**" "backend/internal/foo/bar.go" && rc=0 || rc=$?
assert_exit_code   "glob: backend/** matches deep path" 0 "$rc"

glob_match "**/auth/**" "backend/internal/auth/middleware.go" && rc=0 || rc=$?
assert_exit_code   "glob: **/auth/** matches" 0 "$rc"

glob_match "**/*.go" "foo.go" && rc=0 || rc=$?
assert_exit_code   "glob: **/*.go matches root file" 0 "$rc"

glob_match "**/*.go" "frontend/foo.tsx" && rc=0 || rc=$?
assert_exit_code   "glob: **/*.go does NOT match .tsx" 1 "$rc"

test_summary
