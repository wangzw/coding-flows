# Coder cycle

Coder is **serial within a single cycle invocation** — only one issue / PR's
build or test runs at a time, because local resources (CI runners, DB
containers, ports) don't tolerate parallelism. But it is **multi-task across
items in the same cycle**: whenever an item rotates out of the Coder's hands
(push → CI; PR opened → Reviewer; merge done), the cycle moves to the next
actionable item. Work-stealing, not parallel.

Iteration frequency is set by the wrapping scheduler
(`slock reminder schedule --recur "every Xm"` or `/loop Xm`), not by this
skill. One cycle invocation never sleeps waiting on CI — it just rotates.

## Pre-flight (every cycle)

The pre-flight runs from the main checkout (or any worktree of the same repo;
config and identity resolution work from either via `find_repo_config` +
`gh repo view`).

1. `gh auth status` matches `acting_user` (or current authed user). Otherwise
   abort with `auth-broken`.
2. cwd is inside a GitHub repo.
3. **Main-checkout `git status` is not blocking.** With per-issue worktrees,
   the main checkout's state is irrelevant to per-item work. Only the
   target worktree's state matters; this is checked per-item in Phase B/E.
4. Run `scripts/coding-flows-worktree-prune` to retire worktrees whose PRs have
   merged or closed since the last cycle (best-effort, ignored on `gh`
   failures).

## Phase A — Enumerate and classify work

One batched query each:

```
gh issue list --assignee <acting_user> --state open \
  --json number,title,labels,body,author,url
gh pr list --assignee <acting_user> --state open \
  --json number,title,headRefName,headRefOid,labels,reviewDecision,statusCheckRollup,isDraft
```

For each PR, derive a **state** that determines the Coder's next action:

| State | Condition (PR) | Coder action |
|-------|----------------|--------------|
| `address-changes` | Most recent reviewer review is `CHANGES_REQUESTED` and not superseded by a later same-author `/lgtm` | Phase E |
| `address-ci-fail` | `statusCheckRollup` contains a `FAILURE`/`ERROR`/`CANCELLED` | Phase E (fix-and-push) |
| `ready-to-merge` | `scripts/coding-flows-merge --dry-run` would exit 0 | Phase F |
| `wait-ci` | CI in progress | **skip** (record in summary) |
| `wait-review` | CI green, no LGTM yet, no CHANGES_REQUESTED to address | **skip** |
| `wait-lgtm-fresh` | LGTM exists but bound to older head SHA (already pushed) | **skip** |

For each issue, derive:

| State | Condition (issue) | Coder action |
|-------|-------------------|--------------|
| `clarify` | Issue is too ambiguous to act on; no clarification posted yet OR `needs-human` was removed by human after a response | Phase A1 (clarify) |
| `start` | Issue clear, no PR yet | Phase A1 → B → C → D |
| `wait-author` | Already asked clarification; no human response yet | **skip** |

### Priority (within actionable states)

Process actionable items in this order — older items break ties within
the same state:

1. `address-changes` — reviewers waiting on me
2. `address-ci-fail` — my own failed CI
3. `ready-to-merge` — close out completed work
4. `start` (new issue) — pull in fresh work
5. `clarify` (ambiguous issue) — escalate

This favors **finishing in-flight work** over starting new work. A backlog
of half-finished PRs is worse than a backlog of un-started issues.

## Rotation points (when an item exits this cycle)

Each item's processing within a cycle ends at one of these points — the
Coder then moves to the next actionable item without waiting:

| Item type | Rotation point |
|-----------|----------------|
| `start` | After Phase D (`gh pr create` succeeded) — CI is now running |
| `address-changes` / `address-ci-fail` | After `git push` — CI is now running |
| `ready-to-merge` | After `coding-flows-merge` returns (success or specific gate failure) |
| `clarify` | After posting the clarification comment + `needs-human` label |

Never block the cycle waiting on CI or Reviewer. The next cycle, fired by
the scheduler N minutes later, picks up changes.

## Phase A1 — Feasibility check + plan bootstrap (per issue)

For each `start` or `clarify` issue, before opening a worktree:

