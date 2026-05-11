# clarification_status <issue-view-json>
#
# Inspect an issue's comments + labels to decide whether a clarification
# loop is in flight. Reads:
#   - .labels[].name (looking for the notification label, default needs-human)
#   - .comments[] (looking for coding-flows:human-needed reason=ambiguous-issue
#     marker and the issue author's responses afterward)
#   - .author.login (to identify "author responded" vs "agent responded")
#
# Output (KEY=VALUE):
#   STATUS=not-asked|awaiting|responded|timeout
#   ASKED_AT=<iso8601 or empty>
#   AUTHOR_RESPONSE_AT=<iso8601 or empty>
#   ROUNDS=<integer count of human-needed markers found>
#
# Exit codes:
#   0 — always (status is in stdout).
#  64 — input malformed.
#
# Env:
#   CLARIFICATION_TIMEOUT_ROUNDS — number of rounds (default 10) after which
#     status flips from 'awaiting' to 'timeout'. The "round" counter is the
#     number of human-needed markers in this issue's history; each new
#     asked-after-removal round adds one.

clarification_status() {
  local json="$1"
  local timeout_rounds="${CLARIFICATION_TIMEOUT_ROUNDS:-10}"
  local notif_label
  notif_label="$(read_config '.notification.label' 'needs-human')"

  if ! jq empty <<<"$json" 2>/dev/null; then
    log_error "clarification_status: input not valid JSON"
    return 64
  fi

  local has_label
  has_label="$(jq -r --arg lbl "$notif_label" \
    '(.labels // []) | any(.name == $lbl) | tostring' <<<"$json")"

  # Author = issue.author.login (fallback to .user.login for API variants).
  local author
  author="$(jq -r '(.author.login // .user.login // "")' <<<"$json")"

  # Find the latest "coding-flows:human-needed reason=ambiguous-issue" marker
  # and its timestamp. Also count total such markers (rounds).
  local marker_data
  marker_data="$(jq -r '
    [(.comments // [])[]
      | select((.body // "") | test("<!--[[:space:]]*coding-flows:human-needed[[:space:]]+reason=ambiguous-issue"))
      | {createdAt: (.createdAt // ""), body: (.body // "")}
    ]
  ' <<<"$json")"

  local rounds asked_at
  rounds="$(jq -r 'length' <<<"$marker_data")"
  asked_at="$(jq -r 'sort_by(.createdAt) | last.createdAt // ""' <<<"$marker_data")"

  if [[ "$rounds" -eq 0 ]]; then
    printf 'STATUS=not-asked\nASKED_AT=\nAUTHOR_RESPONSE_AT=\nROUNDS=0\n'
    return 0
  fi

  # Look for an author comment strictly after asked_at.
  local response_at
  response_at="$(jq -r --arg author "$author" --arg asked "$asked_at" '
    [(.comments // [])[]
      | select((.author.login // "") == $author)
      | select((.createdAt // "") > $asked)
      | .createdAt
    ] | sort | first // ""
  ' <<<"$json")"

  if [[ -n "$response_at" ]]; then
    printf 'STATUS=responded\nASKED_AT=%s\nAUTHOR_RESPONSE_AT=%s\nROUNDS=%s\n' \
      "$asked_at" "$response_at" "$rounds"
    return 0
  fi

  if [[ "$rounds" -ge "$timeout_rounds" ]]; then
    printf 'STATUS=timeout\nASKED_AT=%s\nAUTHOR_RESPONSE_AT=\nROUNDS=%s\n' \
      "$asked_at" "$rounds"
    return 0
  fi

  printf 'STATUS=awaiting\nASKED_AT=%s\nAUTHOR_RESPONSE_AT=\nROUNDS=%s\n' \
    "$asked_at" "$rounds"
  return 0
}
