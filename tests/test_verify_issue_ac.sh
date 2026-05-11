#!/usr/bin/env bash
# Tests for scripts/lib/verify-issue-ac.sh.
set -uo pipefail

TEST_FILE="test_verify_issue_ac.sh"
TEST_PASS=0
TEST_FAIL=0

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$THIS_DIR/.." && pwd)"

source "$THIS_DIR/lib/assert.sh"
source "$SKILL_DIR/scripts/lib/common.sh"
source "$SKILL_DIR/scripts/lib/verify-ac-mapping.sh"
source "$SKILL_DIR/scripts/lib/verify-issue-ac.sh"

mk_pr_view() {
  # mk_pr_view <pr-body> <issue-body>
  jq -n --arg pb "$1" --arg ib "$2" \
    '{number: 99, headRefOid: "h", body: $pb, linkedIssueBody: $ib, commits: [{oid: "abc1234"}], files: []}'
}

# Test 1: counts match → pass
pr_body='## Summary

Closes #1.

## AC mapping

| AC | Description | Test | Code | Commit |
|----|-------------|------|------|--------|
| AC-1 | first AC | t.go:T1 | c.go:1 | abc1234 |
| AC-2 | second AC | t.go:T2 | c.go:2 | abc1234 |
'
issue_body='## Acceptance criteria

- [ ] first AC
- [ ] second AC
'
out="$(verify_issue_ac "$(mk_pr_view "$pr_body" "$issue_body")" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "match: exit 0" 0 "$rc"
assert_contains  "match: ISSUE_AC_COUNT=2" "ISSUE_AC_COUNT=2" "$out"
assert_contains  "match: PR_AC_COUNT=2"    "PR_AC_COUNT=2"    "$out"

# Test 2: PR has fewer rows than issue → fail (Coder dropped one)
pr_body='## AC mapping

| AC | Description | Test | Code | Commit |
|----|-------------|------|------|--------|
| AC-1 | first AC | t.go:T1 | c.go:1 | abc1234 |
'
issue_body='## Acceptance criteria

- [ ] first AC
- [ ] second AC
- [ ] third AC
'
out="$(verify_issue_ac "$(mk_pr_view "$pr_body" "$issue_body")" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "dropped: exit 1" 1 "$rc"
assert_contains  "dropped: ISSUE_AC_COUNT=3" "ISSUE_AC_COUNT=3" "$out"
assert_contains  "dropped: PR_AC_COUNT=1"    "PR_AC_COUNT=1"    "$out"

# Test 3: PR has MORE rows than issue → pass (Coder split or added derived ACs)
pr_body='## AC mapping

| AC | Description | Test | Code | Commit |
|----|-------------|------|------|--------|
| AC-1 | derived A | t.go:T1 | c.go:1 | abc1234 |
| AC-2 | derived B | t.go:T2 | c.go:2 | abc1234 |
| AC-3 | extra | t.go:T3 | c.go:3 | abc1234 |
'
issue_body='## Acceptance criteria

- [ ] single AC item
'
verify_issue_ac "$(mk_pr_view "$pr_body" "$issue_body")" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "more-rows-than-issue: exit 0" 0 "$rc"

# Test 4: no `## Acceptance criteria` in issue → pass (count=0)
pr_body='## AC mapping

| AC | Description | Test | Code | Commit |
|----|-------------|------|------|--------|
| AC-1 | thing | t.go:T | c.go:1 | abc1234 |
'
issue_body='## Summary

Some bug description.

## Reproduce

Step 1.
'
out="$(verify_issue_ac "$(mk_pr_view "$pr_body" "$issue_body")" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "no-ac-section: exit 0" 0 "$rc"
assert_contains  "no-ac-section: ISSUE_AC_COUNT=0" "ISSUE_AC_COUNT=0" "$out"

# Test 5: no linkedIssueBody field → skip with warning, pass
pr_view='{"number":1,"headRefOid":"h","body":"## AC mapping\n\n| AC | Description | Test | Code | Commit |\n|----|-------------|------|------|--------|\n| AC-1 | x | t.go:T | c.go:1 | abc |\n","commits":[{"oid":"abc1234"}]}'
out="$(verify_issue_ac "$pr_view" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "no-issue-body: exit 0" 0 "$rc"
assert_contains  "no-issue-body: skipped marker" "ISSUE_AC_COUNT=skipped" "$out"

# Test 6: issue AC section uses `## Requirements` header
pr_body='## AC mapping

| AC | Description | Test | Code | Commit |
|----|-------------|------|------|--------|
| AC-1 | x | t.go:T | c.go:1 | abc1234 |
| AC-2 | y | t.go:T | c.go:2 | abc1234 |
'
issue_body='## Requirements

- [ ] req one
- [ ] req two
'
verify_issue_ac "$(mk_pr_view "$pr_body" "$issue_body")" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "header-Requirements: exit 0" 0 "$rc"

# Test 7: issue AC items with `- [x]` (already checked) still count
pr_body='## AC mapping

