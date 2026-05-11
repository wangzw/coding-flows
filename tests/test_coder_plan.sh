#!/usr/bin/env bash
# Tests for scripts/lib/coder-plan.sh.
set -uo pipefail

TEST_FILE="test_coder_plan.sh"
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

# Cache root override + repo NWO so coder_plan_dir is deterministic.
TMPCACHE="$(mktemp -d)"
export CODING_FLOWS_CACHE_DIR="$TMPCACHE"
export CODING_FLOWS_REPO_NWO="acme/widget"

# --- Path resolution -----------------------------------------------------
got="$(coder_plan_dir "fix/240-empty-pkg")"
expected="$TMPCACHE/acme/widget/coder/fix-240-empty-pkg"
assert_eq "dir: matches expected" "$expected" "$got"

got="$(coder_plan_latest_path "fix/240-empty-pkg")"
assert_eq "latest_path: defaults to plan-v1.json" "$expected/plan-v1.json" "$got"

# --- coder_plan_init -----------------------------------------------------
issue_body='{"body":"# Issue\n\n## Acceptance Criteria\n\n- Removing all packages yields empty config\n- Existing flows unaffected\n\nAnother section ignored."}'
got_path="$(coder_plan_init "fix/240-empty-pkg" 240 "$issue_body" "events-before-publish,no-secrets-in-logs")"
assert_eq "init: emits plan path" "$expected/plan-v1.json" "$got_path"
[[ -f "$got_path" ]] && rc=0 || rc=1
assert_exit_code "init: file exists" 0 "$rc"

ac_count="$(jq '.acceptance_criteria | length' "$got_path")"
assert_eq "init: 2 AC rows" "2" "$ac_count"
inv_count="$(jq '.invariants_considered | length' "$got_path")"
assert_eq "init: 2 invariant rows" "2" "$inv_count"
first_ac_id="$(jq -r '.acceptance_criteria[0].id' "$got_path")"
assert_eq "init: AC ids start at AC-1" "AC-1" "$first_ac_id"

# Re-init refuses
coder_plan_init "fix/240-empty-pkg" 240 "$issue_body" "" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "init: refuses overwrite" 1 "$rc"

# --- coder_plan_validate (pre-fill) --------------------------------------
# Fresh plan has incomplete ACs → validate fails
coder_plan_validate "$got_path" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "validate: fresh plan fails" 1 "$rc"

# Fill in the plan so it passes validate.
tmp_plan="$(mktemp)"
jq '
  .acceptance_criteria |= map(.planned_test = "t.go:T" | .planned_code = "c.go:1-10" | .commit = "aaa1bbb" | .status = "done")
  | .invariants_considered |= map(.approach = "checked" | .status = "respected")
  | .risks = [{"category": "none", "description": "—", "mitigation": "—"}]
' "$got_path" > "$tmp_plan"
cp "$tmp_plan" "$got_path"
rm -f "$tmp_plan"

coder_plan_validate "$got_path" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code "validate: complete plan passes" 0 "$rc"

# --- coder_plan_render ---------------------------------------------------
rendered="$(coder_plan_render "$got_path")"
assert_contains "render: AC mapping header"      "## AC mapping" "$rendered"
assert_contains "render: AC row"                 "AC-1" "$rendered"
assert_contains "render: Risks header"           "## Risks" "$rendered"
assert_contains "render: risks marker"           "<!-- coding-flows:risks categories= -->" "$rendered"
assert_contains "render: self-check marker"      "<!-- coding-flows:coder-self-check invariants-considered=events-before-publish,no-secrets-in-logs -->" "$rendered"
assert_contains "render: none row"               "| none | — | — |" "$rendered"

# Add a real risk and re-render
tmp_plan="$(mktemp)"
jq '.risks = [{"category":"migration","description":"adds col","mitigation":"backfill"}]' "$got_path" > "$tmp_plan"
cp "$tmp_plan" "$got_path"
rm -f "$tmp_plan"
rendered="$(coder_plan_render "$got_path")"
assert_contains "render: marker reflects categories" "categories=migration" "$rendered"
assert_contains "render: migration row"              "migration | adds col | backfill" "$rendered"

rm -rf "$TMPCACHE"

test_summary
