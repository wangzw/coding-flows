#!/usr/bin/env bash
# Integration test: runs scripts/coding-flows-merge --dry-run --from-file against
# fixtures and asserts the gate exit code matches expectation.
set -uo pipefail

TEST_FILE="test_merge.sh"
TEST_PASS=0
TEST_FAIL=0

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$THIS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$THIS_DIR/lib/assert.sh"

MERGE="$SKILL_DIR/scripts/coding-flows-merge"
FIX="$THIS_DIR/fixtures/pr-views"
CFG="$THIS_DIR/fixtures/configs/default.json"

# All tests run in a tmpdir with .coding-flows.json so config is picked up.
TMPDIR_TEST="$(mktemp -d)"
cp "$CFG" "$TMPDIR_TEST/.coding-flows.json"
cd "$TMPDIR_TEST"
trap 'cd /; rm -rf "$TMPDIR_TEST"' EXIT

# Test 1: coverage-complete → exit 0 (dry-run, all gates pass)
"$MERGE" --from-file "$FIX/coverage-complete.json" --dry-run >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "complete: exit 0" 0 "$rc"

# Test 2: merge-no-issue → exit 11 (linked-issue-missing)
"$MERGE" --from-file "$FIX/merge-no-issue.json" --dry-run >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "no-issue: exit 11" 11 "$rc"

# Test 3: merge-ci-fail → exit 10 (ci-failing)
"$MERGE" --from-file "$FIX/merge-ci-fail.json" --dry-run >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "ci-fail: exit 10" 10 "$rc"

# Test 4: coverage-missing-ac → exit 13 (lgtm-coverage-incomplete)
"$MERGE" --from-file "$FIX/coverage-missing-ac.json" --dry-run >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "missing-ac: exit 13" 13 "$rc"

# Test 5: coverage-missing-invariant → exit 13
"$MERGE" --from-file "$FIX/coverage-missing-invariant.json" --dry-run >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "missing-invariant: exit 13" 13 "$rc"

# Test 6: lgtm-stale → exit 14
"$MERGE" --from-file "$FIX/lgtm-stale.json" --dry-run >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "stale-lgtm: exit 14" 14 "$rc"

# Test 7: no-lgtm → exit 15 (lgtm-missing). Need a fixture with linked
# issue, valid AC mapping, but no LGTM.
TMP_FIX="$(mktemp)"
jq '. + {body: "Closes #999.\n\n## AC mapping\n\n| AC | Description | Test | Code | Commit |\n|----|-------------|------|------|--------|\n| AC-1 | x | README.md:T | README.md:1 | abc1234 |\n\n## Risks\n\n<!-- coding-flows:risks categories= -->\n\n| Category | Description | Mitigation |\n|----------|-------------|------------|\n| none | — | — |\n", commits: [{oid: "abc1234aaaa"}], files: [{path: "README.md", additions: 1, deletions: 0}]}' "$FIX/no-lgtm.json" > "$TMP_FIX"
"$MERGE" --from-file "$TMP_FIX" --dry-run >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "no-lgtm: exit 15" 15 "$rc"
rm -f "$TMP_FIX"

# Test 8: high-risk PR with single LGTM only → exit 18 (dual-lgtm-missing).
# Reuse lgtm-current (single reviewer) and add high-risk label, valid AC.
TMP_FIX="$(mktemp)"
jq '. + {labels:[{name:"high-risk:auth"}], body: "Closes #888.\n\n## AC mapping\n\n| AC | Description | Test | Code | Commit |\n|----|-------------|------|------|--------|\n| AC-1 | x | docs/foo.md:T | docs/foo.md:1 | abc1234 |\n\n## Risks\n\n<!-- coding-flows:risks categories= -->\n\n| Category | Description | Mitigation |\n|----------|-------------|------------|\n| none | — | — |\n", commits:[{oid:"abc1234aaaa"}], files:[{path:"docs/foo.md",additions:5,deletions:1}]}' "$FIX/lgtm-current.json" > "$TMP_FIX"
"$MERGE" --from-file "$TMP_FIX" --dry-run >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "high-risk-single: exit 18" 18 "$rc"
rm -f "$TMP_FIX"