1. Read the issue body. Extract bullets from `## Acceptance Criteria`,
   `## Requirements`, `## ACs`, or any Given/When/Then block. If a feature
   spec is linked, Read it too.
2. **Apply the feasibility rubric** — these fields populate
   `plan.feasibility` once a plan exists:
   - `ac_clear`: yes | partial | no
   - `reversibility`: trivial | moderate | hard
   - `high_risk_paths`: boolean (touches auth/migration/billing/etc.)
   - `test_path_clear`: yes | needs-design
   - `size_estimate`: small (≤200) | medium (200–1000) | large (>1000)
3. **If any "no" / "hard" / "partial"** → trigger `needs-human` with
   reason `ambiguous-issue` (or `scope-too-large` if size is the issue).
   Post a single clarification comment listing the specific blockers and
   the interpretations you would default to. Exit the item.
   - On subsequent cycles, the issue stays in `clarify` state.
   - Use `coding-flows-clarification-status <issue>` to determine if the issue
     has progressed to `responded`. Only then re-enter Phase A1; otherwise
     remain parked.

## Phase A2 — Bootstrap the Coder plan + worktree

Once feasibility passes:

```
WT="$(coding-flows-worktree-create <type>/<issue>-<slug> origin/<base>)"
cd "$WT"
coding-flows-coder-plan init <type>/<issue>-<slug> <issue-number>
```

The `init` subcommand:

- Extracts AC bullets from the issue and pre-fills
  `plan-v1.acceptance_criteria[]` (each row gets `id=AC-N`, blank
  planned_test/code/commit, `status=pending`).
- Runs `triggered_invariants` against the working tree's diff to populate
  `plan-v1.invariants_considered[]`. At Phase B's start the diff is
  typically empty, so this array begins empty too; the agent must append
  invariant rows manually as they discover the diff touches relevant
  paths. The `--files-file` flag accepts a pre-supplied path list when
  the agent already knows what files will change.
- Leaves `feasibility`, `scope_envelope`, `support_files`, `risks` for
  the agent to complete during Phase B.

The plan lives at
`~/.cache/coding-flows/<owner>/<repo>/coder/<branch-slug>/plan-v1.json`.

## Phase B — Open a worktree and implement

```
WT="$(coding-flows-worktree-create <type>/<issue-number>-<slug> origin/<base>)"
cd "$WT"
```

The branch name is `<conventional-commits-type>/<issue-number>-<slug>` —
type matches the issue's nature (`feat`, `fix`, `chore`, `docs`, ...), slug
≤ 5 lowercase hyphenated words. The worktree lives at
`<parent-of-main-repo>/<branch-slug>` — i.e. as a sibling of the main
checkout (override via `.coding-flows.json` `worktree.root`).

**Per-worktree pre-flight**: now is when `git status` matters. If this
worktree has uncommitted changes from a previous interrupted cycle, the
Coder must resolve them (commit / discard) before continuing.

**Mandatory scope load**: run `coding-flows-detect-scope --base origin/<base>` and
Read each returned skill / standard before writing code.

Make the change. Keep the diff tight and on-topic; file follow-up issues
for unrelated cleanups. Commit using the project's commit convention.

### Local Coder plan (driven by `coding-flows-coder-plan`)

As you write code, update the plan JSON directly (it's an ordinary file at
the path emitted by `coding-flows-coder-plan path <branch>`):

- For each AC row: fill `planned_test`, `planned_code`, `commit`, flip
  `status` to `done`.
- For each invariant row: fill `approach`, flip `status` to `respected`
  (or `n-a` if the diff doesn't actually touch the invariant's domain).
- Append to `scope_envelope` as you decide which files this PR will touch.
- Append `support_files` for incidental edits you cannot fold into an AC
  (e.g., regenerated `openapi.json` that's not the AC's focus).
- Append `risks` entries — at minimum a single `{category: none, ...}` row
  if the change truly carries no operational risk.

Phase D renders the plan into PR body Markdown; Phase D's pre-push step
runs `coding-flows-coder-plan validate <branch>` and refuses to push if any
row is still incomplete.

## Phase C — Local self-check (mandatory)

In the worktree:

1. `make lint` (or detected equivalent).
2. `make test`.
3. `make build` if cheap.

