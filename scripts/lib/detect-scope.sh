# detect_scope <newline-separated-paths> [<config-path>]
#
# Reads scope_rules from .coding-flows.json. For each rule whose `paths` glob list
# matches at least one path in the input, emits a line:
#
#   RULE_<index> skills=<csv-or-"-"> standards=<csv-or-"-">
#
# Exit codes:
#   0 — always (no matches → empty output).
#  65 — config malformed.

detect_scope() {
  local files_input="$1"
  local config_path="${2:-}"

  if [[ -z "$config_path" ]]; then
    config_path="$(find_repo_config || true)"
  fi
  if [[ -z "$config_path" || ! -f "$config_path" ]]; then
    return 0
  fi

  if ! jq empty "$config_path" 2>/dev/null; then
    log_error "detect-scope: $config_path is not valid JSON"
    return 65
  fi

  local rules_count
  rules_count="$(jq -r '(.scope_rules // []) | length' "$config_path")"
  if [[ "$rules_count" -eq 0 ]]; then
    return 0
  fi

  local i=0
  while [[ $i -lt $rules_count ]]; do
    local rule
    rule="$(jq -c ".scope_rules[$i]" "$config_path")"
    local patterns
    patterns="$(jq -r '.paths[]? // empty' <<<"$rule")"

    local matched=0
    local pattern file
    while IFS= read -r pattern; do
      [[ -z "$pattern" ]] && continue
      while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        if glob_match "$pattern" "$file"; then
          matched=1
          break 2
        fi
      done <<< "$files_input"
    done <<< "$patterns"

    if [[ $matched -eq 1 ]]; then
      local skills standards
      skills="$(jq -r '[.skills[]? // empty] | join(",")' <<<"$rule")"
      standards="$(jq -r '[.standards[]? // empty] | join(",")' <<<"$rule")"
      [[ -z "$skills"    ]] && skills="-"
      [[ -z "$standards" ]] && standards="-"
      printf 'RULE_%d skills=%s standards=%s\n' "$i" "$skills" "$standards"
    fi
    i=$((i + 1))
  done
  return 0
}
