#!/usr/bin/env bash
# Integration test: bootstrap a Coder plan, render it to Markdown, and run
# every PR-body verifier (AC mapping, Risks) against the output. Catches
# drift between the renderer and the parsers — e.g. a column-rename or a
# marker-format change that breaks one side.
set -uo pipefail

TEST_FILE="test_render_roundtrip.sh"
TEST_PASS=0
TEST_FAIL=0

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$THIS_DIR/.." && pwd)"
export SKILL_DIR

# shellcheck source=lib/assert.sh
source "$THIS_DIR/lib/assert.sh"
# shellcheck source=../scripts/lib/common.sh
source "$SKILL_DIR/scripts/lib/common.sh"
# shellcheck source=../scripts/lib/worktree.sh
source "$SKILL_DIR/scripts/lib/worktree.sh"
# shellcheck source=../scripts/lib/coder-plan.sh
source "$SKILL_DIR/scripts/lib/coder-plan.sh"
# shellcheck source=../scripts/lib/verify-ac-mapping.sh
source "$SKILL_DIR/scripts/lib/verify-ac-mapping.sh"
# shellcheck source=../scripts/lib/verify-risks.sh
source "$SKILL_DIR/scripts/lib/verify-risks.sh"

# Isolated cache
TMP="$(mktemp -d)"
export CODING_FLOWS_CACHE_DIR="$TMP"
export CODING_FLOWS_REPO_NWO="acme/widget"

# 1. Bootstrap the plan from an issue body that includes a pipe character —
# this exercises the escape path end-to-end.
issue_body='{"body":"## Acceptance Criteria\n\n- AC with a | pipe in description\n- Plain AC text\n"}'
plan_path="$(coder_plan_init "fix/1-roundtrip" 1 "$issue_body" "events-before-publish")"
[[ -f "$plan_path" ]] && rc=0 || rc=1
assert_exit_code "init: plan written" 0 "$rc"

# 2. Fill in the plan so the renderer has real content.
tmp_plan="$(mktemp)"
jq '
  .acceptance_criteria |= map(
    .planned_test = "service_test.go:" + .id
    | .planned_code = "service.go:" + .id
    | .commit = "abc1234"
    | .status = "done"
  )
  | .invariants_considered |= map(.approach = "double-checked" | .status = "respected")
  | .risks = [
      {"category": "migration", "description": "adds | NOT NULL col", "mitigation": "backfill window"}
    ]
' "$plan_path" > "$tmp_plan"
cp "$tmp_plan" "$plan_path"
rm -f "$tmp_plan"

# 3. Validate succeeds.
coder_plan_validate "$plan_path" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "validate: complete plan ok" 0 "$rc"

# 4. Render the plan; this is the artifact that goes into the PR body.
rendered="$(coder_plan_render "$plan_path")"

# Sanity: rendered output contains the key sections
assert_contains "render: AC mapping header"  "## AC mapping"  "$rendered"
assert_contains "render: Risks header"       "## Risks"       "$rendered"
assert_contains "render: risks marker"       "<!-- coding-flows:risks categories=migration -->" "$rendered"
assert_contains "render: self-check marker"  "<!-- coding-flows:coder-self-check invariants-considered=events-before-publish -->" "$rendered"
# Pipe in AC text was escaped (no raw "|" outside table delimiters)
assert_contains "render: AC pipe escaped"    'AC with a \| pipe' "$rendered"
assert_contains "render: risk desc pipe escaped" 'adds \| NOT NULL col' "$rendered"

# 5. Round-trip: parse the rendered output back through the verifiers.
# Wrap in a faux PR body with Closes header so verify_ac_mapping has a
# realistic context (verify_ac_mapping doesn't check for Closes, but real
# PRs always have one — keep this realistic).
pr_body=$'## Summary\n\nCloses #1.\n\n'"$rendered"

# Build a PR-view JSON whose commits include abc1234 so the AC verifier's
# commit-SHA check passes.
pr_view="$(jq -n --arg b "$pr_body" '{number:1, headRefOid:"h", body:$b, commits:[{oid:"abc1234aaaa"}], files:[]}')"

ac_out="$(verify_ac_mapping "$pr_body" "$pr_view" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "roundtrip: ac-mapping ok"    0 "$rc"
assert_contains  "roundtrip: ac-mapping IDs"   "AC_IDS=AC-1,AC-2" "$ac_out"

risks_out="$(verify_risks "$pr_body" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "roundtrip: risks ok"          0 "$rc"
assert_contains  "roundtrip: risks category"    "RISKS_CATEGORIES=migration" "$risks_out"

rm -rf "$TMP"
test_summary
