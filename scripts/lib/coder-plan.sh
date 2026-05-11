# Coder plan library.
#
# The Coder's local working plan mirrors the Reviewer's plan: never posted
# to the PR, lives on disk, drives Phase B/C/D. Phase D renders the plan
# into Markdown segments for the PR body; Phase C/D validate completeness
# before push.
#
# Location:
#   $(repo_state_dir)/coder/<branch-slug>/plan-vN.json
#   (override base via CODING_FLOWS_CACHE_DIR for tests)

# coder_plan_dir <branch> — emit absolute path to the Coder plan dir.
coder_plan_dir() {
  local branch="$1"
  local slug
  slug="$(worktree_branch_to_slug "$branch")"
  printf '%s/coder/%s' "$(repo_state_dir)" "$slug"
}

# coder_plan_latest_path <branch> — emit the path to the most-recent plan
# version, or the would-be path of plan-v1.json if no plan exists yet.
coder_plan_latest_path() {
  local branch="$1"
  local dir
  dir="$(coder_plan_dir "$branch")"
  if [[ -d "$dir" ]]; then
    local latest
    latest="$(ls "$dir"/plan-v*.json 2>/dev/null | sort -V | tail -n1 || true)"
    if [[ -n "$latest" ]]; then
      printf '%s' "$latest"
      return 0
    fi
  fi
  printf '%s/plan-v1.json' "$dir"
}

# coder_plan_init <branch> <issue-number> <issue-body-json> <triggered-invariants-csv>
#
# Bootstrap a plan-v1.json from an issue body. Pre-fills:
#   - feasibility (all "unknown" — agent must complete)
#   - acceptance_criteria from issue body sections
#   - invariants_considered from <triggered-invariants-csv>
#   - empty scope_envelope, support_files, risks
#
# Emits the path to the created plan on stdout.
coder_plan_init() {
  local branch="$1" issue="$2" issue_body_json="$3" triggered="$4"

  if [[ -z "$branch" || -z "$issue" ]]; then
    log_error "coder_plan_init: branch and issue required"
    return 64
  fi

  local dir
  dir="$(coder_plan_dir "$branch")"
  mkdir -p "$dir"
  local path="$dir/plan-v1.json"
  if [[ -f "$path" ]]; then
    log_error "coder_plan_init: $path already exists; use a fresh branch or remove the plan dir"
    return 1
  fi

  # Extract AC bullets from the issue body. Looks under common headers and
  # for Given/When/Then blocks. The agent will refine; this is a best-effort
  # bootstrap.
  local issue_body
  issue_body="$(jq -r '.body // ""' <<<"$issue_body_json" 2>/dev/null || true)"
  local -a ac_bullets=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && ac_bullets+=("$line")
  done < <(_extract_ac_bullets "$issue_body")

  # Build acceptance_criteria array (use shell to assemble JSON safely via jq)
  local ac_json='[]'
  local i=0
  local b
  for b in "${ac_bullets[@]}"; do
    i=$((i + 1))
    ac_json="$(jq --arg id "AC-$i" --arg text "$b" \
      '. + [{id: $id, text: $text, planned_test: "", planned_code: "", commit: "", status: "pending"}]' \
      <<<"$ac_json")"
  done

  # invariants_considered from triggered-invariants CSV
  local inv_json='[]'
  if [[ -n "$triggered" ]]; then
    local IFS=','
    local -a inv_ids=($triggered)
    IFS=$' \t\n'
    local id
    for id in "${inv_ids[@]}"; do
      [[ -z "$id" ]] && continue
      inv_json="$(jq --arg id "$id" \
        '. + [{id: $id, rule: "", approach: "", status: "pending"}]' \
        <<<"$inv_json")"
    done
  fi

  jq -n \
    --argjson issue "$issue" \
    --arg branch "$branch" \
    --argjson acs "$ac_json" \
    --argjson invs "$inv_json" \
    '{
      issue: $issue,
      branch: $branch,
      feasibility: {
        ac_clear: "unknown",
        reversibility: "unknown",
        high_risk_paths: null,
        test_path_clear: "unknown",
        size_estimate: "unknown"
      },
      acceptance_criteria: $acs,
      invariants_considered: $invs,
      scope_envelope: [],
      support_files: [],
      risks: []
    }' > "$path"

  printf '%s\n' "$path"
}

