# verify_scope_envelope <pr-view-json>
#
# Asserts every changed file in the PR is "claimed" by at least one of:
#   1. AC mapping Code or Test column (file path before first `:` is the
#      claim — path:line-range or path:test-name both supported).
#   2. ## Support files section in PR body (one path per bulleted line).
#   3. .coding-flows.json scope_envelope.exclude_paths (glob patterns).
#
# Output:
#   SCOPE_CLAIMED=<count>
#   SCOPE_UNCLAIMED=<csv of unclaimed file paths>
#
# Exit codes:
#   0 — every changed file is claimed.
#   1 — one or more changed files are unclaimed.
#  64 — input malformed.

# Default exclude patterns when .coding-flows.json doesn't specify any.
_DEFAULT_SCOPE_EXCLUDES=(
  '**/*.md'
  '*.md'
  '**/CHANGELOG'
  '**/package-lock.json'
  '**/yarn.lock'
  '**/pnpm-lock.yaml'
  '**/go.sum'
  '**/Cargo.lock'
  '**/poetry.lock'
  '**/*.snap'
  '.github/dependabot.yml'
)

# _extract_support_files <body> — emit one path per line. Reads bulleted
# lines under `## Support files`. Accepts `- path` / `* path` markers.
_extract_support_files() {
  awk '
    BEGIN { in_sec=0 }
    /^##[[:space:]]/ {
      lc = tolower($0)
      if (lc ~ /^## *support[[:space:]]+files([[:space:]]|$)/) { in_sec=1 }
      else { in_sec=0 }
      next
    }
    in_sec && /^[[:space:]]*[-*][[:space:]]+/ {
      sub(/^[[:space:]]*[-*][[:space:]]+/, "")
      gsub(/`/, "")
      # Take only the path token (everything up to the first whitespace).
      n = split($0, parts, /[[:space:]]+/)
      if (n > 0 && parts[1] != "") print parts[1]
    }
  '
}

# _extract_claimed_paths_from_ac_table <body> — emit one path per line from
# every Code or Test cell of the AC mapping table. Path is the prefix
# before the first `:` (or the whole cell if no `:`).
_extract_claimed_paths_from_ac_table() {
  local body="$1"
  local table
  table="$(extract_ac_table <<<"$body")"
  [[ -z "$table" ]] && return 0

  local -a lines=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && lines+=("$line")
  done <<< "$table"
  [[ ${#lines[@]} -lt 2 ]] && return 0

  # Identify column indices for Test and Code
  local header_cells
  header_cells="$(_parse_row "${lines[0]}")"
  local -a hdrs=()
  local IFS=$'\t'
  read -ra hdrs <<<"$header_cells"
  IFS=$' \t\n'

  local idx_test=-1 idx_code=-1 i
  for ((i=0; i<${#hdrs[@]}; i++)); do
    case "$(printf '%s' "${hdrs[$i]}" | tr '[:upper:]' '[:lower:]')" in
      test) idx_test="$i" ;;
      code) idx_code="$i" ;;
    esac
  done

  local row_idx
  for ((row_idx=1; row_idx<${#lines[@]}; row_idx++)); do
    local line="${lines[$row_idx]}"
    _is_separator_row "$line" && continue
    local cells_str
    cells_str="$(_parse_row "$line")"
    local -a cells=()
    IFS=$'\t'
    read -ra cells <<<"$cells_str"
    IFS=$' \t\n'

    local cell
    for i in "$idx_test" "$idx_code"; do
      [[ $i -lt 0 ]] && continue
      cell="${cells[$i]:-}"
      [[ -z "$cell" ]] && continue
      # Path is everything before the first colon. If no colon, whole cell.
      local path
      if [[ "$cell" == *:* ]]; then
        path="${cell%%:*}"
      else
        path="$cell"
      fi
      path="$(trim "$path")"
      [[ -n "$path" ]] && printf '%s\n' "$path"
    done
  done
}

# _path_claimed <changed-file> <claimed-paths-newline> — return 0 if the
# changed file matches a claimed path either exactly or by suffix (claimed
# paths can be relative — "service.go" matches "backend/foo/service.go").
_path_claimed() {
  local changed="$1"
  local claimed="$2"
  local p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if [[ "$changed" == "$p" || "$changed" == */"$p" ]]; then
      return 0
    fi
  done <<< "$claimed"
  return 1
}

verify_scope_envelope() {
  local json="$1"

  local body
  body="$(jq -r '.body // ""' <<<"$json" 2>/dev/null || true)"
  if [[ -z "$body" ]]; then
    log_error "scope-envelope: PR body missing"
    return 64
  fi

  local changed
  changed="$(extract_changed_files "$json")"
  if [[ -z "$changed" ]]; then
    printf 'SCOPE_CLAIMED=0\nSCOPE_UNCLAIMED=\n'
    return 0
  fi

  # Claimed by AC mapping table
  local from_ac
  from_ac="$(_extract_claimed_paths_from_ac_table "$body")"

  # Claimed by ## Support files
  local from_support
  from_support="$(_extract_support_files <<<"$body")"

  # Combined explicit claim list
  local claimed
  claimed="$(printf '%s\n%s\n' "$from_ac" "$from_support" | awk 'NF' | sort -u)"

  # Exclude patterns from config (or defaults)
  local config_excludes
  config_excludes="$(read_config '.scope_envelope.exclude_paths | join("\n")' '' || true)"
  local -a exclude_globs=()
  if [[ -n "$config_excludes" ]]; then
    while IFS= read -r g; do
      [[ -n "$g" ]] && exclude_globs+=("$g")
    done <<< "$config_excludes"
  else
    exclude_globs=("${_DEFAULT_SCOPE_EXCLUDES[@]}")
  fi

  local -a unclaimed=()
  local count_claimed=0
  local cf
  while IFS= read -r cf; do
    [[ -z "$cf" ]] && continue
    # Check explicit claims
    if _path_claimed "$cf" "$claimed"; then
      count_claimed=$((count_claimed + 1))
      continue
    fi
    # Check exclude globs
    local hit_exclude=0 g
    for g in "${exclude_globs[@]}"; do
      if glob_match "$g" "$cf"; then
        hit_exclude=1; break
      fi
    done
    if [[ $hit_exclude -eq 1 ]]; then
      count_claimed=$((count_claimed + 1))
      continue
    fi
    unclaimed+=("$cf")
  done <<< "$changed"

  local unclaimed_csv
  unclaimed_csv="$(IFS=,; printf '%s' "${unclaimed[*]:-}")"

  printf 'SCOPE_CLAIMED=%d\nSCOPE_UNCLAIMED=%s\n' "$count_claimed" "$unclaimed_csv"

  if [[ ${#unclaimed[@]} -gt 0 ]]; then
    log_error "scope-envelope: ${#unclaimed[@]} changed file(s) not claimed by AC mapping, Support files, or excludes: ${unclaimed[*]}"
    return 1
  fi
  return 0
}
