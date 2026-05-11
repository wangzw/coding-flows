# verify_test_plan <pr-body>
#
# Asserts every bullet in the PR body's `## Test plan` section is an
# explicit checked checkbox (`- [x]`). Anything else — `- [ ]`, `- [.]`,
# `- [?]`, a plain bullet `- foo` with no checkbox at all — counts as
# unchecked. The Coder must either:
#   - run the manual verification and mark `- [x]`, OR
#   - remove the entire bullet line (don't strip just the `[ ]` checkbox
#     marker to slip past the gate).
#
# Rules:
#   - If no `## Test plan` section exists → pass (opt-in; PRs that
#     don't need manual testing may omit the section entirely).
#   - If section exists but contains no bullet lines at all (only prose)
#     → pass (vacuous).
#   - If section exists and any bullet line is NOT `- [x]` / `* [X]` →
#     fail, list the offending lines.
#
# Output:
#   TEST_PLAN_UNCHECKED=<count>
#   (followed by `- ITEM` lines on stderr for each non-checked bullet)
#
# Exit codes:
#   0 — clean.
#   1 — at least one non-checked bullet.

# _extract_test_plan_section <body> — emit lines of the `## Test plan`
# section (until the next `## ` heading or EOF).
#
# Header match is lenient on the suffix: anything non-alphanumeric or EOL
# after `plan` counts as the boundary. So `## Test plan`, `## Test plan: …`,
# `## Test plan / rollout`, `## Test plan.` all match. Doesn't match
# `## Test plans`, `## Test planning`, etc. (the trailing char must not be
# a word char).
#
# Known limitation: doesn't track Markdown fenced code blocks. A literal
# `- [ ]` inside a ```fenced ... ``` block within `## Test plan` would
# be treated as an unchecked item. Real test plans use prose for items,
# not code samples, so this is documented rather than worked around.
_extract_test_plan_section() {
  awk '
    BEGIN { in_sec=0 }
    /^##[[:space:]]/ {
      lc = tolower($0)
      if (lc ~ /^## *test[[:space:]]+plan([^[:alnum:]_]|$)/) {
        in_sec = 1
        next
      }
      if (in_sec) { in_sec = 0 }
    }
    in_sec { print }
  '
}

verify_test_plan() {
  local body="$1"

  local section
  section="$(_extract_test_plan_section <<<"$body")"
  if [[ -z "$section" ]]; then
    printf 'TEST_PLAN_UNCHECKED=0\n'
    return 0
  fi

  # Find every bullet line, then filter out those that are explicitly
  # checked (`- [x]` / `* [X]`). The remainder is unchecked — covers
  # `- [ ]`, `- [.]`, `- [?]`, `- foo` with no checkbox, etc.
  local all_bullets unchecked
  all_bullets="$(printf '%s\n' "$section" | grep -E '^[[:space:]]*[-*][[:space:]]+' || true)"
  if [[ -z "$all_bullets" ]]; then
    printf 'TEST_PLAN_UNCHECKED=0\n'
    return 0
  fi
  unchecked="$(printf '%s\n' "$all_bullets" | grep -vE '^[[:space:]]*[-*][[:space:]]+\[[xX]\]([[:space:]]|$)' || true)"

  if [[ -z "$unchecked" ]]; then
    printf 'TEST_PLAN_UNCHECKED=0\n'
    return 0
  fi

  local count
  count="$(printf '%s\n' "$unchecked" | wc -l | tr -d ' ')"
  printf 'TEST_PLAN_UNCHECKED=%s\n' "$count"
  log_error "test-plan: $count non-checked bullet(s) in '## Test plan' (must be '- [x]' or removed entirely):"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    log_error "  $line"
  done <<< "$unchecked"
  return 1
}
