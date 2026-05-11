# verify_issue_ac <pr-view-json>
#
# Asserts the PR body's `## AC mapping` table covers every Acceptance
# Criterion bullet across **all** linked issues (the PR may close
# multiple: `Closes #A`, `Fixes #B`, `Resolves #C` are all aggregated).
# Without this, the Coder can silently drop AC items (write an N-row
# table when the linked issues declared N+M items in total) and the
# Reviewer — who only reads the PR body — never catches it.
#
# Comparison is row count (PR side) vs. summed AC bullet count across
# all linked issues. Strict equality is too tight (Coder may legitimately
# split one issue AC into multiple PR rows or add derived ACs). The
# rule is: PR mapping row count **≥** total issue AC bullet count.
#
# Linked issue bodies must be present on `.linkedIssues[]` of the
# PR-view JSON as `{number, body}` objects. `load_pr_view` attaches
# them automatically in live mode. For backwards-compat with
# `--from-file` fixtures that set `.linkedIssueBody` (single-issue
# shape), this function falls back to that field. If neither is
# available, the gate emits a warning and passes (test mode without
# gh access).
#
# Output:
#   ISSUE_AC_COUNT=<int>
#   PR_AC_COUNT=<int>
#   ISSUE_COUNT=<n>          (number of linked issues counted)
#
# Exit codes:
#   0 — counts OK (or no linked issue bodies available).
#   1 — PR mapping has fewer rows than total issue ACs.

# _extract_issue_ac_items <issue-body> — emit one line per AC bullet
# under `## Acceptance criteria` / `## Acceptance Criteria` / `## ACs`
# / `## Requirements`. Accepts `- [ ]` / `- [x]` and plain `-` bullets.
_extract_issue_ac_items() {
  awk '
    BEGIN { in_sec=0 }
    /^##[[:space:]]/ {
      lc = tolower($0)
      if (lc ~ /^## *(acceptance[[:space:]]+criteria|acs|requirements)([^[:alnum:]_]|$)/) {
        in_sec=1; next
      }
      if (in_sec) { in_sec=0 }
    }
    in_sec && /^[[:space:]]*[-*][[:space:]]+/ { print }
  '
}

verify_issue_ac() {
  local json="$1"

  if ! jq empty <<<"$json" 2>/dev/null; then
    log_error "verify-issue-ac: input not valid JSON"
    return 64
  fi

  # Resolve linked issue bodies. Preferred shape:
  #   .linkedIssues = [{number, body}, ...]
  # Backwards-compat: .linkedIssueBody (single string) — wraps into a
  # 1-element list.
  local linked_count
  linked_count="$(jq -r '(.linkedIssues // []) | length' <<<"$json")"
  if [[ "$linked_count" -eq 0 ]]; then
    local back_compat
    back_compat="$(jq -r '.linkedIssueBody // ""' <<<"$json" 2>/dev/null || true)"
    if [[ -z "$back_compat" ]]; then
      log_warn "verify-issue-ac: no linkedIssues on PR view; skipping parity check"
      printf 'ISSUE_AC_COUNT=skipped\nPR_AC_COUNT=skipped\nISSUE_COUNT=0\n'
      return 0
    fi
    linked_count=1
  fi

  # Sum AC items across all linked issues. Build a per-issue breakdown
  # for the error message.
  local issue_count=0
  local -a issue_summary=()
  local i=0
  while [[ $i -lt $linked_count ]]; do
    local n body items per
    n="$(jq -r ".linkedIssues[$i].number // .linkedIssueNumber // \"?\"" <<<"$json")"
    body="$(jq -r ".linkedIssues[$i].body // .linkedIssueBody // \"\"" <<<"$json")"
    items="$(_extract_issue_ac_items <<<"$body")"
    if [[ -z "$items" ]]; then
      per=0
    else
      per="$(printf '%s\n' "$items" | wc -l | tr -d ' ')"
    fi
    issue_count=$((issue_count + per))
    issue_summary+=("#$n: $per AC item(s)")
    i=$((i + 1))
  done

  # Count PR body AC mapping rows. Reuse verify_ac_mapping's AC_ROWS
  # output if available; otherwise extract directly.
  local body pr_count=0
  body="$(jq -r '.body // ""' <<<"$json")"
  local acmap_out
  if acmap_out="$(verify_ac_mapping "$body" "$json" 2>/dev/null)"; then
    pr_count="$(grep -E '^AC_ROWS=' <<<"$acmap_out" | head -n1 | cut -d= -f2)"
    pr_count="${pr_count:-0}"
  fi

  printf 'ISSUE_AC_COUNT=%d\nPR_AC_COUNT=%d\nISSUE_COUNT=%d\n' \
    "$issue_count" "$pr_count" "$linked_count"

  if [[ "$pr_count" -lt "$issue_count" ]]; then
    log_error "verify-issue-ac: PR body AC mapping has $pr_count row(s) but $linked_count linked issue(s) declare $issue_count AC item(s) in total — Coder dropped or missed item(s):"
    local s
    for s in "${issue_summary[@]}"; do
      log_error "  $s"
    done
    # Print every issue's items for context
    i=0
    while [[ $i -lt $linked_count ]]; do
      local n body items
      n="$(jq -r ".linkedIssues[$i].number // .linkedIssueNumber // \"?\"" <<<"$json")"
      body="$(jq -r ".linkedIssues[$i].body // .linkedIssueBody // \"\"" <<<"$json")"
      items="$(_extract_issue_ac_items <<<"$body")"
      local idx=0 item
      while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        idx=$((idx + 1))
        log_error "  issue #$n AC $idx: $item"
      done <<< "$items"
      i=$((i + 1))
    done
    return 1
  fi
  return 0
}
