# check_lgtm <pr-view-json>
#
# Scans PR comments newest-first for valid /lgtm signals. A signal is valid if:
#   1. The comment body's first non-blank line is exactly "/lgtm".
#   2. The body contains a marker:
#        <!-- coding-flows:lgtm sha=<hex> reviewer=<id> acs=<csv> invariants=<csv> risks-reviewed=<csv> -->
#      All four key=value fields are required (values can be empty). The
#      `risks-reviewed=` field was added later; old markers that omit it are
#      treated as "no risks reviewed" (downstream coverage check decides
#      whether that's acceptable).
#
# Output (KEY=VALUE on stdout, one per line):
#   LGTM_COUNT=<distinct reviewers whose LGTM is bound to current head>
#   LGTM_REVIEWERS=<comma-separated reviewer ids — current-head only>
#   LGTM_SHA=<head sha if at least one LGTM matches, else last-seen sha>
#   LGTM_ACS=<csv union of acs= claims across all current-head LGTMs>
#   LGTM_INVARIANTS=<csv union of invariants= claims across all current-head LGTMs>
#   LGTM_RISKS_REVIEWED=<csv union of risks-reviewed= claims across all current-head LGTMs>
#   STALE=<yes|no>
#
# Exit codes:
#   0 — at least one LGTM is bound to current head.
#   1 — no /lgtm with valid marker found at all.
#   2 — most recent LGTM is bound to a different SHA (stale).
#  64 — input JSON malformed.

check_lgtm() {
  local json="$1"
  local head_sha
  head_sha="$(jq -r '.headRefOid // empty' <<<"$json" 2>/dev/null || true)"
  if [[ -z "$head_sha" ]]; then
    log_error "headRefOid missing from PR view JSON"
    return 64
  fi

  # The marker regex tolerates extra whitespace and is order-independent on
  # the four key=value fields. jq's PCRE supports named captures; we capture
  # the full body and let bash extract fields after.
  local lines
  lines="$(
    jq -r '
      (.comments // [])
      | sort_by(.createdAt) | reverse
      | .[]
      | select((.body // "" | split("\n") | map(select(test("\\S"))) | .[0] // "") == "/lgtm")
      | select((.body // "") | test("<!--[[:space:]]*coding-flows:lgtm[[:space:]].*-->"))
      | .body
      | capture("<!--[[:space:]]*coding-flows:lgtm[[:space:]]+(?<fields>[^>]*)-->")
      | .fields
    ' <<<"$json" 2>/dev/null || true
  )"

  if [[ -z "$lines" ]]; then
    printf 'LGTM_COUNT=0\nLGTM_REVIEWERS=\nLGTM_SHA=\nLGTM_ACS=\nLGTM_INVARIANTS=\nLGTM_RISKS_REVIEWED=\nSTALE=no\n'
    return 1
  fi

  local most_recent_sha=""
  local current_reviewers=""
  local count_current=0
  local acs_union="" inv_union="" risks_union=""

  while IFS= read -r fields; do
    [[ -z "$fields" ]] && continue
    local sha reviewer acs invs risks_rev
    sha="$(_kv "$fields" sha)"
    reviewer="$(_kv "$fields" reviewer)"
    acs="$(_kv "$fields" acs)"
    invs="$(_kv "$fields" invariants)"
    risks_rev="$(_kv "$fields" risks-reviewed)"

    if [[ -z "$sha" || -z "$reviewer" ]]; then
      continue
    fi
    if ! grep -qE '(^|[[:space:]])acs=' <<<"$fields"; then continue; fi
    if ! grep -qE '(^|[[:space:]])invariants=' <<<"$fields"; then continue; fi
    # risks-reviewed is optional in the marker for backwards compat; treat
    # missing as empty.

    [[ -z "$most_recent_sha" ]] && most_recent_sha="$sha"
    if [[ "$sha" == "$head_sha" ]]; then
      if [[ ",$current_reviewers," != *",$reviewer,"* ]]; then
        if [[ -z "$current_reviewers" ]]; then
          current_reviewers="$reviewer"
        else
          current_reviewers="$current_reviewers,$reviewer"
        fi
        count_current=$((count_current + 1))
      fi
      acs_union="$(_csv_union "$acs_union" "$acs")"
      inv_union="$(_csv_union "$inv_union" "$invs")"
      risks_union="$(_csv_union "$risks_union" "$risks_rev")"
    fi
  done <<< "$lines"

  if [[ -z "$most_recent_sha" ]]; then
    printf 'LGTM_COUNT=0\nLGTM_REVIEWERS=\nLGTM_SHA=\nLGTM_ACS=\nLGTM_INVARIANTS=\nLGTM_RISKS_REVIEWED=\nSTALE=no\n'
    return 1
  fi

  if [[ $count_current -eq 0 ]]; then
    printf 'LGTM_COUNT=0\nLGTM_REVIEWERS=\nLGTM_SHA=%s\nLGTM_ACS=\nLGTM_INVARIANTS=\nLGTM_RISKS_REVIEWED=\nSTALE=yes\n' "$most_recent_sha"
    return 2
  fi

  printf 'LGTM_COUNT=%d\nLGTM_REVIEWERS=%s\nLGTM_SHA=%s\nLGTM_ACS=%s\nLGTM_INVARIANTS=%s\nLGTM_RISKS_REVIEWED=%s\nSTALE=no\n' \
    "$count_current" "$current_reviewers" "$head_sha" "$acs_union" "$inv_union" "$risks_union"
  return 0
}

# _kv <fields-string> <key> — extract `key=value` (value stops at whitespace
# or closing '>'). Empty if not present. Always returns 0 — missing key is
# not an error (callers decide), and we don't want to interact poorly with
# `set -e` in the invoking script.
_kv() {
  local fields="$1" key="$2"
  local result
  result="$(grep -oE "(^|[[:space:]])${key}=[^[:space:]>]*" <<<"$fields" 2>/dev/null \
    | head -n1 \
    | sed -E "s/^[[:space:]]*${key}=//" || true)"
  printf '%s' "$result"
}

# _csv_union <a> <b> — emit comma-separated union of two CSV lists, sorted
# for deterministic output.
_csv_union() {
  local a="$1" b="$2"
  if [[ -z "$a" && -z "$b" ]]; then return 0; fi
  local combined
  if [[ -z "$a" ]]; then combined="$b"
  elif [[ -z "$b" ]]; then combined="$a"
  else combined="${a},${b}"
  fi
  local IFS=','
  local -a all=($combined)
  printf '%s\n' "${all[@]}" | awk 'NF' | sort -u | paste -sd, -
}