# Test 9: high-risk PR with dual LGTM → exit 0 (all gates pass)
TMP_FIX="$(mktemp)"
# Patch lgtm-dual fixture to satisfy linked-issue + commit-validity gates.
jq '. + {body: "Resolves #777.\n\n## AC mapping\n\n| AC | Description | Test | Code | Commit |\n|----|-------------|------|------|--------|\n| AC-1 | x | docs/auth-flow.md:T1 | docs/auth-flow.md:1 | abc1aaa |\n| AC-2 | y | docs/auth-flow.md:T2 | docs/auth-flow.md:2 | abc1aaa |\n\n## Risks\n\n<!-- coding-flows:risks categories= -->\n\n| Category | Description | Mitigation |\n|----------|-------------|------------|\n| none | — | — |\n", commits:[{oid:"abc1aaa0000"}]}' "$FIX/lgtm-dual.json" > "$TMP_FIX"
"$MERGE" --from-file "$TMP_FIX" --dry-run >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "high-risk-dual: exit 0" 0 "$rc"
rm -f "$TMP_FIX"

# Test 10: outstanding CHANGES_REQUESTED review → exit 16 (unresolved-threads)
TMP_FIX="$(mktemp)"
jq '. + {body: "Closes #666.\n\n## AC mapping\n\n| AC | Description | Test | Code | Commit |\n|----|-------------|------|------|--------|\n| AC-1 | x | README.md:T | README.md:1 | ee1aaaa |\n\n## Risks\n\n<!-- coding-flows:risks categories= -->\n\n| Category | Description | Mitigation |\n|----------|-------------|------------|\n| none | — | — |\n", commits:[{oid:"ee1aaaa0000"}]}' "$FIX/merge-changes-requested.json" > "$TMP_FIX"
"$MERGE" --from-file "$TMP_FIX" --dry-run >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "changes-requested: exit 16" 16 "$rc"
rm -f "$TMP_FIX"

# Test 11: CHANGES_REQUESTED superseded by later /lgtm from same reviewer → exit 0
"$MERGE" --from-file "$FIX/merge-changes-superseded.json" --dry-run >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "changes-superseded: exit 0" 0 "$rc"

# Gate 12 — issue↔PR AC parity. Attach a linked issue with MORE AC items
# than the PR body claims → exit 22.
TMP_FIX="$(mktemp)"
jq '. + {
  linkedIssues: [{
    number: 999,
    body: "## Acceptance criteria\n\n- [ ] item one\n- [ ] item two\n- [ ] item three\n- [ ] item four (dropped by Coder)\n"
  }]
}' "$FIX/coverage-complete.json" > "$TMP_FIX"
"$MERGE" --from-file "$TMP_FIX" --dry-run >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "issue-ac-parity-violation: exit 22" 22 "$rc"
rm -f "$TMP_FIX"

# Gate 12 multi-issue: PR claims 2 ACs, two linked issues with 2 + 1 items
# (3 > 2) → exit 22.
TMP_FIX="$(mktemp)"
jq '. + {
  linkedIssues: [
    {number: 100, body: "## Acceptance criteria\n\n- [ ] one\n- [ ] two\n"},
    {number: 101, body: "## Acceptance criteria\n\n- [ ] only one\n"}
  ]
}' "$FIX/coverage-complete.json" > "$TMP_FIX"
"$MERGE" --from-file "$TMP_FIX" --dry-run >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "issue-ac-parity-multi: exit 22" 22 "$rc"
rm -f "$TMP_FIX"

# Gate 12: coverage-complete with a properly-sized linked issue → exit 0.
TMP_FIX="$(mktemp)"
jq '. + {
  linkedIssues: [{
    number: 999,
    body: "## Acceptance criteria\n\n- [ ] one\n- [ ] two\n"
  }]
}' "$FIX/coverage-complete.json" > "$TMP_FIX"
"$MERGE" --from-file "$TMP_FIX" --dry-run >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "issue-ac-parity-ok: exit 0" 0 "$rc"
rm -f "$TMP_FIX"

# Test 12: configured method 'squash' but repo allows only rebase → exit 17
CODING_FLOWS_REPO_ALLOWS="rebase" "$MERGE" --from-file "$FIX/coverage-complete.json" --dry-run >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "method-disallowed: exit 17" 17 "$rc"

# Test 13: configured 'rebase' override + repo allows 'rebase' → exit 0
TMP_CFG_DIR="$(mktemp -d)"
cp "$CFG" "$TMP_CFG_DIR/.coding-flows.json"
# Patch the temp config to set method=rebase, then point cwd at it.
jq '.merge.method = "rebase"' "$CFG" > "$TMP_CFG_DIR/.coding-flows.json"
( cd "$TMP_CFG_DIR" && CODING_FLOWS_REPO_ALLOWS="rebase" "$MERGE" --from-file "$FIX/coverage-complete.json" --dry-run >/dev/null 2>&1 ) && rc=0 || rc=$?
assert_exit_code "rebase-allowed: exit 0" 0 "$rc"
rm -rf "$TMP_CFG_DIR"

test_summary