| AC | Description | Test | Code | Commit |
|----|-------------|------|------|--------|
| AC-1 | x | t.go:T | c.go:1 | abc1234 |
| AC-2 | y | t.go:T | c.go:2 | abc1234 |
'
issue_body='## Acceptance criteria

- [x] already done
- [ ] still pending
'
verify_issue_ac "$(mk_pr_view "$pr_body" "$issue_body")" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "mixed-check-states: exit 0" 0 "$rc"

# Test 8: indented bullets in AC section are counted
pr_body='## AC mapping

| AC | Description | Test | Code | Commit |
|----|-------------|------|------|--------|
| AC-1 | x | t.go:T | c.go:1 | abc1234 |
| AC-2 | y | t.go:T | c.go:2 | abc1234 |
'
issue_body='## Acceptance criteria

- [ ] outer one
  - [ ] inner sub-item
'
out="$(verify_issue_ac "$(mk_pr_view "$pr_body" "$issue_body")" 2>/dev/null)" && rc=0 || rc=$?
assert_contains "indented-bullets: count both" "ISSUE_AC_COUNT=2" "$out"

# Test 9: malformed input → exit 64
verify_issue_ac "not json" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "malformed: exit 64" 64 "$rc"

# --- Multi-issue cases ----------------------------------------------------

# Helper: build a PR view with multiple linkedIssues
mk_multi() {
  # mk_multi <pr-body> <issue-body-A> <issue-body-B>
  jq -n --arg pb "$1" --arg ba "$2" --arg bb "$3" \
    '{number: 99, headRefOid: "h", body: $pb, commits:[{oid:"abc"}], files:[],
      linkedIssues: [{number: 100, body: $ba}, {number: 101, body: $bb}]}'
}

# Test 10: two linked issues, PR body covers both AC sets → pass
pr_body='## AC mapping

| AC | Description | Test | Code | Commit |
|----|-------------|------|------|--------|
| AC-1 | from issue A | t.go:T1 | c.go:1 | abc |
| AC-2 | from issue A | t.go:T2 | c.go:2 | abc |
| AC-3 | from issue B | t.go:T3 | c.go:3 | abc |
'
issue_a='## Acceptance criteria

- [ ] first item from A
- [ ] second item from A
'
issue_b='## Acceptance criteria

- [ ] only item from B
'
out="$(verify_issue_ac "$(mk_multi "$pr_body" "$issue_a" "$issue_b")" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "multi-issue-match: exit 0" 0 "$rc"
assert_contains  "multi-issue-match: total AC = 3" "ISSUE_AC_COUNT=3" "$out"
assert_contains  "multi-issue-match: ISSUE_COUNT=2" "ISSUE_COUNT=2" "$out"

# Test 11: two linked issues, PR body drops one item from issue B → fail
pr_body='## AC mapping

| AC | Description | Test | Code | Commit |
|----|-------------|------|------|--------|
| AC-1 | from A | t.go:T1 | c.go:1 | abc |
| AC-2 | from A | t.go:T2 | c.go:2 | abc |
'
issue_a='## Acceptance criteria

- [ ] first
- [ ] second
'
issue_b='## Acceptance criteria

- [ ] sole item
'
verify_issue_ac "$(mk_multi "$pr_body" "$issue_a" "$issue_b")" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "multi-issue-dropped: exit 1" 1 "$rc"
out="$(verify_issue_ac "$(mk_multi "$pr_body" "$issue_a" "$issue_b")" 2>/dev/null)"
assert_contains  "multi-issue-dropped: counts" "ISSUE_AC_COUNT=3" "$out"

# Test 12: backwards-compat — single linkedIssueBody (no linkedIssues array)
pr_body='## AC mapping

| AC | Description | Test | Code | Commit |
|----|-------------|------|------|--------|
| AC-1 | x | t.go:T | c.go:1 | abc |
'
issue_body='## Acceptance criteria

- [ ] one
'
back_compat="$(jq -n --arg pb "$pr_body" --arg ib "$issue_body" \
  '{number:99, headRefOid:"h", body:$pb, linkedIssueBody:$ib, commits:[{oid:"abc"}], files:[]}')"
verify_issue_ac "$back_compat" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "back-compat-single-issue: exit 0" 0 "$rc"

# Test 13: two linked issues, one has no AC section → only the other counts
issue_a='## Acceptance criteria

- [ ] from A
'
issue_b='## Summary

Just a description, no AC section.
'
pr_body='## AC mapping

| AC | Description | Test | Code | Commit |
|----|-------------|------|------|--------|
| AC-1 | x | t.go:T | c.go:1 | abc |
'
out="$(verify_issue_ac "$(mk_multi "$pr_body" "$issue_a" "$issue_b")" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "issue-without-AC-section: exit 0" 0 "$rc"
assert_contains  "issue-without-AC-section: total=1" "ISSUE_AC_COUNT=1" "$out"

test_summary
