#!/usr/bin/env bash
# Tests for scripts/lib/verify-test-plan.sh.
set -uo pipefail

TEST_FILE="test_verify_test_plan.sh"
TEST_PASS=0
TEST_FAIL=0

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$THIS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$THIS_DIR/lib/assert.sh"
# shellcheck source=../scripts/lib/common.sh
source "$SKILL_DIR/scripts/lib/common.sh"
# shellcheck source=../scripts/lib/verify-test-plan.sh
source "$SKILL_DIR/scripts/lib/verify-test-plan.sh"

# Test 1: no Test plan section → pass (opt-in)
body='## Summary

Closes #1.

## AC mapping

| AC | x | t.go | c.go | abc |
'
out="$(verify_test_plan "$body" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "no-section: exit 0" 0 "$rc"
assert_contains  "no-section: count 0" "TEST_PLAN_UNCHECKED=0" "$out"

# Test 2: section present, all items checked → pass
body='## Test plan

- [x] ran make test, all green
- [x] manual smoke: open dialog → close → no console warnings
'
out="$(verify_test_plan "$body" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "all-checked: exit 0" 0 "$rc"
assert_contains  "all-checked: count 0" "TEST_PLAN_UNCHECKED=0" "$out"

# Test 3: section present with empty items / no checkboxes → pass (vacuous)
body='## Test plan

CI handles everything; no manual verification needed.
'
out="$(verify_test_plan "$body" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "no-checkboxes: exit 0" 0 "$rc"

# Test 4: one unchecked item → fail
body='## Test plan

- [x] ran make test
- [ ] manual: VoiceOver pass
'
verify_test_plan "$body" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "one-unchecked: exit 1" 1 "$rc"
out="$(verify_test_plan "$body" 2>/dev/null)"
assert_contains  "one-unchecked: count 1" "TEST_PLAN_UNCHECKED=1" "$out"

# Test 5: multiple unchecked → fail with correct count
body='## Test plan

- [x] ran make test
- [ ] manual: VoiceOver pass
- [ ] manual: focus management on close
- [ ] manual: stacked-modal interaction
'
out="$(verify_test_plan "$body" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "three-unchecked: exit 1" 1 "$rc"
assert_contains  "three-unchecked: count 3" "TEST_PLAN_UNCHECKED=3" "$out"

# Test 6: indented checkboxes are still caught
body='## Test plan

- [x] outer thing
  - [ ] inner sub-item still unchecked
'
verify_test_plan "$body" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "indented-unchecked: exit 1" 1 "$rc"

# Test 7: bullet style `*` is also recognized
body='## Test plan

* [x] item one
* [ ] item two
'
verify_test_plan "$body" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "asterisk-bullet: exit 1" 1 "$rc"

# Test 8: unchecked checkboxes outside Test plan are ignored
body='## Other section

- [ ] something else

## Test plan

- [x] real check
'
out="$(verify_test_plan "$body" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "other-section-ignored: exit 0" 0 "$rc"

# Test 9: case-insensitive header
body='## Test Plan

- [x] only thing
'
verify_test_plan "$body" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "case-insensitive-header: exit 0" 0 "$rc"

# Test 10: section ends at the next `## ` heading; checkboxes after don't count
body='## Test plan

- [x] real
- [x] also real

## Risks

- [ ] this looks like an unchecked item but is in Risks
'
verify_test_plan "$body" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "section-boundary: exit 0" 0 "$rc"

# Test 11a: header variants — all should be recognized as the section
for header in \
  '## Test plan' \
  '## Test Plan' \
  '## Test plan / rollout' \
  '## Test plan: smoke + manual' \
  '## Test plan.' ; do
  body="$header"$'\n\n- [ ] one unchecked item\n'
  verify_test_plan "$body" >/dev/null 2>&1 && rc=0 || rc=$?
  assert_exit_code "header variant '$header' recognized → fail" 1 "$rc"
done

# Test 11b: looks-like-Test-plan but isn't (should NOT be recognized)
for header in \
  '## Test plans (plural)' \
  '## Test planning' \
  '## Testplan' ; do
  body="$header"$'\n\n- [ ] would be unchecked if section matched\n'
  verify_test_plan "$body" >/dev/null 2>&1 && rc=0 || rc=$?
  assert_exit_code "header variant '$header' NOT recognized → pass" 0 "$rc"
done

# Test 11c: the actual failure mode that motivated this gate — PR #253
# pattern: many checked + a few unchecked manual verification items.
body='## Test plan

- [x] `npm run typecheck` clean.
- [x] `npx vitest run src/components/AppDialog.test.tsx` — 2/2 green.
- [ ] Manual: `make dev` → open dialog → no console warnings.
- [ ] Manual: VoiceOver pass after dialog close.
- [ ] Manual: Tab after dialog close — focus lands on trigger button.
'
out="$(verify_test_plan "$body" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "real-pr-pattern: exit 1" 1 "$rc"
assert_contains  "real-pr-pattern: count 3" "TEST_PLAN_UNCHECKED=3" "$out"

# Test 12: gaming the gate — Coder strips the [ ] checkbox entirely,
# leaving a plain bullet. Real bug observed on a PR. Must be flagged.
body='## Test plan

- [x] ran make test
- Manual: `make dev` → no console warnings
- Manual: VoiceOver pass
'
out="$(verify_test_plan "$body" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "stripped-checkbox: exit 1" 1 "$rc"
assert_contains  "stripped-checkbox: count 2" "TEST_PLAN_UNCHECKED=2" "$out"

# Test 13: Coder writes [.] / [?] / weird checkbox content → unchecked
body='## Test plan

- [x] real
- [.] dot — not a check
- [?] question mark
- [ X] leading space inside brackets
- [X ] trailing space inside brackets
'
out="$(verify_test_plan "$body" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "weird-checkbox: exit 1" 1 "$rc"
assert_contains  "weird-checkbox: 4 unchecked" "TEST_PLAN_UNCHECKED=4" "$out"

# Test 14: [X] (capital) is valid
body='## Test plan

- [X] capital is fine
- [x] lowercase too
'
verify_test_plan "$body" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "capital-X: exit 0" 0 "$rc"

# Test 15: bullet immediately followed by [x] but no space after → still
# unchecked-looking. The regex requires a space (or EOL) after the bracket.
body='## Test plan

- [x]something glued
'
# This is `- [x]something` — the [x] has no separator. Treat as unchecked
# (real check entries always have a space after [x]).
verify_test_plan "$body" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "no-space-after-bracket: exit 1" 1 "$rc"

# Test 16: bullets mixed with prose — prose ignored, bullets enforced
body='## Test plan

This PR is mostly automated; manual sanity checks:

- [x] confirmed dialog opens
- confirmed dialog closes  (← gaming the gate)
'
verify_test_plan "$body" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "prose+gamed-bullet: exit 1" 1 "$rc"

test_summary
