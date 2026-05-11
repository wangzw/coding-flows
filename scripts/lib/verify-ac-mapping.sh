# verify_ac_mapping <pr-body> [<pr-view-json>]
#
# Validates the AC mapping table in the PR body per references/ac-mapping.md.
# If a pr-view-json is supplied, also checks that every Commit SHA referenced
# in the table appears in the PR's commits.
#
# Required env (with defaults):
#   AC_REQUIRED_COLUMNS — comma-separated, default "AC,Description,Test,Code,Commit"
#
# Output:
#   AC_ROWS=<int>
#   AC_IDS=<comma-separated ids>
#
# Exit codes:
#   0 — table valid.
#   1 — table missing / incomplete / placeholders / unknown commit / dup ids.

# extract_ac_table <body> — emit the raw lines of the AC mapping markdown
# table to stdout, including header + separator + data rows.
extract_ac_table() {
  awk '
    BEGIN { in_sec=0; in_tbl=0 }
    /^##[[:space:]]/ {
      lc = tolower($0)
      if (lc ~ /^## *(ac[[:space:]]+mapping|acs|acceptance[[:space:]]+criteria)([[:space:]]|$)/) {
        in_sec = 1; in_tbl = 0
      } else {
        in_sec = 0; in_tbl = 0
      }
      next
    }
    in_sec && /^\|/ { in_tbl = 1; print; next }
    in_tbl && !/^\|/ { in_sec = 0; in_tbl = 0 }
  '
}

verify_ac_mapping() {
  local body="$1"
  local json_view="${2:-}"
  local req_cols="${AC_REQUIRED_COLUMNS:-AC,Description,Test,Code,Commit}"

  local table
  table="$(extract_ac_table <<<"$body")"

  if [[ -z "$table" ]]; then
    log_error "ac-mapping: section header or table not found"
    return 1
  fi

  local lines=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && lines+=("$line")
  done <<< "$table"

  if [[ ${#lines[@]} -lt 2 ]]; then
    log_error "ac-mapping: table has no rows beyond header"
    return 1
  fi

  local header_cells
  header_cells="$(_parse_row "${lines[0]}")"
  local -a hdrs=()
  local IFS=$'\t'
  read -ra hdrs <<<"$header_cells"
  IFS=$' \t\n'

  # Lowercase headers for matching
  local -a hdrs_lc=()
  local h
  for h in "${hdrs[@]}"; do
    hdrs_lc+=("$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')")
  done

  # Check required columns and remember their indices
  local -a req_arr=()
  IFS=','
  read -ra req_arr <<<"$req_cols"
  IFS=$' \t\n'

  local -a missing=()
  local req idx_ac=-1 idx_commit=-1
  for req in "${req_arr[@]}"; do
    local req_lc
    req_lc="$(printf '%s' "$req" | tr '[:upper:]' '[:lower:]')"
    local found=0 i=0
    for ((i=0; i<${#hdrs_lc[@]}; i++)); do
      if [[ "${hdrs_lc[$i]}" == "$req_lc" ]]; then
        found=1
        [[ "$req_lc" == "ac"     ]] && idx_ac="$i"
        [[ "$req_lc" == "commit" ]] && idx_commit="$i"
        break
      fi
    done
    [[ $found -eq 0 ]] && missing+=("$req")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "ac-mapping: missing required columns: ${missing[*]}"
    return 1
  fi

  # Walk data rows
  local row_count=0
  local -a ac_ids=()
  local -a commit_shas=()
  local -a incomplete=()
  local row_idx
  for ((row_idx=1; row_idx<${#lines[@]}; row_idx++)); do
    local line="${lines[$row_idx]}"
    if _is_separator_row "$line"; then
      continue
    fi
    row_count=$((row_count + 1))

    local cells_str
    cells_str="$(_parse_row "$line")"
    local -a cells=()
    IFS=$'\t'
    read -ra cells <<<"$cells_str"
    IFS=$' \t\n'

    local row_ok=1
    for req in "${req_arr[@]}"; do
      local req_lc
      req_lc="$(printf '%s' "$req" | tr '[:upper:]' '[:lower:]')"
      local i=0
      for ((i=0; i<${#hdrs_lc[@]}; i++)); do
        if [[ "${hdrs_lc[$i]}" == "$req_lc" ]]; then
          local val="${cells[$i]:-}"
          if is_placeholder "$val"; then
            row_ok=0
          fi
          break
        fi
      done
      [[ $row_ok -eq 0 ]] && break
    done

    if [[ $row_ok -eq 0 ]]; then
      incomplete+=("row#${row_count}")
      continue
    fi

    # Reject comma-separated paths in Test/Code cells: one path per row.
    # A comma here would silently get mis-attributed by the scope-envelope
    # parser, which takes the path prefix before the first `:`.
    local i_test=-1 i_code=-1 j
    for ((j=0; j<${#hdrs_lc[@]}; j++)); do
      case "${hdrs_lc[$j]}" in
        test) i_test="$j" ;;
        code) i_code="$j" ;;
      esac
    done
    if [[ $i_test -ge 0 && "${cells[$i_test]:-}" == *,* ]]; then
      log_error "ac-mapping: row $row_count Test cell contains comma — one path per row only"
      return 1
    fi
    if [[ $i_code -ge 0 && "${cells[$i_code]:-}" == *,* ]]; then
      log_error "ac-mapping: row $row_count Code cell contains comma — one path per row only"
      return 1
    fi

    [[ $idx_ac -ge 0     ]] && ac_ids+=("${cells[$idx_ac]}")
    [[ $idx_commit -ge 0 ]] && commit_shas+=("${cells[$idx_commit]}")
  done

  if [[ $row_count -eq 0 ]]; then
    log_error "ac-mapping: table has no data rows"
    return 1
  fi

  if [[ ${#incomplete[@]} -gt 0 ]]; then
    log_error "ac-mapping: incomplete rows: ${incomplete[*]}"
    return 1
  fi

  # Unique AC IDs
  local i j
  for ((i=0; i<${#ac_ids[@]}; i++)); do
    for ((j=i+1; j<${#ac_ids[@]}; j++)); do
      if [[ "${ac_ids[$i]}" == "${ac_ids[$j]}" ]]; then
        log_error "ac-mapping: duplicate AC id: ${ac_ids[$i]}"
        return 1
      fi
    done
  done

  # Commit SHAs in PR (if json_view given)
  if [[ -n "$json_view" ]]; then
    local pr_commits
    pr_commits="$(jq -r '(.commits // [])[] | .oid // empty' <<<"$json_view" 2>/dev/null || true)"
    local sha
    for sha in "${commit_shas[@]}"; do
      if [[ -z "$sha" ]]; then continue; fi
      local matched=0 commit_oid
      while IFS= read -r commit_oid; do
        [[ -z "$commit_oid" ]] && continue
        if [[ "$commit_oid" == "$sha"* || "$sha" == "$commit_oid"* ]]; then
          matched=1; break
        fi
      done <<< "$pr_commits"
      if [[ $matched -eq 0 ]]; then
        log_error "ac-mapping: commit SHA not in PR: $sha"
        return 1
      fi
    done
  fi

  local ac_ids_csv
  ac_ids_csv="$(IFS=,; printf '%s' "${ac_ids[*]}")"
  printf 'AC_ROWS=%d\nAC_IDS=%s\n' "$row_count" "$ac_ids_csv"
  return 0
}
