# verify_risks <pr-body>
#
# Validates the `## Risks` section of a PR body:
#   - Section exists
#   - Followed by a Markdown table with columns Category/Description/Mitigation
#   - At least one row, every row complete
#   - Each Category in the allowed enum
#   - If category "none" appears, every row must be "none"
#   - HTML marker `<!-- coding-flows:risks categories=<csv> -->` present and the
#     marker's CSV matches the distinct non-"none" categories in the table
#
# Output:
#   RISKS_CATEGORIES=<csv of distinct non-none categories (sorted)>
#
# Allowed categories come from .coding-flows.json `risks.allowed_categories`, or
# default to: migration,feature-flag,secret,perf,external-side-effect,
# compat-break,none. Test override: env RISKS_ALLOWED_CATEGORIES.

# _extract_risks_table <body> — emit the table lines (header + sep + data).
_extract_risks_table() {
  awk '
    BEGIN { in_sec=0; in_tbl=0 }
    /^##[[:space:]]/ {
      lc = tolower($0)
      if (lc ~ /^## *risks([[:space:]]|$)/) { in_sec=1; in_tbl=0 }
      else { in_sec=0; in_tbl=0 }
      next
    }
    in_sec && /^\|/ { in_tbl=1; print; next }
    in_tbl && !/^\|/ { in_sec=0; in_tbl=0 }
  '
}

# _extract_risks_marker <body> — emit the categories CSV from the HTML
# marker (or empty if missing).
_extract_risks_marker() {
  grep -oE '<!--[[:space:]]*coding-flows:risks[[:space:]]+categories=[^[:space:]>]*' \
    | head -n1 \
    | sed -E 's/^.*categories=//'
}

verify_risks() {
  local body="$1"
  local allowed="${RISKS_ALLOWED_CATEGORIES:-}"
  if [[ -z "$allowed" ]]; then
    allowed="$(read_config '.risks.allowed_categories | join(",")' 'migration,feature-flag,secret,perf,external-side-effect,compat-break,none')"
  fi

  local table
  table="$(_extract_risks_table <<<"$body")"
  if [[ -z "$table" ]]; then
    log_error "risks: '## Risks' section or table not found"
    return 1
  fi

  local -a lines=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && lines+=("$line")
  done <<< "$table"

  if [[ ${#lines[@]} -lt 2 ]]; then
    log_error "risks: table has no rows beyond header"
    return 1
  fi

  # Parse header
  local header_cells
  header_cells="$(_parse_row "${lines[0]}")"
  local -a hdrs=()
  local IFS=$'\t'
  read -ra hdrs <<<"$header_cells"
  IFS=$' \t\n'

  local -a hdrs_lc=()
  local h
  for h in "${hdrs[@]}"; do
    hdrs_lc+=("$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')")
  done

  # Required columns + their indices
  local req_cols=("category" "description" "mitigation")
  local -A idx=()
  local r
  for r in "${req_cols[@]}"; do
    local found_idx=-1 i=0
    for ((i=0; i<${#hdrs_lc[@]}; i++)); do
      if [[ "${hdrs_lc[$i]}" == "$r" ]]; then
        found_idx="$i"; break
      fi
    done
    if [[ $found_idx -eq -1 ]]; then
      log_error "risks: missing required column: $r"
      return 1
    fi
    idx[$r]="$found_idx"
  done

  # Walk data rows
  local -a categories=()
  local row_count=0
  local row_idx
  for ((row_idx=1; row_idx<${#lines[@]}; row_idx++)); do
    local line="${lines[$row_idx]}"
    if _is_separator_row "$line"; then continue; fi
    row_count=$((row_count + 1))

    local cells_str
    cells_str="$(_parse_row "$line")"
    local -a cells=()
    IFS=$'\t'
    read -ra cells <<<"$cells_str"
    IFS=$' \t\n'

    local cat desc mit
    cat="$(printf '%s' "${cells[${idx[category]}]:-}" | tr '[:upper:]' '[:lower:]')"
    desc="${cells[${idx[description]}]:-}"
    mit="${cells[${idx[mitigation]}]:-}"

    if is_placeholder "$cat"; then
      log_error "risks: row $row_count has blank Category"
      return 1
    fi
    if [[ "$cat" != "none" ]] && { is_placeholder "$desc" || is_placeholder "$mit"; }; then
      log_error "risks: row $row_count (category=$cat) has blank Description or Mitigation"
      return 1
    fi
    # Validate category in allowed set
    if [[ ",$allowed," != *",$cat,"* ]]; then
      log_error "risks: row $row_count has unknown category '$cat' (allowed: $allowed)"
      return 1
    fi
    categories+=("$cat")
  done

  if [[ $row_count -eq 0 ]]; then
    log_error "risks: table has no data rows"
    return 1
  fi

  # If "none" appears, it must be the only category
  local has_none=0 has_other=0 c
  for c in "${categories[@]}"; do
    if [[ "$c" == "none" ]]; then has_none=1; else has_other=1; fi
  done
  if [[ $has_none -eq 1 && $has_other -eq 1 ]]; then
    log_error "risks: 'none' must not coexist with other categories"
    return 1
  fi

  # Non-none distinct categories, sorted CSV
  local distinct_csv
  distinct_csv="$(printf '%s\n' "${categories[@]}" | grep -vx 'none' | sort -u | paste -sd, -)"

  # Marker: must be present with explicit categories= field (value may be
  # empty for none-only PRs). The marker is what Reviewer reads.
  local marker_present=0
  if grep -qE '<!--[[:space:]]*coding-flows:risks[[:space:]]+categories=' <<<"$body"; then
    marker_present=1
  fi
  if [[ $marker_present -eq 0 ]]; then
    if grep -q '<!-- *coding-flows:risks' <<<"$body"; then
      log_error "risks: HTML marker malformed (expected categories= field)"
    else
      log_error "risks: HTML marker missing (expected <!-- coding-flows:risks categories=$distinct_csv -->)"
    fi
    return 1
  fi

  local marker_csv
  marker_csv="$(_extract_risks_marker <<<"$body")"
  # Normalize the marker the same way as distinct_csv: drop "none" (which is
  # the absence-of-risk sentinel — semantically equivalent to an empty list)
  # and de-dup. This lets `categories=` and `categories=none` both pass for a
  # none-only Risks table.
  local marker_sorted
  marker_sorted="$(printf '%s\n' "$marker_csv" | tr ',' '\n' | grep -vxE '|none' | sort -u | paste -sd, -)"
  if [[ "$marker_sorted" != "$distinct_csv" ]]; then
    log_error "risks: marker categories ($marker_sorted) != table categories ($distinct_csv)"
    return 1
  fi

  printf 'RISKS_CATEGORIES=%s\n' "$distinct_csv"
  return 0
}
