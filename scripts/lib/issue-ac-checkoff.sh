# check_off_ac_items <issue-body>
#
# Pure function: take an issue body, return the body with every `- [ ]`
# (and `* [ ]`) bullet under the `## Acceptance criteria` /
# `## Requirements` / `## ACs` section flipped to `- [x]`. Bullets
# outside the AC section are left alone, and bullets that are already
# `- [x]` or have non-checkbox content are not touched.
#
# Used by coding-flows-merge after a successful `gh pr merge` to mark
# the linked issue's AC items as completed.
check_off_ac_items() {
  local body="$1"
  awk '
    BEGIN { in_sec=0 }
    /^##[[:space:]]/ {
      lc = tolower($0)
      if (lc ~ /^## *(acceptance[[:space:]]+criteria|acs|requirements)([^[:alnum:]_]|$)/) {
        in_sec=1; print; next
      }
      if (in_sec) { in_sec=0 }
    }
    {
      if (in_sec && $0 ~ /^[[:space:]]*[-*][[:space:]]+\[ \]/) {
        sub(/\[ \]/, "[x]")
      }
      print
    }
  ' <<<"$body"
}
