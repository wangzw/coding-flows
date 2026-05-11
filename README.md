# coding-flows

A two-role GitHub workflow skill for [Claude Code](https://claude.ai/code).
A **Coder** agent turns assigned issues into PRs; a **Reviewer** agent
audits PRs against project standards until they meet a hard merge bar.
Multiple PRs and issues are work-stolen within a single cycle — when one
item rotates out to CI or to the Reviewer, the Coder switches to the next
actionable item rather than blocking.

The merge bar is **mechanically enforced** by `coding-flows-merge`, not
inferred from a checklist. Ten gates run before any `gh pr merge`:
CI green; linked issue; complete AC mapping; LGTM coverage of every AC,
triggered invariant, and declared risk; LGTM bound to current head;
unresolved threads cleared; allowed merge method; dual LGTM for
high-risk PRs; structured `## Risks` section; and a scope envelope that
proves every changed file is claimed.

## Install

Clone into your Claude Code skills directory:

```sh
git clone https://github.com/wangzw/coding-flows ~/.claude/skills/coding-flows
```

Verify the install with the test suite:

```sh
bash ~/.claude/skills/coding-flows/tests/run-all.sh
```

233 tests should pass — they exercise every gate, parser, and lifecycle
script without making any real `gh` calls.

### Dependencies

- `gh` (GitHub CLI), authenticated for your repos
- `jq` (≥ 1.6)
- `bash` (≥ 4.0) + POSIX coreutils
- `git` (≥ 2.20, for worktree support)

No Python, no Node, no `yq`.

## Usage

Inside Claude Code, in a checkout of a GitHub repo:

```
# One Coder pass: turn unassigned issues into PRs, address review feedback,
# merge anything that meets the bar.
run coding-flows as coder

# One Reviewer pass: audit every PR assigned to you against the merge bar.
run coding-flows as reviewer
```

Each invocation runs **one cycle** (work-stealing through all actionable
items). Wrap with `slock reminder` or `/loop` for continuous monitoring:

```
slock reminder schedule \
  --title "coding-flows coder on my-repo" \
  --recur "every 10 minutes" \
  --message "run coding-flows as coder"
```

## Configuration — `.coding-flows.json`

Drop a `.coding-flows.json` at your repo root. Everything is optional;
[references/config-schema.md](references/config-schema.md) documents the
full schema with defaults.

Minimal example:

```json
{
  "acting_user": "octocat",
  "merge": {"method": "squash"},
  "scope_rules": [
    {"paths": ["backend/**"], "skills": ["backend-coding-standards"]},
    {"paths": ["frontend/**"], "skills": ["frontend-coding-standards"]}
  ],
  "invariants": [
    {
      "id": "events-before-publish",
      "rule": "every nats.Publish must be preceded by eventstore write",
      "triggered_by_paths": ["**/eventstore/**", "**/messaging/**"]
    }
  ],
  "high_risk_rules": [
    {"paths": ["**/auth/**", "**/security/**"], "label": "high-risk:auth"},
    {"paths": ["migrations/**"], "label": "high-risk:migration"}
  ]
}
```

A fuller version with categories, exclusions, and tuning knobs lives in
[`examples/coding-flows.example.json`](examples/coding-flows.example.json).

## Architecture

Two cycles, both running with strict adversarial discipline against the
same project. All structural artifacts (review plans, coder plans) live
on disk under `~/.cache/coding-flows/<owner>/<repo>/` — **never** posted
to the PR. The only PR-visible artifacts are short, machine-parseable
markers in normal review/comment surfaces.

### Coder cycle

Per-issue **git worktree** isolation. Each cycle invocation enumerates
every assigned PR and issue, classifies them by state, and processes
actionable items in a **strict two-stage order — PRs first, then
issues**. Detailed flow:
[`references/coder-cycle.md`](references/coder-cycle.md).

```
Phase A   Enumerate + classify   (PRs first, then issues)
            │
Stage 1 ──► Process actionable PRs in priority order:
            1. address-changes   (Reviewer marked CHANGES_REQUESTED)
            2. address-ci-fail   (own CI broke; push fix)
            3. ready-to-merge    (coding-flows-merge → gates + cleanup)
            │
            │  (rotate to next PR when this one hands off to CI/Reviewer)
            ▼
Stage 2 ──► Only after every PR is processed or in a waiting state:
            4. start             (new issue → worktree + plan + PR)
            5. clarify           (ambiguous issue → post question)

Per-item phases (Stage-1 PRs use E/F; Stage-2 issues use A1–D):
  Phase A1  Feasibility + plan bootstrap (per issue, gated by rubric)
  Phase A2  Open worktree + init plan
  Phase B   Implement (update plan as you go)
  Phase C   Local lint/test/build
  Phase D   Validate → render → push     (PR body comes from rendered plan)
  Phase E   Address review/CI feedback
  Phase F   coding-flows-merge           (gates + worktree/cache cleanup)
```

### Reviewer cycle

Default-deny adversarial stance. Builds a local review plan; publishes
only `/lgtm` with a coverage marker (or `--request-changes` with prose +
inline comments). Detailed flow:
[`references/reviewer-cycle.md`](references/reviewer-cycle.md).

The LGTM marker is compact and machine-verifiable:

```
/lgtm

<!-- coding-flows:lgtm sha=<head> reviewer=<id> acs=AC-1,AC-2 invariants=events-before-publish risks-reviewed=migration -->
Verified AC-1/AC-2 against env_test.go; confirmed events-before-publish
in sse/broker.go:88; migration backfill plan is safe under concurrent
writes. CI green.
```

For PRs labeled `high-risk:*`, the skill dispatches a **second Reviewer
agent** with the comments filtered through
`coding-flows-fetch-for-reviewer`, so reviewer-2 cannot see reviewer-1's
findings before reaching its own conclusion.

## What the merge gate enforces

| Gate | Subject | Validator |
|------|---------|-----------|
| 1 | CI green on current head | `gh pr checks` (after flaky-test policy) |
| 2 | Linked issue (`Closes #N` etc.) | regex |
| 3 | AC mapping table complete + commit SHAs in PR | `coding-flows-verify-ac-mapping` |
| 4 | Union of `/lgtm` `acs=` / `invariants=` / `risks-reviewed=` covers AC mapping + triggered invariants + declared risks | `coding-flows-verify-lgtm-coverage` |
| 5 | Most-recent `/lgtm` bound to current head | `coding-flows-check-lgtm` |
| 6 | No CHANGES_REQUESTED review un-superseded by later `/lgtm` | `gh-flow-merge` Gate 6 |
| 7 | Configured merge method allowed by repo | `coding-flows-merge` (queries `gh repo view`) |
| 8 | Dual LGTM if any `high-risk:*` label | `coding-flows-merge` Gate 8 |
| 9 | `## Risks` table + marker | `coding-flows-verify-risks` |
| 10 | Every changed file claimed by AC mapping / Support files / excludes | `coding-flows-verify-scope-envelope` |
| 11 | No unchecked `- [ ]` items in `## Test plan` | `coding-flows-verify-test-plan` |
| 12 | PR body AC mapping has ≥ rows as linked issue's `## Acceptance criteria` | `coding-flows-verify-issue-ac` |

Full reference: [`references/merge-gates.md`](references/merge-gates.md).

## Scripts

All under `scripts/`. Each has a pure verification lib at `scripts/lib/`
that takes JSON via stdin/arg, so tests run without `gh`.

| Script | Purpose |
|--------|---------|
| `coding-flows-detect-scope` | Skills/standards triggered by a diff |
| `coding-flows-label-risk` | Apply `high-risk:*` labels |
| `coding-flows-verify-ac-mapping` | Parse + validate AC mapping table |
| `coding-flows-verify-risks` | Parse + validate `## Risks` section |
| `coding-flows-verify-scope-envelope` | Confirm changed files are claimed |
| `coding-flows-check-lgtm` | Parse `/lgtm` markers; head-binding |
| `coding-flows-verify-lgtm-coverage` | Coverage union vs Coder declarations |
| `coding-flows-fetch-for-reviewer` | Comment-filtered PR view (dual-reviewer blindness) |
| `coding-flows-coder-plan` | `init` / `path` / `render` / `validate` |
| `coding-flows-clarification-status` | Issue clarification state machine |
| `coding-flows-worktree-{create,list,path,remove,prune,sync}` | Per-issue worktree lifecycle |
| `coding-flows-merge` | Compose all gates → `gh pr merge` (hard blocker) |

Detail: [`references/scripts.md`](references/scripts.md).

## Testing

```sh
bash tests/run-all.sh
```

233 tests across 15 test files. Each test file exits 0 only when every
assertion passes; the runner reports aggregate pass/fail and flags any
file that crashed early.

Tests use fixture JSON files (`tests/fixtures/`) for PR views, file
lists, and config — no live `gh` or GitHub API calls.

## License

MIT — see [LICENSE](LICENSE).
