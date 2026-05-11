#!/usr/bin/env bash
# Tests for scripts/lib/label-risk.sh.
set -uo pipefail

TEST_FILE="test_label_risk.sh"
TEST_PASS=0
TEST_FAIL=0

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$THIS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$THIS_DIR/lib/assert.sh"
# shellcheck source=../scripts/lib/common.sh
source "$SKILL_DIR/scripts/lib/common.sh"
# shellcheck source=../scripts/lib/label-risk.sh
source "$SKILL_DIR/scripts/lib/label-risk.sh"

CFG="$THIS_DIR/fixtures/configs/default.json"
FILES="$THIS_DIR/fixtures/pr-files"

# Test 1: auth-touched files → high-risk:auth
out="$(detect_high_risk_labels "$(cat "$FILES/auth-touched.txt")" 100 "" "$CFG" 2>/dev/null)"
assert_contains   "auth: labels with high-risk:auth" "high-risk:auth" "$out"

# Test 2: backend-only (no auth, no migrations, under size) → no label
out="$(detect_high_risk_labels "$(cat "$FILES/backend-only.txt")" 200 "" "$CFG" 2>/dev/null)"
assert_eq         "backend: no label" "" "$out"

# Test 3: large diff (>=1000 lines) → high-risk:large
out="$(detect_high_risk_labels "$(cat "$FILES/backend-only.txt")" 1500 "" "$CFG" 2>/dev/null)"
assert_contains   "large: triggers size rule" "high-risk:large" "$out"

# Test 4: large diff but excluded by 'dependencies' label → still large?
# default config doesn't exclude large via 'dependencies' — billing rule does.
# Switch fixture: large + auth excluded? Not in default. Test that
# exclude_labels for billing rule works.
# Create a temp config that excludes large on dependencies label.
TMP_CFG="$(mktemp)"
cat > "$TMP_CFG" <<'EOF'
{
  "high_risk_rules": [
    {
      "size": {"lines_changed": 1000},
      "exclude_labels": ["dependencies"],
      "label": "high-risk:large"
    }
  ]
}
EOF
out="$(detect_high_risk_labels "anyfile.txt" 2000 "dependencies" "$TMP_CFG" 2>/dev/null)"
assert_eq         "excluded-by-label: empty" "" "$out"
out="$(detect_high_risk_labels "anyfile.txt" 2000 "" "$TMP_CFG" 2>/dev/null)"
assert_contains   "no-exclude-label: triggers large" "high-risk:large" "$out"
rm -f "$TMP_CFG"

# Test 5: exclude_paths skips matching files
TMP_CFG="$(mktemp)"
cat > "$TMP_CFG" <<'EOF'
{
  "high_risk_rules": [
    {
      "paths": ["**/migrations/**"],
      "exclude_paths": ["**/test/**"],
      "label": "high-risk:migration"
    }
  ]
}
EOF
out="$(detect_high_risk_labels $'backend/migrations/foo.sql' 10 "" "$TMP_CFG" 2>/dev/null)"
assert_contains   "migration: triggered" "high-risk:migration" "$out"
out="$(detect_high_risk_labels $'backend/migrations/test/foo.sql' 10 "" "$TMP_CFG" 2>/dev/null)"
assert_eq         "migration-in-test: excluded" "" "$out"
rm -f "$TMP_CFG"

# Test 6: no config → empty output, exit 0
out="$(detect_high_risk_labels "anything" 100 "" "/nonexistent.json" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code  "no-config: exit 0" 0 "$rc"
assert_eq         "no-config: empty" "" "$out"

# Test 7: multiple rules fire → both labels emitted
files="$(printf 'backend/internal/auth/middleware.go\nbackend/migrations/001.sql\n')"
out="$(detect_high_risk_labels "$files" 100 "" "$CFG" 2>/dev/null)"
assert_contains   "multi: auth" "high-risk:auth" "$out"
assert_contains   "multi: migration" "high-risk:migration" "$out"

test_summary
