# Shared helpers for coding-flows scripts. Sourced by all entry points and libs.
# Exits and side effects are the caller's responsibility — these helpers only
# emit values / log to stderr.

log_info()  { printf '[coding-flows] %s\n' "$*" >&2; }
log_warn()  { printf '[coding-flows] WARN: %s\n' "$*" >&2; }
log_error() { printf '[coding-flows] ERROR: %s\n' "$*" >&2; }

# find_repo_config [start-dir] — locate .coding-flows.json. First walks up from
# `start-dir` (default $PWD). If not found and cwd is inside a git worktree,
# falls back to the main repo's root (via `git rev-parse --git-common-dir`)
# so config is shared across all worktrees of the same repo.
find_repo_config() {
  local dir="${1:-$PWD}"
  dir="$(cd "$dir" 2>/dev/null && pwd)" || return 1

  local search="$dir"
  while [[ "$search" != "/" && -n "$search" ]]; do
    if [[ -f "$search/.coding-flows.json" ]]; then
      printf '%s\n' "$search/.coding-flows.json"
      return 0
    fi
    search="$(dirname "$search")"
  done

  # Fall back to main repo via git-common-dir (works from any worktree).
  local common
  common="$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null)" || return 1
  if [[ -n "$common" ]]; then
    if [[ "$common" != /* ]]; then
      common="$(cd "$dir" && cd "$common" 2>/dev/null && pwd)" || return 1
    fi
    local main_root
    main_root="$(dirname "$common")"
    if [[ -f "$main_root/.coding-flows.json" ]]; then
      printf '%s\n' "$main_root/.coding-flows.json"
      return 0
    fi
  fi
  return 1
}

# read_config <jq-path> [default] — read a value from .coding-flows.json.
# Returns the value or `default` if file or key is missing/null.
read_config() {
  local key="$1"
  local default="${2:-}"
  local cfg
  if ! cfg="$(find_repo_config)"; then
    printf '%s' "$default"
    return 0
  fi
  local out
  out="$(jq -r "$key // empty" "$cfg" 2>/dev/null || true)"
  if [[ -z "$out" || "$out" == "null" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$out"
  fi
}

# trim leading/trailing whitespace from a single value.
trim() {
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# is_placeholder <value> — return 0 if the value is one of our placeholder
# sentinels (empty, dash, TBD, ellipsis, angle-bracketed). Used by AC mapping
# and Risks verifiers.
is_placeholder() {
  local v="$1"
  [[ -z "$v" ]] && return 0
  case "$v" in
    -|—|TBD|tbd|N/A|n/a|\?|"…"|"...") return 0 ;;
    "<"*">") return 0 ;;
  esac
  return 1
}

# _is_separator_row <line> — true for `|---|---|` style separator rows.
_is_separator_row() {
  local stripped
  stripped="$(printf '%s' "$1" | tr -d '|: \t-')"
  [[ -z "$stripped" ]]
}

# _parse_row <markdown-table-row> — emit tab-separated cell values, trimmed.
# Strips leading/trailing `|`. Treats `\|` as a literal `|` in cell content
# (Markdown's standard pipe-escape inside table cells).
_parse_row() {
  local line="$1"
  line="${line#|}"
  line="${line%|}"
  # Protect escaped pipes with a sentinel before splitting.
  line="${line//\\|/$'\x01'}"
  local IFS='|'
  local -a cells=()
  read -ra cells <<<"$line"
  local out="" cell
  for cell in "${cells[@]}"; do
    local t
    t="$(trim "$cell")"
    # Restore sentinel to literal pipe.
    t="${t//$'\x01'/|}"
    if [[ -z "$out" ]]; then out="$t"; else out+=$'\t'"$t"; fi
  done
  printf '%s' "$out"
}

# glob_match <pattern> <path> — glob-style match supporting:
#   *   any chars except /
#   **  any chars including /
#   ?   single char except /
# Implementation converts glob → POSIX ERE and uses [[ =~ ]]. Avoids reliance
# on `shopt -s globstar` quirks across bash versions.
glob_match() {
  local pattern="$1" path="$2"
  local re=""
  local p="$pattern"
  local prefix=""

  if [[ "$p" == '**/'* ]]; then
    prefix='(.*/)?'
    p="${p#'**/'}"
  fi

  local i=0 len=${#p} c next
  while (( i < len )); do
    c="${p:$i:1}"
    case "$c" in
      .)
        re+='\.'
        ;;
      \?)
        re+='[^/]'
        ;;
      \*)
        next="${p:$((i+1)):1}"
        if [[ "$next" == '*' ]]; then
          re+='.*'
          i=$((i + 1))
        else
          re+='[^/]*'
        fi
        ;;
      '['|']'|'('|')'|'{'|'}'|'+'|'^'|'$'|'|'|'\\')
        re+='\'"$c"
        ;;
      *)
        re+="$c"
        ;;
    esac
    i=$((i + 1))
  done

  re="^${prefix}${re}\$"
  [[ "$path" =~ $re ]]
}

# load_pr_view "$@" — populate global PR_VIEW_JSON from either --from-file
# <path> or a PR number (via gh). Sets exit-code 64 on usage error.
load_pr_view() {
  local from_file="" pr=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from-file) from_file="$2"; shift 2 ;;
      --pr)        pr="$2"; shift 2 ;;
      --dry-run|--quiet) shift ;;
      *)
        if [[ -z "$pr" && "$1" =~ ^[0-9]+$ ]]; then pr="$1"; fi
        shift
        ;;
    esac
  done
  if [[ -n "$from_file" ]]; then
    if [[ ! -f "$from_file" ]]; then
      log_error "fixture file not found: $from_file"
      return 64
    fi
    PR_VIEW_JSON="$(cat "$from_file")"
    PR_VIEW_SOURCE="file"
  elif [[ -n "$pr" ]]; then
    PR_VIEW_JSON="$(gh pr view "$pr" --json \
      number,title,body,headRefName,headRefOid,baseRefName,comments,commits,labels,files,statusCheckRollup,reviewDecision,reviews,state,isDraft 2>&1)" \
      || { log_error "gh pr view failed: $PR_VIEW_JSON"; return 69; }
    PR_VIEW_SOURCE="gh"
  else
    log_error "no PR number or --from-file specified"
    return 64
  fi
  export PR_VIEW_JSON PR_VIEW_SOURCE
}

