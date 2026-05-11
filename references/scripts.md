# Scripts reference

All scripts live in `scripts/`. Each has a pure verification lib at
`scripts/lib/<name>.sh` that takes JSON via stdin or argument, so tests can
exercise the logic without live GitHub calls.

## Conventions

- Shebang: `#!/usr/bin/env bash`
- `set -euo pipefail` in every script.
- Source `scripts/lib/common.sh` for shared helpers.
- Exit codes:
  - `0` — success.
  - `1` — generic "check failed" (missing data, gate failed).
  - `2` — stale state (e.g. LGTM bound to old SHA).
  - `3` — dual-reviewer requirement unmet.
  - `64` — usage error (bad args).
  - `65` — config error (`.coding-flows.json` malformed).
  - `69` — service unavailable (`gh` auth, network).

## Dependencies

- `gh` (GitHub CLI), authenticated.
- `jq` (≥1.6).
- `bash` (≥4.0).
- POSIX coreutils.

No Python, no Node, no yq — keeps install footprint minimal.

## Scripts

### `coding-flows-detect-scope`

```
coding-flows-detect-scope [--pr <N> | --base <branch>]
coding-flows-detect-scope --from-file <changed-files-json>
```

Lists which `scope_rules` from `.coding-flows.json` are triggered by the diff.
Output: one rule ID per line, plus a tabbed list of `skills:` and `standards:`
to read.

Tests: `tests/test_detect_scope.sh`.

### `coding-flows-label-risk`

```
coding-flows-label-risk <PR>
coding-flows-label-risk --from-file <pr-view-json> --dry-run
```

Evaluates `high_risk_rules` against the PR's changed files + size; applies
labels via `gh pr edit --add-label`. `--dry-run` prints labels that would be
applied without modifying the PR.

Tests: `tests/test_label_risk.sh`.

### `coding-flows-verify-risks`

```
coding-flows-verify-risks <PR>
coding-flows-verify-risks --from-file <pr-view-json>
```

Validates the `## Risks` section per Gate 9. Emits
`RISKS_CATEGORIES=<csv>` (non-`none` categories declared by the Coder).
Tests: `tests/test_verify_risks.sh`.

### `coding-flows-verify-scope-envelope`

```
coding-flows-verify-scope-envelope <PR>
coding-flows-verify-scope-envelope --from-file <pr-view-json>
```

Validates Gate 10. Emits `SCOPE_CLAIMED=<n>` and
`SCOPE_UNCLAIMED=<csv>` (paths not covered by AC mapping, Support files,
or exclude globs). Tests: `tests/test_verify_scope_envelope.sh`.

### `coding-flows-coder-plan`

```
coding-flows-coder-plan init     <branch> <issue> [--issue-file <p>] [--files-file <p>]
coding-flows-coder-plan path     <branch>
coding-flows-coder-plan render   <branch>
coding-flows-coder-plan validate <branch>
```

Manages the Coder's local working plan
(`$(repo_state_dir)/coder/<branch-slug>/plan-vN.json`). `render` produces
the AC mapping table, Support files, and Risks segments for inclusion in
the PR body. `validate` sanity-checks the plan before push (every AC
row must be `done` with non-blank planned_test/code/commit; every
invariant must be `respected`/`n-a`; risks list non-empty).

Tests: `tests/test_coder_plan.sh`.

### `coding-flows-clarification-status`

```
coding-flows-clarification-status <issue#>
coding-flows-clarification-status --from-file <issue-view-json>
```

Inspects an issue's comments and labels and emits
`STATUS=not-asked|awaiting|responded|timeout`, `ASKED_AT=<iso8601>`,
`AUTHOR_RESPONSE_AT=<iso8601>`, `ROUNDS=<n>`. Used by Coder Phase A to
decide whether a `clarify`-state issue is now actionable (`responded`) or
still parked (`awaiting`). Timeout threshold via
`CLARIFICATION_TIMEOUT_ROUNDS` env (default 10).

Tests: `tests/test_clarification_status.sh`.

### `coding-flows-verify-ac-mapping`

```
coding-flows-verify-ac-mapping <PR>
coding-flows-verify-ac-mapping --from-file <pr-view-json>
```

Parses the PR body for `## AC mapping` table. Validates per [ac-mapping.md](
ac-mapping.md). Prints per-row status; exits 0 only if all rows pass.

Tests: `tests/test_verify_ac_mapping.sh`.

### `coding-flows-check-lgtm`

```
coding-flows-check-lgtm <PR>
coding-flows-check-lgtm --from-file <pr-view-json>
```

Scans PR comments newest-first for valid `/lgtm` markers. A marker is valid
only when all four fields are present: `sha`, `reviewer`, `acs`,
`invariants` (values may be empty for `acs`/`invariants`).

Outputs `LGTM_COUNT=N`, `LGTM_REVIEWERS=<csv>`, `LGTM_SHA=<sha>`,
`LGTM_ACS=<csv-union>`, `LGTM_INVARIANTS=<csv-union>`, `STALE=<yes|no>`.

