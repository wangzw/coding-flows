# show_coverage <pr-view-json>
#
# Compute exactly what the Reviewer's /lgtm marker must claim for Gate 4
# (lgtm-coverage) to pass. Output three values the Reviewer can copy
# directly into the marker:
#
#   EXPECTED_ACS=<csv>           — AC IDs from the PR body's AC mapping table
#   EXPECTED_INVARIANTS=<csv>    — invariant IDs triggered by the diff (from
#                                 .coding-flows.json `invariants[].triggered_by_paths`)
#   EXPECTED_RISKS_REVIEWED=<csv>— non-`none` categories from the PR body's
#                                 `<!-- coding-flows:risks categories=... -->`
#                                 marker — these are enum values, not custom
#                                 prose labels
#
# This exists because Reviewer agents have been observed writing descriptive
# labels (e.g. `risks-reviewed=stacked-modals,future-mui-version`) instead
# of the canonical enum categories the Coder declared. The merge gate
# correctly blocks but doesn't tell the Reviewer the *expected* value —
# this script does.
#
# Exit codes:
#   0 — coverage values emitted.
#  64 — input JSON malformed.

show_coverage() {
  local json="$1"

  if ! jq empty <<<"$json" 2>/dev/null; then
    log_error "show_coverage: input not valid JSON"
    return 64
  fi

  local body
  body="$(jq -r '.body // ""' <<<"$json")"

  # AC IDs — reuse verify_ac_mapping
  local acmap_out acs=""
  if acmap_out="$(verify_ac_mapping "$body" "$json" 2>/dev/null)"; then
    acs="$(grep -E '^AC_IDS=' <<<"$acmap_out" | head -n1 | cut -d= -f2-)"
  fi

  # Triggered invariants — from changed files + config
  local files invariants
  files="$(extract_changed_files "$json")"
  invariants="$(triggered_invariants "$files" | paste -sd, -)"

  # Risk categories from the PR body's marker. Use verify_risks for
  # validation; on parse failure (e.g. malformed PR), fall back to the
  # raw marker if present.
  local risks=""
  if grep -iqE '^## *risks([[:space:]]|$)' <<<"$body"; then
    local risks_out
    if risks_out="$(verify_risks "$body" 2>/dev/null)"; then
      risks="$(grep -E '^RISKS_CATEGORIES=' <<<"$risks_out" | head -n1 | cut -d= -f2-)"
    fi
  fi

  printf 'EXPECTED_ACS=%s\nEXPECTED_INVARIANTS=%s\nEXPECTED_RISKS_REVIEWED=%s\n' \
    "$acs" "$invariants" "$risks"

  # Also surface every linked issue's AC items so the Reviewer can see
  # *what* they're agreeing to. The Coder's PR body AC mapping must
  # cover every one of these in total (Gate 12 enforces count parity).
  local linked_count
  linked_count="$(jq -r '(.linkedIssues // []) | length' <<<"$json")"
  local printed_header=0

  if [[ "$linked_count" -gt 0 ]]; then
    local i=0
    while [[ $i -lt $linked_count ]]; do
      local n body items
      n="$(jq -r ".linkedIssues[$i].number // \"?\"" <<<"$json")"
      body="$(jq -r ".linkedIssues[$i].body // \"\"" <<<"$json")"
      items="$(_extract_issue_ac_items <<<"$body" 2>/dev/null || true)"
      if [[ -n "$items" ]]; then
        if [[ $printed_header -eq 0 ]]; then
          printf '\n--- Linked issue AC items (Reviewer must audit against these) ---\n'
          printed_header=1
        fi
        printf '\nIssue #%s:\n%s\n' "$n" "$items"
      fi
      i=$((i + 1))
    done
  else
    # Backwards-compat: single linkedIssueBody field.
    local linked_body
    linked_body="$(jq -r '.linkedIssueBody // ""' <<<"$json" 2>/dev/null || true)"
    if [[ -n "$linked_body" ]]; then
      local items
      items="$(_extract_issue_ac_items <<<"$linked_body" 2>/dev/null || true)"
      if [[ -n "$items" ]]; then
        printf '\n--- Linked issue AC items (Reviewer must audit against these) ---\n%s\n' "$items"
        printed_header=1
      fi
    fi
  fi

  if [[ $printed_header -eq 1 ]]; then
    printf '\nReview against the issue text above, NOT just the PR body table.\n'
  fi
}
