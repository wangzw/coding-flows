#!/usr/bin/env bash
# Tests for scripts/lib/issue-ac-checkoff.sh — the awk function that
# flips `- [ ]` to `- [x]` only within the AC section of an issue body.
set -uo pipefail

TEST_FILE="test_issue_ac_checkoff.sh"
TEST_PASS=0
TEST_FAIL=0

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$THIS_DIR/.." && pwd)"

source "$THIS_DIR/lib/assert.sh"
source "$SKILL_DIR/scripts/lib/issue-ac-checkoff.sh"

# Test 1: basic flip — all unchecked items get marked
body='## Acceptance criteria

- [ ] first item
- [ ] second item
- [ ] third item
'
out="$(check_off_ac_items "$body")"
checked_count="$(printf '%s\n' "$out" | grep -cE '^- \[x\]')"
unchecked_count="$(printf '%s\n' "$out" | grep -cE '^- \[ \]')"
assert_eq "all-unchecked: 3 checked"   "3" "$checked_count"
assert_eq "all-unchecked: 0 unchecked" "0" "$unchecked_count"

# Test 2: bullets outside the AC section are NOT touched
body='## Summary

- [ ] this bullet is in Summary, MUST stay unchecked

## Acceptance criteria

- [ ] this one gets checked

## Notes

- [ ] this one also stays unchecked
'
out="$(check_off_ac_items "$body")"
# Use flag-based section scoping (awk's range operator goes false on the
# start line itself when start regex also matches end regex — `## Foo`
# matches `^## `, so a naive range would only cover the start line).
in_summary="$(awk '/^## Summary/{f=1; next} /^## /{f=0} f && /^- \[x\]/{c++} END{print c+0}' <<<"$out")"
in_notes="$(awk '/^## Notes/{f=1; next} /^## /{f=0} f && /^- \[x\]/{c++} END{print c+0}' <<<"$out")"
in_ac="$(awk '/^## Acceptance criteria/{f=1; next} /^## /{f=0} f && /^- \[x\]/{c++} END{print c+0}' <<<"$out")"
assert_eq "scoped: Summary untouched" "0" "$in_summary"
assert_eq "scoped: Notes untouched"   "0" "$in_notes"
assert_eq "scoped: AC flipped"        "1" "$in_ac"

# Test 3: mixed - [x] and - [ ] in AC section — only unchecked flip
body='## Acceptance criteria

- [x] already done
- [ ] needs flip
- [x] also done
- [ ] another flip
'
out="$(check_off_ac_items "$body")"
checked_count="$(printf '%s\n' "$out" | grep -cE '^- \[x\]')"
unchecked_count="$(printf '%s\n' "$out" | grep -cE '^- \[ \]')"
assert_eq "mixed: all 4 checked now" "4" "$checked_count"
assert_eq "mixed: 0 unchecked left"  "0" "$unchecked_count"

# Test 4: idempotent — applying twice gives the same result
body='## Acceptance criteria

- [ ] one
- [ ] two
'
once="$(check_off_ac_items "$body")"
twice="$(check_off_ac_items "$once")"
assert_eq "idempotent" "$once" "$twice"

# Test 5: no AC section → body unchanged (compare with trailing newlines
# trimmed because `$(...)` strips them)
body='## Summary

Just a description.

- [ ] this stays unchecked (not in AC section)
'
out="$(check_off_ac_items "$body")"
body_trimmed="${body%$'\n'}"
assert_eq "no-ac-section: unchanged" "$body_trimmed" "$out"

# Test 6: `## Requirements` header also works
body='## Requirements

- [ ] requirement one
- [ ] requirement two
'
out="$(check_off_ac_items "$body")"
checked_count="$(printf '%s\n' "$out" | grep -cE '^- \[x\]')"
assert_eq "Requirements header: flipped" "2" "$checked_count"

# Test 7: case-insensitive header
body='## ACS

- [ ] one
'
out="$(check_off_ac_items "$body")"
checked_count="$(printf '%s\n' "$out" | grep -cE '^- \[x\]')"
assert_eq "case-insensitive AC header" "1" "$checked_count"

# Test 8: `[ ]` in prose (not at bullet start) is NOT modified
body='## Acceptance criteria

The text [ ] here should stay literal.

- [ ] the actual bullet
'
out="$(check_off_ac_items "$body")"
# The prose `[ ]` should NOT be touched (only matched as part of a bullet)
in_prose="$(printf '%s\n' "$out" | grep -c '\[ \] here')"
in_bullet="$(printf '%s\n' "$out" | grep -cE '^- \[x\]')"
assert_eq "prose [ ] untouched" "1" "$in_prose"
assert_eq "bullet [ ] flipped"  "1" "$in_bullet"

# Test 9: asterisk bullets `* [ ]` also work
body='## Acceptance criteria

* [ ] asterisk bullet one
* [ ] asterisk bullet two
'
out="$(check_off_ac_items "$body")"
flipped="$(printf '%s\n' "$out" | grep -cE '^\* \[x\]')"
assert_eq "asterisk bullets flipped" "2" "$flipped"

# Test 10: indented bullets `  - [ ]` also flip
body='## Acceptance criteria

- [ ] outer
  - [ ] nested
'
out="$(check_off_ac_items "$body")"
flipped="$(printf '%s\n' "$out" | grep -cE '^[[:space:]]*[-*] \[x\]')"
assert_eq "indented bullets flipped" "2" "$flipped"

test_summary
