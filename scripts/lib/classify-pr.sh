# classify_pr <pr-view-json>
#
# Canonical state-machine for the Coder cycle. Emits the single most-
# actionable state for the PR, on stdout as:
#
#   PR_STATE=<one of: address-changes | address-ci-fail
#                   | ready-to-merge | wait-ci | wait-review | wait-lgtm-fresh>
#
# Why this script exists: PRs in the coding-flows model use a *comment*
# marker (`<!-- coding-flows:lgtm ... -->`) for approval, not a formal
# `gh pr review --approve`. `gh pr view`'s `reviewDecision` field is
# therefore useless to the Coder (it stays `""` unless a formal review
# fires). The Coder must call this script (which wraps `check_lgtm` and
# the CHANGES_REQUESTED supersession logic) instead of inspecting raw
# fields.
#
# State precedence (highest first):
#   1. address-changes      — Reviewer marked CHANGES_REQUESTED and the
#                             review is not superseded by a later /lgtm
#                             from the same reviewer.
#   2. address-ci-fail      — any required check is FAILURE/ERROR/CANCELLED.
#   3. wait-ci              — any required check is in progress / pending
#                             / queued / waiting / expected.
#   4. ready-to-merge       — CI green, a valid /lgtm marker exists and is
#                             bound to the current head SHA. (The agent
#                             should still confirm with
#                             `coding-flows-merge --dry-run` before merging
#                             — Gate failures beyond CI/LGTM are surfaced
#                             there.)
#   5. wait-lgtm-fresh      — CI green, /lgtm exists but bound to an older
#                             head SHA (Coder pushed since).
#   6. wait-review          — CI green, no valid /lgtm marker at all.
#
# Exit codes:
#   0  — state emitted on stdout.
#  64  — input JSON malformed.

classify_pr() {
  local json="$1"

  if ! jq empty <<<"$json" 2>/dev/null; then
    log_error "classify_pr: input not valid JSON"
    return 64
  fi

  # 1. Unsuperseded CHANGES_REQUESTED — same query as gh-flow-merge Gate 6.
  local pending_changes
  pending_changes="$(jq -r '
    . as $pr
    | [(.reviews // [])
        | sort_by(.submittedAt) | reverse
        | group_by(.author.login // "?")
        | map(.[0])
        | .[]
        | select(.state == "CHANGES_REQUESTED")
        | . as $r
        | (
            [$pr.comments[]?
              | select((.author.login // "") == ($r.author.login // ""))
              | select((.body // "" | split("\n") | map(select(test("\\S"))) | .[0] // "") == "/lgtm")
              | select((.createdAt // "") > ($r.submittedAt // ""))
            ] | length
          ) as $superseded
        | select($superseded == 0)
      ] | length
  ' <<<"$json")"
  if [[ "$pending_changes" -gt 0 ]]; then
    printf 'PR_STATE=address-changes\n'
    return 0
  fi

  # 2. CI failed
  local ci_fail
  ci_fail="$(jq -r '
    [(.statusCheckRollup // [])[]
      | select((.conclusion // .state // "") | ascii_upcase | test("FAIL|ERROR|CANCEL"))
    ] | length
  ' <<<"$json")"
  if [[ "$ci_fail" -gt 0 ]]; then
    printf 'PR_STATE=address-ci-fail\n'
    return 0
  fi

  # 3. CI in progress
  local ci_pending
  ci_pending="$(jq -r '
    [(.statusCheckRollup // [])[]
      | select((.conclusion // .state // "") | ascii_upcase | test("PENDING|IN_PROGRESS|QUEUED|WAITING|EXPECTED"))
    ] | length
  ' <<<"$json")"
  if [[ "$ci_pending" -gt 0 ]]; then
    printf 'PR_STATE=wait-ci\n'
    return 0
  fi

  # 4. CI green — branch on LGTM state.
  local lgtm_rc=0
  check_lgtm "$json" >/dev/null 2>&1 || lgtm_rc=$?
  case $lgtm_rc in
    0) printf 'PR_STATE=ready-to-merge\n' ;;
    1) printf 'PR_STATE=wait-review\n' ;;
    2) printf 'PR_STATE=wait-lgtm-fresh\n' ;;
    *)
      log_error "classify_pr: check_lgtm returned unexpected exit $lgtm_rc"
      return 1
      ;;
  esac
  return 0
}