Pre-existing failures → note in PR body. Flaky → apply
[flaky-test-policy.md](flaky-test-policy.md). Genuinely broken main → file
issue, abort the item with `broken-main`.

## Phase D — Validate, render, push, open the PR

```
# Refuse to push if the plan is incomplete
coding-flows-coder-plan validate <branch>

# Render plan → PR body sections
RENDERED="$(coding-flows-coder-plan render <branch>)"

git push -u origin <branch>
gh pr create --assignee <acting_user> --title "..." --body "$(printf '%s\n\nCloses #%s\n\n%s\n' "$SUMMARY" "$ISSUE" "$RENDERED")"
```

The full PR body uses [templates/pr-body.md](../templates/pr-body.md) and
includes:

1. Summary (1-3 paragraphs).
2. `Closes #<issue>` (or Fixes / Resolves).
3. `## AC mapping` table (from plan render) — Gate 3.
4. `## Support files` section (from plan render, if non-empty) — feeds Gate 10.
5. `## Risks` table + `<!-- coding-flows:risks categories=... -->` marker —
   Gate 9.
6. `<!-- coding-flows:coder-self-check invariants-considered=... -->` marker —
   visible to Reviewer to see what the Coder claims to have considered.
7. Project's PR template content if present.

After opening, post a one-line acknowledgment on the linked issue:
```
gh issue comment <N> --body "Opened #<PR> to address this — please review if the approach diverges."
```

**Rotation**: the PR is now waiting on CI / Reviewer. Move to the next
actionable item.

## Phase E — Address reviewer feedback / CI failure

For PRs in `address-changes` or `address-ci-fail` state:

```
WT="$(coding-flows-worktree-path <branch>)"
cd "$WT"
```

If the worktree no longer exists (previous cycle deleted it, or first time
this PR is processed since restart) → re-create with the existing branch.
`coding-flows-worktree-create` automatically resumes when the branch already
exists locally but has no active worktree:

```
coding-flows-worktree-create <branch> origin/<base>
```

The script attaches a new worktree to the existing branch in place of
creating a fresh one. If the branch was deleted locally too, it fetches
the remote branch and creates a new local branch from it.

Then:

- Read open review threads, each unaddressed CHANGES_REQUESTED comment,
  and any CI failure logs.
- For each, choose: push a fix + reply with commit SHA, **or** push back
  with reasoning.
- Update the local plan (verdicts + scope envelope) accordingly.
- Local self-check (`make lint`/`test`/`build`).
- `git push`.

If review-feedback prose has line-anchored points, use inline reply via
`gh api` — see [pr-comment-format.md](pr-comment-format.md).

**Rotation**: after `git push` the PR is back in `wait-ci` / `wait-review`.

## Phase F — Merge (when `ready-to-merge`)

```
cd "$(coding-flows-worktree-path <branch>)"
scripts/coding-flows-merge <PR>
```

Never call `gh pr merge` directly. The script enforces all 8 gates, and on
success cleans up: removes the worktree, deletes the local branch, clears
`~/.cache/coding-flows/<owner>/<repo>/pr-<N>/`. Use `--keep-worktree` if you
want to inspect the branch state post-merge.

After merge, the script posts a one-line "Shipped" comment on the linked
issue. The item is complete.

## Parallel-cycle safety

If another cycle is already operating on the same branch's worktree (e.g.
two `/loop` invocations overlap), the second cycle should:

- Skip `start` and `address-*` actions for that PR.
- Still allow itself to act on **different** PRs / issues whose worktrees
  it doesn't share.

Locking is best-effort via the worktree directory: a `.coding-flows.lock` file
inside the worktree marks "in use". Stale locks (older than 30 min) are
ignored. Lock writer: `flock(1)` with a non-blocking `-n` flag.

## Hard guardrails (Coder-specific)

Inherited from SKILL.md, plus:

- **One worktree per branch.** Never `git checkout <other-branch>` inside a
  worktree — every branch gets its own worktree (or none).
- **Never abandon a worktree with uncommitted changes.** Commit, stash to
  a named branch, or explicitly `coding-flows-worktree-remove --force`.
- **Never delete the main checkout's branch.** Worktree cleanup only
  removes managed worktrees under `worktree_root`.
