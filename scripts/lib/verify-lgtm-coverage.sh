# verify_lgtm_coverage <pr-view-json>
#
# Composes:
#   - check_lgtm  → claimed acs=, invariants=, risks-reviewed= from LGTM markers
#   - verify_ac_mapping → AC IDs the Coder claimed in the PR body
#   - triggered_invariants → invariant IDs the diff currently triggers
#   - verify_risks → risk categories the Coder declared in the PR body
#
# Then asserts:
#   - LGTM_ACS ⊇ AC mapping IDs (every claimed AC has at least one LGTM that
#     names it).
#   - LGTM_INVARIANTS ⊇ triggered invariants (every triggered invariant is
#     claimed verified by at least one LGTM).
#   - LGTM_RISKS_REVIEWED ⊇ declared risk categories (every Coder-declared
#     non-"none" risk category is claimed reviewed by at least one LGTM).
#     If the Coder declared "none" / no categories, the LGTM has nothing to
#     cover on that axis.
#
# Output (stdout, KEY=VALUE):
#   COVERAGE_MISSING_ACS=<csv>
#   COVERAGE_MISSING_INVARIANTS=<csv>
#   COVERAGE_MISSING_RISKS=<csv>
#
# Exit codes:
#   0 — coverage complete.
#   1 — coverage gap (missing AC, invariant, or risks-reviewed category).
#   2 — prerequisite failed (no current LGTM, AC mapping or Risks invalid).
#  64 — input JSON malformed.

verify_lgtm_coverage() {
  local json_view="$1"

  # 1. Run check_lgtm — it does its own head-SHA check.
  local lgtm_out lgtm_rc=0
  lgtm_out="$(check_lgtm "$json_view")" || lgtm_rc=$?
  if [[ $lgtm_rc -ne 0 ]]; then
    log_error "lgtm-coverage: no current LGTM (check_lgtm exit $lgtm_rc)"
    return 2
  fi
  local claimed_acs claimed_invariants claimed_risks
  claimed_acs="$(_extract_kv "$lgtm_out" LGTM_ACS)"
  claimed_invariants="$(_extract_kv "$lgtm_out" LGTM_INVARIANTS)"
  claimed_risks="$(_extract_kv "$lgtm_out" LGTM_RISKS_REVIEWED)"

  # 2. Get AC IDs from the PR body's AC mapping table.
  local body
  body="$(jq -r '.body // ""' <<<"$json_view")"
  local acmap_out acmap_rc=0
  acmap_out="$(verify_ac_mapping "$body" "$json_view")" || acmap_rc=$?
  if [[ $acmap_rc -ne 0 ]]; then
    log_error "lgtm-coverage: AC mapping invalid; cannot compute coverage"
    return 2
  fi
  local mapping_acs
  mapping_acs="$(_extract_kv "$acmap_out" AC_IDS)"

  # 3. Compute triggered invariants from current diff.
  local files
  files="$(extract_changed_files "$json_view")"
  local triggered
  triggered="$(triggered_invariants "$files" | paste -sd, -)"

  # 4. Risk categories declared in PR body (none if Risks section absent —
  # in that case treat as empty; coding-flows-merge's separate Gate 9 surfaces
  # the missing Risks section.)
  local declared_risks=""
  if grep -iqE '^## *risks([[:space:]]|$)' <<<"$body"; then
    local risks_out risks_rc=0
    risks_out="$(verify_risks "$body" 2>/dev/null)" || risks_rc=$?
    if [[ $risks_rc -eq 0 ]]; then
      declared_risks="$(_extract_kv "$risks_out" RISKS_CATEGORIES)"
    fi
  fi

  # 5. Diff sets.
  local missing_acs missing_invs missing_risks
  missing_acs="$(_csv_diff "$mapping_acs" "$claimed_acs")"
  missing_invs="$(_csv_diff "$triggered" "$claimed_invariants")"
  missing_risks="$(_csv_diff "$declared_risks" "$claimed_risks")"

  printf 'COVERAGE_MISSING_ACS=%s\nCOVERAGE_MISSING_INVARIANTS=%s\nCOVERAGE_MISSING_RISKS=%s\n' \
    "$missing_acs" "$missing_invs" "$missing_risks"

  if [[ -n "$missing_acs" || -n "$missing_invs" || -n "$missing_risks" ]]; then
    [[ -n "$missing_acs" ]]   && log_error "lgtm-coverage: AC IDs not claimed by any LGTM: $missing_acs"
    [[ -n "$missing_invs" ]]  && log_error "lgtm-coverage: triggered invariants not claimed: $missing_invs"
    [[ -n "$missing_risks" ]] && log_error "lgtm-coverage: declared risk categories not reviewed: $missing_risks"
    return 1
  fi
  return 0
}

# _extract_kv <KEY=VALUE\n...> <KEY> — extract a value from KEY=VALUE output.
_extract_kv() {
  local block="$1" key="$2"
  grep -E "^${key}=" <<<"$block" | head -n1 | sed -E "s/^${key}=//"
}

# _csv_diff <expected-csv> <actual-csv> — emit CSV of expected items missing
# from actual.
_csv_diff() {
  local expected="$1" actual="$2"
  [[ -z "$expected" ]] && return 0
  local IFS=','
  local -a exp_arr=($expected)
  local missing=""
  local item
  for item in "${exp_arr[@]}"; do
    [[ -z "$item" ]] && continue
    if [[ ",$actual," != *",$item,"* ]]; then
      if [[ -z "$missing" ]]; then
        missing="$item"
      else
        missing="$missing,$item"
      fi
    fi
  done
  printf '%s' "$missing"
}
