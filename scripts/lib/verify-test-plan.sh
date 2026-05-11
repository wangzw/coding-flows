# verify_test_plan <pr-body>
#
# Asserts no unchecked Markdown checkboxes (`- [ ]`) remain in the PR
# body's `## Test plan` section. The template makes the Coder list manual
# verification steps; leaving them unchecked at merge time means the
# manual work wasn't done. This gate catches that.
#
# Rules:
#   - If no `## Test plan` section exists → pass (the section is opt-in;
#     PRs that don't need manual testing may omit it entirely).
#   - If section exists but contains no `- [ ]` / `- [x]` checkboxes →
#     pass (vacuous).
#   - If section exists and any line matches `^[[:space:]]*[-*][[:space:]]+\[ \]`
#     → fail, list the unchecked items.
#
# Output:
#   TEST_PLAN_UNCHECKED=<count>
#   (followed by `- ITEM` lines on stderr for each unchecked entry)
#
# Exit codes:
#   0 — clean.
#   1 — at least one unchecked checkbox.

# _extract_test_plan_section <body> — emit lines of the `## Test plan`
# section (until the next `## ` heading or EOF).
_extract_test_plan_section() {
  awk '
    BEGIN { in_sec=0 }
    /^##[[:space:]]/ {
      lc = tolower($0)
      if (lc ~ /^## *test[[:space:]]+plan([[:space:]]|$|\/)/) {
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

  # Find unchecked checkboxes. Markdown allows extra inner spaces but the
  # canonical form is `- [ ]`. Accept `-` or `*` bullets, any leading
  # whitespace, and a single space inside the brackets.
  local unchecked
  unchecked="$(printf '%s\n' "$section" | grep -E '^[[:space:]]*[-*][[:space:]]+\[ \]' || true)"

  if [[ -z "$unchecked" ]]; then
    printf 'TEST_PLAN_UNCHECKED=0\n'
    return 0
  fi

  local count
  count="$(printf '%s\n' "$unchecked" | wc -l | tr -d ' ')"
  printf 'TEST_PLAN_UNCHECKED=%s\n' "$count"
  log_error "test-plan: $count unchecked checkbox(es) in '## Test plan':"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    log_error "  $line"
  done <<< "$unchecked"
  return 1
}