Exit codes:

- 0 — at least one `/lgtm` bound to current head.
- 1 — no `/lgtm` with valid marker found.
- 2 — most recent `/lgtm` is stale (different SHA).

Tests: `tests/test_check_lgtm.sh`.

### `coding-flows-verify-lgtm-coverage`

```
coding-flows-verify-lgtm-coverage <PR>
coding-flows-verify-lgtm-coverage --from-file <pr-view-json>
```

Composes `check_lgtm`, `verify_ac_mapping`, and `triggered_invariants`. Demands:

- `LGTM_ACS` (union of `acs=` claims) ⊇ AC IDs from the AC mapping table.
- `LGTM_INVARIANTS` ⊇ invariant IDs triggered by the diff per
  `.coding-flows.json` `invariants[].triggered_by_paths`.

Outputs `COVERAGE_MISSING_ACS=<csv>`, `COVERAGE_MISSING_INVARIANTS=<csv>`.

Exit codes:

- 0 — coverage complete.
- 1 — coverage gap (specific missing IDs in stderr + stdout).
- 2 — prerequisite failed (no current LGTM, AC mapping invalid).

Tests: `tests/test_verify_lgtm_coverage.sh`.

### `coding-flows-worktree-*`

A small family of scripts manages per-issue worktrees. Full design:
[worktrees.md](worktrees.md).

```
coding-flows-worktree-path <branch>                     # pure path lookup
coding-flows-worktree-list                              # path \t branch \t sha
coding-flows-worktree-create <branch> [<base-ref>]      # create + emit path
coding-flows-worktree-sync [<branch>]                   # rebase on base ref
coding-flows-worktree-remove <branch> [--force]         # tear down
coding-flows-worktree-prune                             # remove merged/closed PRs' worktrees
```

Tests: `tests/test_worktree.sh`.

### `coding-flows-classify-pr`

```
coding-flows-classify-pr <PR>
coding-flows-classify-pr --from-file <pr-view-json>
```

Emits `PR_STATE=<state>` for use during Coder Phase A. State is one of:
`address-changes`, `address-ci-fail`, `ready-to-merge`, `wait-ci`,
`wait-review`, `wait-lgtm-fresh` — see
[coder-cycle.md](coder-cycle.md) for definitions and processing order.

**Use this script — don't inspect `gh pr view` fields directly.**
`/lgtm` is a comment marker, not a formal review, so `reviewDecision`
stays `""` regardless of how many LGTMs the PR carries. The classify
script wraps CHANGES_REQUESTED supersession logic + CI status + `check_lgtm`
exit codes into one authoritative answer.

For `ready-to-merge`, follow up with `coding-flows-merge --dry-run`
before actually merging — `ready-to-merge` here only confirms CI + LGTM;
other gates (AC mapping, scope envelope, risks, etc.) can still fail.

Tests: `tests/test_classify_pr.sh`.

### `coding-flows-fetch-for-reviewer`

```
coding-flows-fetch-for-reviewer <PR> --reviewer <id>
coding-flows-fetch-for-reviewer --from-file <pr-view-json> --reviewer <id>
```

Emits a PR view JSON with comments authored by other reviewers' markers
filtered out. Used by the dual-reviewer dispatch to make reviewer-2 blind
to reviewer-1's `/lgtm` claim. See [high-risk-pr.md](high-risk-pr.md) for
the limitations on what blindness this can enforce (review bodies are not
filtered).

Tests: `tests/test_filter_reviewer.sh` (library) + `tests/test_cli_smoke.sh`
(CLI).

### `coding-flows-merge`

```
coding-flows-merge <PR>
coding-flows-merge --from-file <pr-view-json> --dry-run
```

Composes all gate checks and, only if every gate passes, calls
`gh pr merge`. `--dry-run` runs all checks but skips the actual merge.

Exit codes map to gate failures:

| Code | Reason                       |
|------|------------------------------|
| 0    | merged                       |
| 10   | `ci-failing`                 |
| 11   | `linked-issue-missing`       |
| 12   | `ac-mapping-incomplete`      |
| 13   | `lgtm-coverage-incomplete`   |
| 14   | `stale-lgtm`                 |
| 15   | `lgtm-missing`               |
| 16   | `unresolved-threads`         |
| 17   | `merge-method-disallowed`    |
| 18   | `dual-lgtm-missing`          |
| 19   | `scope-envelope-violation`   |
| 20   | `risks-missing-or-malformed` |
| 69   | `auth-broken` or `gh` error  |

Tests: `tests/test_merge.sh`.

## Test runner

```
bash tests/run-all.sh
```

Discovers and runs `tests/test_*.sh`. Each test file is a self-contained bash
script. Sources `tests/lib/assert.sh`. Uses fixtures from
`tests/fixtures/`. No external dependencies beyond `jq` and `bash`.

CI integration: a project using coding-flows can add `bash
~/.claude/skills/coding-flows/tests/run-all.sh` to its CI pipeline (or to its own
test command) to verify the skill installation.
