# filter_pr_view_for_reviewer <pr-view-json> <my-reviewer-id>
#
# Returns a copy of the PR view JSON with comments redacted so a dispatched
# reviewer agent cannot read another reviewer's findings before reaching its
# own conclusion. Specifically:
#
#   - Comments whose body contains any `<!-- coding-flows:<kind> ... reviewer=<id>
#     ... -->` marker where `<id>` is NOT my-reviewer-id are dropped from
#     `.comments`. This hides other reviewers' /lgtm signals.
#   - Comments without any coding-flows marker are kept (Coder ↔ Reviewer prose).
#   - Reviews are LEFT UNCHANGED. Under same-user authentication (Coder and
#     all reviewers share one gh login), reviews cannot be authoritatively
#     attributed to a particular `reviewer=` id, so the filter does not edit
#     them. The dispatching agent must enforce blindness for review bodies
#     by not surfacing earlier review history to the dispatched reviewer.
#     See references/high-risk-pr.md "Code-enforced blindness — limitations".
#
# Output: filtered PR view JSON on stdout.

filter_pr_view_for_reviewer() {
  local json="$1" my_id="$2"
  if [[ -z "$my_id" ]]; then
    log_error "filter_pr_view_for_reviewer: missing reviewer id"
    return 64
  fi
  jq --arg me "$my_id" '
    .comments = (
      .comments // []
      | map(
          # Find every coding-flows:<kind> ... reviewer=<id> ... --> marker in
          # the body, extract the reviewer ids, and keep the comment only if
          # at least one matches $me or there are none (= it has no coding-flows
          # marker at all, e.g. ordinary discussion).
          . as $c
          | (
              [ ($c.body // "") | scan("<!--[[:space:]]*coding-flows:[a-z-]+[[:space:]][^>]*?reviewer=([^[:space:]>]+)") | .[0] ]
            ) as $reviewers
          | if ($reviewers | length) == 0 then $c
            elif ($reviewers | any(. == $me)) then $c
            else empty
            end
        )
    )
  ' <<<"$json"
}
