#!/usr/bin/env bash
# Tests for scripts/lib/verify-scope-envelope.sh.
set -uo pipefail

TEST_FILE="test_verify_scope_envelope.sh"
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
# shellcheck source=../scripts/lib/verify-scope-envelope.sh
source "$SKILL_DIR/scripts/lib/verify-scope-envelope.sh"

# Helper: build a PR view JSON with given AC mapping body + changed files.
make_pr_view() {
  local body="$1" files_json="$2"
  jq -n --arg b "$body" --argjson f "$files_json" \
    '{number: 99, headRefOid: "h", body: $b, files: $f, commits: [{oid: "aaa1bbb"}]}'
}

AC_BODY='## Summary

Closes #5.

## AC mapping

| AC | Description | Test | Code | Commit |
|----|-------------|------|------|--------|
| AC-1 | x | service_test.go:T | service.go:1-20 | aaa1bbb |
'

# Test 1: all changed files claimed by AC mapping → exit 0
files='[{"path":"backend/foo/service.go","additions":10,"deletions":1},{"path":"backend/foo/service_test.go","additions":5,"deletions":0}]'
pr="$(make_pr_view "$AC_BODY" "$files")"
out="$(verify_scope_envelope "$pr" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "all-claimed: exit 0" 0 "$rc"
assert_contains  "all-claimed: SCOPE_UNCLAIMED= empty" $'SCOPE_UNCLAIMED=\n' "$out"$'\n'

# Test 2: an extra unclaimed file → exit 1, file listed
files='[{"path":"backend/foo/service.go"},{"path":"backend/foo/service_test.go"},{"path":"backend/bar/unrelated.go"}]'
pr="$(make_pr_view "$AC_BODY" "$files")"
out="$(verify_scope_envelope "$pr" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "unclaimed: exit 1" 1 "$rc"
assert_contains  "unclaimed: names file" "backend/bar/unrelated.go" "$out"

# Test 3: Support files section claims the file → exit 0
body_with_support="$AC_BODY"$'\n\n## Support files\n\n- backend/bar/unrelated.go — needed by side change\n'
pr="$(make_pr_view "$body_with_support" "$files")"
verify_scope_envelope "$pr" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "support-claimed: exit 0" 0 "$rc"

# Test 4: default excludes cover *.md → exit 0
files='[{"path":"backend/foo/service.go"},{"path":"backend/foo/service_test.go"},{"path":"CHANGELOG.md"},{"path":"docs/guide.md"}]'
pr="$(make_pr_view "$AC_BODY" "$files")"
verify_scope_envelope "$pr" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "md-excluded: exit 0" 0 "$rc"

# Test 5: config-driven excludes — fixture config says **/generated/**.
TMPDIR_TEST="$(mktemp -d)"
cat > "$TMPDIR_TEST/.coding-flows.json" <<'EOF'
{"scope_envelope": {"exclude_paths": ["frontend/api/generated/**", "*.lock"]}}
EOF
cd "$TMPDIR_TEST"
files='[{"path":"backend/foo/service.go"},{"path":"backend/foo/service_test.go"},{"path":"frontend/api/generated/foo.ts"},{"path":"pnpm.lock"}]'
pr="$(make_pr_view "$AC_BODY" "$files")"
verify_scope_envelope "$pr" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "config-excludes: exit 0" 0 "$rc"
cd /
rm -rf "$TMPDIR_TEST"

# Test 6: AC mapping references relative path, changed file has full path → match
ac_short='## Summary
Closes #5.
## AC mapping
| AC | Description | Test | Code | Commit |
|----|-------------|------|------|--------|
| AC-1 | x | service_test.go:T | service.go:1-20 | aaa1bbb |
'
files='[{"path":"backend/foo/service.go"},{"path":"backend/foo/service_test.go"}]'
pr="$(make_pr_view "$ac_short" "$files")"
verify_scope_envelope "$pr" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "suffix-match: exit 0" 0 "$rc"

# Test 7: empty changed files list → exit 0, count=0
files='[]'
pr="$(make_pr_view "$AC_BODY" "$files")"
out="$(verify_scope_envelope "$pr" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "empty-diff: exit 0" 0 "$rc"
assert_contains  "empty-diff: SCOPE_CLAIMED=0" "SCOPE_CLAIMED=0" "$out"

test_summary