# repo_allowed_merge_methods — emit a CSV of merge methods the current repo
# permits. Order: env override > live gh query > permissive fallback for
# --from-file tests.
#
#   $CODING_FLOWS_REPO_ALLOWS  — explicit override (e.g. "squash,rebase").
#   PR_VIEW_SOURCE=file   — fixture mode: assume "squash,rebase" allowed.
#   otherwise             — `gh repo view --json squashMergeAllowed,...`.
repo_allowed_merge_methods() {
  if [[ -n "${CODING_FLOWS_REPO_ALLOWS:-}" ]]; then
    printf '%s' "$CODING_FLOWS_REPO_ALLOWS"
    return 0
  fi
  if [[ "${PR_VIEW_SOURCE:-}" == "file" ]]; then
    printf 'squash,rebase'
    return 0
  fi
  local info
  info="$(gh repo view --json squashMergeAllowed,rebaseMergeAllowed,mergeCommitAllowed 2>/dev/null || echo '{}')"
  local out=""
  local sq rb mc
  sq="$(jq -r '.squashMergeAllowed // false' <<<"$info")"
  rb="$(jq -r '.rebaseMergeAllowed // false' <<<"$info")"
  mc="$(jq -r '.mergeCommitAllowed // false' <<<"$info")"
  [[ "$sq" == "true" ]] && out="${out:+$out,}squash"
  [[ "$rb" == "true" ]] && out="${out:+$out,}rebase"
  [[ "$mc" == "true" ]] && out="${out:+$out,}merge"
  printf '%s' "$out"
}

# extract_changed_files <pr-view-json> — emit one path per line.
extract_changed_files() {
  jq -r '(.files // []) | .[] | .path' <<<"$1"
}

# extract_total_lines <pr-view-json> — emit additions+deletions.
extract_total_lines() {
  jq -r '[(.files // [])[] | (.additions // 0) + (.deletions // 0)] | add // 0' <<<"$1"
}

# extract_labels <pr-view-json> — comma-separated label names.
extract_labels() {
  jq -r '[(.labels // [])[] | .name] | join(",")' <<<"$1"
}

# repo_state_dir [PR_number] — emit per-repo state dir path. Caches owner/repo
# in CODING_FLOWS_REPO_NWO across calls. Override base with CODING_FLOWS_CACHE_DIR for
# tests (e.g. point at a tmpdir).
#
#   ~/.cache/coding-flows/<owner>/<repo>/pr-<N>/...      (with PR number)
#   ~/.cache/coding-flows/<owner>/<repo>/                (without)
#
# Does not create the directory — caller decides when to mkdir.
repo_state_dir() {
  local pr="${1:-}"
  local nwo
  if [[ -n "${CODING_FLOWS_REPO_NWO:-}" ]]; then
    nwo="$CODING_FLOWS_REPO_NWO"
  else
    nwo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
    [[ -n "$nwo" ]] && export CODING_FLOWS_REPO_NWO="$nwo"
  fi
  [[ -z "$nwo" ]] && nwo="unknown/unknown"
  local base="${CODING_FLOWS_CACHE_DIR:-$HOME/.cache/coding-flows}/${nwo}"
  if [[ -n "$pr" ]]; then
    printf '%s/pr-%s' "$base" "$pr"
  else
    printf '%s' "$base"
  fi
}

# triggered_invariants <files-newline> [<config-path>]
#
# Emits one invariant ID per line for each invariant in .coding-flows.json whose
# `triggered_by_paths` matches at least one changed file. Output is sorted +
# uniqued. The merge gate uses this to demand the LGTM marker's `invariants=`
# list cover every triggered invariant.
triggered_invariants() {
  local files_input="$1"
  local config_path="${2:-}"

  if [[ -z "$config_path" ]]; then
    config_path="$(find_repo_config || true)"
  fi
  [[ -z "$config_path" || ! -f "$config_path" ]] && return 0

  if ! jq empty "$config_path" 2>/dev/null; then
    log_error "triggered-invariants: $config_path is not valid JSON"
    return 65
  fi

  local count
  count="$(jq -r '(.invariants // []) | length' "$config_path")"
  [[ "$count" -eq 0 ]] && return 0

  local i=0
  while [[ $i -lt $count ]]; do
    local inv
    inv="$(jq -c ".invariants[$i]" "$config_path")"
    local id patterns
    id="$(jq -r '.id // empty' <<<"$inv")"
    patterns="$(jq -r '.triggered_by_paths[]? // empty' <<<"$inv")"

    if [[ -z "$id" ]]; then
      i=$((i + 1)); continue
    fi
    if [[ -z "$patterns" ]]; then
      # No paths declared → invariant always applies.
      printf '%s\n' "$id"
      i=$((i + 1)); continue
    fi

    local matched=0 pat file
    while IFS= read -r pat; do
      [[ -z "$pat" ]] && continue
      while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        if glob_match "$pat" "$file"; then
          matched=1
          break 2
        fi
      done <<< "$files_input"
    done <<< "$patterns"

    [[ $matched -eq 1 ]] && printf '%s\n' "$id"
    i=$((i + 1))
  done | sort -u
}
