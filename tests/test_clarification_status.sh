#!/usr/bin/env bash
# Tests for scripts/lib/clarification-status.sh.
set -uo pipefail

TEST_FILE="test_clarification_status.sh"
TEST_PASS=0
TEST_FAIL=0

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$THIS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$THIS_DIR/lib/assert.sh"
# shellcheck source=../scripts/lib/common.sh
source "$SKILL_DIR/scripts/lib/common.sh"
# shellcheck source=../scripts/lib/clarification-status.sh
source "$SKILL_DIR/scripts/lib/clarification-status.sh"

mk_issue() {
  # mk_issue <author-login> <label-name-or-empty> <comments-json>
  jq -n --arg a "$1" --arg l "$2" --argjson c "$3" '
    {
      number: 1,
      author: {login: $a},
      body: "issue text",
      labels: ( if $l == "" then [] else [{name: $l}] end ),
      comments: $c
    }
  '
}

# Test 1: no marker → not-asked
issue="$(mk_issue "alice" "" '[]')"
out="$(clarification_status "$issue" 2>/dev/null)"
assert_contains "no-marker: STATUS=not-asked" "STATUS=not-asked" "$out"
assert_contains "no-marker: ROUNDS=0" "ROUNDS=0" "$out"

# Test 2: one marker, no author response → awaiting
comments='[{
  "author": {"login": "agent"},
  "createdAt": "2026-05-01T10:00:00Z",
  "body": "<!-- coding-flows:human-needed reason=ambiguous-issue -->\n@alice please clarify"
}]'
issue="$(mk_issue "alice" "needs-human" "$comments")"
out="$(clarification_status "$issue" 2>/dev/null)"
assert_contains "awaiting: STATUS" "STATUS=awaiting" "$out"
assert_contains "awaiting: ASKED_AT" "ASKED_AT=2026-05-01T10:00:00Z" "$out"
assert_contains "awaiting: ROUNDS=1" "ROUNDS=1" "$out"

# Test 3: author responded after marker → responded
comments='[
  {"author":{"login":"agent"},"createdAt":"2026-05-01T10:00:00Z","body":"<!-- coding-flows:human-needed reason=ambiguous-issue -->\n@alice please clarify"},
  {"author":{"login":"alice"},"createdAt":"2026-05-01T12:00:00Z","body":"Sure — option A."}
]'
issue="$(mk_issue "alice" "needs-human" "$comments")"
out="$(clarification_status "$issue" 2>/dev/null)"
assert_contains "responded: STATUS"     "STATUS=responded" "$out"
assert_contains "responded: response time" "AUTHOR_RESPONSE_AT=2026-05-01T12:00:00Z" "$out"

# Test 4: author commented BEFORE marker (irrelevant) → still awaiting
comments='[
  {"author":{"login":"alice"},"createdAt":"2026-05-01T09:00:00Z","body":"FYI"},
  {"author":{"login":"agent"},"createdAt":"2026-05-01T10:00:00Z","body":"<!-- coding-flows:human-needed reason=ambiguous-issue -->\n@alice please clarify"}
]'
issue="$(mk_issue "alice" "needs-human" "$comments")"
out="$(clarification_status "$issue" 2>/dev/null)"
assert_contains "pre-marker comment: STATUS=awaiting" "STATUS=awaiting" "$out"

# Test 5: timeout — many rounds without response
gen_rounds() {
  local n="$1"
  local arr='[]'
  local i
  for ((i=1; i<=n; i++)); do
    arr="$(jq --arg t "2026-05-01T10:0${i}:00Z" \
      '. + [{author:{login:"agent"},createdAt:$t,body:"<!-- coding-flows:human-needed reason=ambiguous-issue -->\nping"}]' <<<"$arr")"
  done
  printf '%s' "$arr"
}
comments="$(gen_rounds 10)"
issue="$(mk_issue "alice" "needs-human" "$comments")"
out="$(CLARIFICATION_TIMEOUT_ROUNDS=10 clarification_status "$issue" 2>/dev/null)"
assert_contains "timeout: STATUS=timeout" "STATUS=timeout" "$out"
assert_contains "timeout: ROUNDS=10"       "ROUNDS=10" "$out"

# Test 6: malformed input → exit 64
clarification_status "not json" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "malformed: exit 64" 64 "$rc"

test_summary
