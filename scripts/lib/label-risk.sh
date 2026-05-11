# detect_high_risk_labels <files-newline> <total-lines> <existing-labels-csv> [<config-path>]
#
# Evaluates `high_risk_rules` from .coding-flows.json against:
#   - the changed file list
#   - the total lines changed
#   - existing labels on the PR
#
# Emits one label per line for each triggered rule. Caller decides whether to
# actually apply the labels (the CLI wrapper does it; tests just read stdout).
#
# Exit codes:
#   0 — always (no rules / no match → empty).
#  65 — config malformed.

detect_high_risk_labels() {
  local files_input="$1"
  local total_lines="${2:-0}"
  local existing_labels="${3:-}"
  local config_path="${4:-}"

  if [[ -z "$config_path" ]]; then
    config_path="$(find_repo_config || true)"
  fi
  if [[ -z "$config_path" || ! -f "$config_path" ]]; then
    return 0
  fi

  if ! jq empty "$config_path" 2>/dev/null; then
    log_error "label-risk: $config_path is not valid JSON"
    return 65
  fi

  local rules_count
  rules_count="$(jq -r '(.high_risk_rules // []) | length' "$config_path")"
  if [[ "$rules_count" -eq 0 ]]; then
    return 0
  fi

  local i=0
  while [[ $i -lt $rules_count ]]; do
    local rule
    rule="$(jq -c ".high_risk_rules[$i]" "$config_path")"

    # exclude_labels — if any matches an existing label, skip this rule.
    local excl_labels
    excl_labels="$(jq -r '.exclude_labels[]? // empty' <<<"$rule")"
    local rule_excluded=0
    local el
    while IFS= read -r el; do
      [[ -z "$el" ]] && continue
      if [[ ",$existing_labels," == *",$el,"* ]]; then
        rule_excluded=1
        break
      fi
    done <<< "$excl_labels"

    if [[ $rule_excluded -eq 1 ]]; then
      i=$((i + 1)); continue
    fi

    local label
    label="$(jq -r '.label // empty' <<<"$rule")"
    if [[ -z "$label" ]]; then
      i=$((i + 1)); continue
    fi

    local matched=0

    # Size check
    local size_threshold
    size_threshold="$(jq -r '.size.lines_changed // empty' <<<"$rule")"
    if [[ -n "$size_threshold" ]]; then
      if (( total_lines >= size_threshold )); then
        matched=1
      fi
    fi

    # Paths check (if not yet matched by size)
    if [[ $matched -eq 0 ]]; then
      local incl_paths excl_paths
      incl_paths="$(jq -r '.paths[]? // empty' <<<"$rule")"
      excl_paths="$(jq -r '.exclude_paths[]? // empty' <<<"$rule")"

      if [[ -n "$incl_paths" ]]; then
        local file pattern
        while IFS= read -r file; do
          [[ -z "$file" ]] && continue
          # exclude_paths takes priority
          local is_excl=0 epat
          while IFS= read -r epat; do
            [[ -z "$epat" ]] && continue
            if glob_match "$epat" "$file"; then
              is_excl=1; break
            fi
          done <<< "$excl_paths"
          [[ $is_excl -eq 1 ]] && continue
          while IFS= read -r pattern; do
            [[ -z "$pattern" ]] && continue
            if glob_match "$pattern" "$file"; then
              matched=1
              break 2
            fi
          done <<< "$incl_paths"
        done <<< "$files_input"
      fi
    fi

    if [[ $matched -eq 1 ]]; then
      printf '%s\n' "$label"
    fi
    i=$((i + 1))
  done
  return 0
}