# coder_plan_render <plan-path> — emit Markdown segments for inclusion in
# the PR body. Stdout layout:
#   ## AC mapping table ... markers ...
# Each section has an explicit HTML marker so Reviewer + merge gate can
# parse without ambiguity.
coder_plan_render() {
  local plan="$1"
  if [[ ! -f "$plan" ]]; then
    log_error "coder_plan_render: plan not found: $plan"
    return 64
  fi

  # AC mapping table. Escape `|` in cell content to `\|` so issue text
  # containing pipes doesn't break the table structure.
  printf '## AC mapping\n\n'
  printf '| AC | Description | Test | Code | Commit |\n'
  printf '|----|-------------|------|------|--------|\n'
  jq -r '
    def esc: gsub("\\|"; "\\|");
    .acceptance_criteria[]
    | "| \(.id|esc) | \(.text|esc) | \(.planned_test|esc) | \(.planned_code|esc) | \(.commit|esc) |"
  ' "$plan"
  printf '\n'

  # Support files
  local support_count
  support_count="$(jq -r '.support_files | length' "$plan")"
  if [[ "$support_count" -gt 0 ]]; then
    printf '## Support files\n\n'
    jq -r '.support_files[] | "- `\(.)`"' "$plan"
    printf '\n'
  fi

  # Risks
  printf '## Risks\n\n'
  local risks_csv
  risks_csv="$(jq -r '
    [.risks[] | select(.category != "none") | .category] | unique | join(",")
  ' "$plan")"
  printf '<!-- coding-flows:risks categories=%s -->\n\n' "$risks_csv"
  printf '| Category | Description | Mitigation |\n'
  printf '|----------|-------------|------------|\n'
  if [[ "$(jq -r '.risks | length' "$plan")" -eq 0 ]]; then
    printf '| none | — | — |\n'
  else
    jq -r '
      def esc: gsub("\\|"; "\\|");
      .risks[]
      | "| \(.category|esc) | \(.description|esc) | \(.mitigation|esc) |"
    ' "$plan"
  fi
  printf '\n'

  # Coder self-check marker
  local invs_csv
  invs_csv="$(jq -r '
    [.invariants_considered[] | select(.status != "pending") | .id] | unique | join(",")
  ' "$plan")"
  printf '<!-- coding-flows:coder-self-check invariants-considered=%s -->\n' "$invs_csv"
}

# coder_plan_validate <plan-path> — sanity-check before push. Emits findings
# on stderr and returns 1 on any blocking issue.
coder_plan_validate() {
  local plan="$1"
  if [[ ! -f "$plan" ]]; then
    log_error "coder_plan_validate: plan not found: $plan"
    return 64
  fi

  local issues=0

  # Feasibility: any "no" / "hard" / "partial" is a soft signal but
  # not blocking — the agent may explicitly proceed. Warn only.
  local feas
  feas="$(jq -r '
    [.feasibility | to_entries[] | select(.value == "no" or .value == "hard" or .value == "partial") | .key] | join(",")
  ' "$plan")"
  if [[ -n "$feas" ]]; then
    log_warn "coder_plan_validate: feasibility flags raised: $feas (consider clarifying with the issue author)"
  fi

  # AC rows: every row must have non-empty planned_test, planned_code, commit, and status=done.
  local ac_incomplete
  ac_incomplete="$(jq -r '
    [.acceptance_criteria[]
     | select(
         (.planned_test // "") == "" or
         (.planned_code // "") == "" or
         (.commit // "") == "" or
         .status != "done"
       )
     | .id
    ] | join(",")
  ' "$plan")"
  if [[ -n "$ac_incomplete" ]]; then
    log_error "coder_plan_validate: AC rows incomplete: $ac_incomplete"
    issues=$((issues + 1))
  fi

  # Invariants: every row's status must be 'respected' or 'n-a'.
  local inv_incomplete
  inv_incomplete="$(jq -r '
    [.invariants_considered[] | select(.status != "respected" and .status != "n-a") | .id] | join(",")
  ' "$plan")"
  if [[ -n "$inv_incomplete" ]]; then
    log_error "coder_plan_validate: invariants not addressed: $inv_incomplete"
    issues=$((issues + 1))
  fi

  # Risks: must be non-empty (use a single 'none' row if no risks apply).
  local risks_count
  risks_count="$(jq -r '.risks | length' "$plan")"
  if [[ "$risks_count" -eq 0 ]]; then
    log_error "coder_plan_validate: risks section empty (add explicit 'none' row if no risks apply)"
    issues=$((issues + 1))
  fi

  [[ $issues -gt 0 ]] && return 1
  return 0
}

# _extract_ac_bullets <issue-body-markdown> — emit one AC text per line.
_extract_ac_bullets() {
  awk '
    BEGIN { in_sec=0 }
    /^##[[:space:]]/ {
      lc = tolower($0)
      if (lc ~ /(acceptance[[:space:]]+criteria|requirements|^## *acs([[:space:]]|$))/) {
        in_sec = 1
      } else {
        in_sec = 0
      }
      next
    }
    in_sec && /^[[:space:]]*[-*][[:space:]]+/ {
      sub(/^[[:space:]]*[-*][[:space:]]+/, "")
      sub(/[[:space:]]*$/, "")
      print
    }
    # Given/When/Then blocks (looser: any line beginning with Given/When/Then is folded together)
    /^[[:space:]]*Given[[:space:]]/ {
      gwt = $0
      while ((getline next_line) > 0) {
        if (next_line ~ /^[[:space:]]*(When|Then|And)[[:space:]]/) {
          gwt = gwt " " next_line
        } else {
          print gwt
          gwt = ""
          if (next_line ~ /^[[:space:]]*Given[[:space:]]/) {
            gwt = next_line
          }
          break
        }
      }
      if (gwt != "") print gwt
    }
  ' <<<"$1"
}
