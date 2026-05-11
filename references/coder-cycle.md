# Coder cycle

Coder is **serial within a single cycle invocation** — only one issue / PR's
build or test runs at a time, because local resources (CI runners, DB
containers, ports) don't tolerate parallelism. But it is **multi-task across
items in the same cycle**: whenever an item rotates out of the Coder's hands
(push → CI; PR opened → Reviewer; merge done), the cycle moves to the next
actionable item. Work-stealing, not parallel.

## No per-cycle time budget

The scheduler's interval (`/loop 5m`, `--recur "every 5 minutes"`) is the
*polling frequency* — how often the system checks for new work — **not**
a wall-clock budget for the current cycle. A cycle picks up an item and
drives it to its **natural rotation point**:

- `start` → `gh pr create` succeeds (CI is now running, Reviewer can read it)
- `address-changes` / `address-ci-fail` → `git push` succeeds (CI restarts)
- `ready-to-merge` → `coding-flows-merge` returns
- `clarify` → clarification comment posted

If an issue is complex and takes 20 minutes (or longer) to implement,
test, validate, and open as a ready PR — **take 20 minutes**. Do not
abandon the work because the scheduler will fire again in 5.

**Overlapping cycle firings** are a scheduler-layer concern, not this
skill's. Use a scheduler that handles overlap by skipping if a prior
invocation is still running (`slock reminder` does this), or set the
polling interval conservatively (10–15 min vs. 5 min) so overlap is
unlikely. The skill does not currently take its own
`.coding-flows.lock` file; the docs in `worktrees.md` mentioning one
are aspirational, not implemented.

In particular, **never push half-finished code or open a draft PR as a
workaround for cycle-length anxiety**. The merge gates assume the
Coder's PR represents complete work for every AC; partial PRs that wait
across cycles for the Coder to "come back later" create stale state
that no gate covers. The Coder either:

- Finishes the item this cycle (taking however long is needed), OR
- Determines the issue is genuinely too large or unclear and triggers
  `needs-human` with reason `ambiguous-issue` / `scope-too-large` — see
  Phase A1.

## Wrapping scheduler

Iteration frequency is set by the wrapping scheduler
(`slock reminder schedule --recur "every Xm"` or `/loop Xm`), not by
this skill. The scheduler's only job is to fire periodically; the cycle
itself decides how long to spend.

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

The cycle runs in two strict **processing** stages — Stage 1 (PRs) and
Stage 2 (issues), see the priority table below. The two `gh` queries
themselves can be issued in any order (or in parallel) — what matters
is that no issue is *processed* until every PR has either been
processed or is in a waiting state.

**Both queries are mandatory, every cycle.** Run both even if Stage 1
ends up with nothing actionable, and run both even if you remember the
issue list from last cycle. Skipping `gh issue list` causes issues to
go unprocessed for many consecutive cycles ("Coder only does PRs"
failure mode observed in transcripts — issues #266, #268, #276–#279
sat untouched for 15+ cycles).

```
gh pr list --assignee <acting_user> --state open \
  --json number,title,headRefName,headRefOid,labels,reviewDecision,statusCheckRollup,isDraft
gh issue list --assignee <acting_user> --state open \
  --json number,title,labels,body,author,url
```

The cycle summary at the end MUST account for **every** PR and **every**
issue returned by these queries — each one appears in exactly one of
`Processed:`, `Skipped:`, or `Needs human:`. If you wrote a cycle
summary with no issue rows at all and `gh issue list` returned ≥1 open
issue assigned to you, that's a bug: you either skipped Stage 2 or
failed to report it. See SKILL.md § "Output protocol" for the exact
output rules.

For each PR, derive a **state** that determines the Coder's next action.
**Run `coding-flows-classify-pr <PR>` to get the state — do NOT classify
by inspecting raw `gh pr view` fields.** In particular:

- `reviewDecision` is always `""` in our flow — `/lgtm` is a comment
  marker, not a formal `gh pr review --approve`.
- `reviews[].state` only captures formal-review actions, not LGTM comments.
- A `labels` containing `lgtm`-ish strings means nothing — gh-flow uses
  comment markers, not labels, for approval.

The classify script wraps the canonical logic (CHANGES_REQUESTED
supersession + CI status + `check_lgtm`) and is the only authoritative
source.

| State | Condition (PR) | Coder action |
|-------|----------------|--------------|
| `wip` | `isDraft: true` | Resume the worktree, finish whatever work the draft was created for, then `gh pr ready <PR>` to flip it to non-draft. Drafts are not a recommended pattern in this skill (the workflow expects fully-formed PRs per "No per-cycle time budget" above); this state exists to handle pre-existing or externally-created drafts gracefully. |
| `address-changes` | Most recent reviewer review is `CHANGES_REQUESTED` and not superseded by a later same-author `/lgtm` | Phase E |
| `address-ci-fail` | `statusCheckRollup` contains a `FAILURE`/`ERROR`/`CANCELLED` | Phase E (fix-and-push) |
| `ready-to-merge` | CI green + current LGTM bound to head; confirm with `coding-flows-merge --dry-run` before merging (other gates may fail) | Phase F |
| `wait-ci` | At least one check is `PENDING`/`IN_PROGRESS`/`QUEUED` | **skip** (record in summary) |
| `wait-review` | CI green, no `/lgtm` marker at all | **skip** |
| `wait-lgtm-fresh` | CI green, `/lgtm` exists but bound to older head SHA (Coder pushed since) | **skip** |

State precedence (when multiple conditions apply): `wip` > `address-changes`
> `address-ci-fail` > `wait-ci` > (LGTM-derived state).

**Advisory comments are not states.** A Reviewer review submitted with
`gh pr review --comment` (not `--request-changes`) does not put the PR
into `address-changes` — it's informational. The Coder may read and act
on such comments at their discretion during a later cycle, but the
merge gates already protect against silently shipping past them: Gate 5
requires an explicit `/lgtm` bound to the head SHA, so a PR with only
`COMMENTED` reviews can never reach merge.

For each issue, derive:

| State | Condition (issue) | Coder action |
|-------|-------------------|--------------|
| `clarify` | Issue is too ambiguous to act on; no clarification posted yet OR `needs-human` was removed by human after a response | Phase A1 (clarify) |
| `start` | Issue clear, no PR yet | Phase A1 → B → C → D |
| `wait-author` | Already asked clarification; no human response yet | **skip** |

### Priority — strict two-stage ordering

**Stage 1 — process ALL actionable PRs first.** Older items break ties
within the same state.

| Sub-priority | State | Why |
|--------------|-------|-----|
| 1 | `address-changes` | Reviewer is blocked on me; addressing review comments is the highest-leverage action because it unblocks an external dependency. |
| 2 | `address-ci-fail` | My own CI is broken and the PR cannot make progress until I fix it. |
| 3 | `ready-to-merge` | All gates green; merge so the worktree and plan cache can be reclaimed and the Reviewer's attention moves on. |

**Stage 2 — only after Stage 1 is exhausted, touch issues.**

| Sub-priority | State | Why |
|--------------|-------|-----|
| 4 | `start` | Open a new worktree, draft a plan, push the first PR. |
| 5 | `clarify` | Author hasn't been pinged yet (or has responded); post or refresh the clarification thread. |

**Hard rule**: Stage 2 only begins when every Stage-1 item has been
processed or is in a waiting state (`wait-ci` / `wait-review` /
`wait-lgtm-fresh`). A cycle never picks up a new issue while a PR could
still be fixed, replied to, or merged.

Rationale:

- **PR comments are the priority within PR work.** A reviewer waiting on
  the Coder is the single most expensive idle state in the loop —
  unblocking them earns the most progress per unit of cycle time.
- **PRs decay if abandoned**: stale LGTMs invalidate, CI states age out,
  reviewer context evaporates. New issues don't decay.
- **Resource isolation**: per-issue worktrees mean starting a new issue
  consumes disk + branch slots. Better to free those up by finishing
  in-flight PRs first.

If the scheduler fires the next cycle 5–10 minutes later, fresh issues
will be picked up then — no permanent starvation.

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

**Rotation is "Skipped", not "Needs human".** When you rotate an item
out (push → CI, PR opened → awaiting Reviewer), record it in the
cycle summary's `Skipped:` section with a wait reason (`wait-ci`,
`wait-review`, `wait-lgtm-fresh`). The Reviewer cycle is a separate
invocation of this skill, not a human — `Needs human` is reserved for
items where the [notification protocol](notification-protocol.md) has
actually fired (label + marker comment). See SKILL.md § "Output
protocol" for the full list of valid `Needs human` reason tags.

## When does the cycle end?

A cycle ends only when **no item — in either stage — is currently
actionable**. "Actionable" means the canonical classifier
(`coding-flows-classify-pr`) returns a non-`wait-*` state, or a Stage 2
issue is in `start` / `clarify-responded` state.

In particular, a cycle DOES NOT end while:

- Any PR is in `address-changes` / `address-ci-fail` / `ready-to-merge`
  (Stage 1 actionable). Process them in priority order; only after they
  are all in `wait-*` states does the cycle move to Stage 2.
- Any issue is `start`-ready (clear AC, no PR yet) AND all Stage 1
  items are in waiting states. Pick one and run Phase A1 → D.
- A previous Stage 1 action you just completed enables a follow-up
  (e.g. you just merged a fix PR; a different PR's `address-ci-fail`
  could now be cleared by a rebase). Do the follow-up in the **same**
  cycle. Don't write "will rebase next cycle" and end.

### Anti-patterns observed in transcripts

These all amount to "ending the cycle early when more work is sitting
right there". They produce the "issue stuck for N cycles" failure
mode. Don't do them:

- **"Will rebase next cycle"** — a rebase is a 30-second action
  (`git rebase origin/main && git push --force-with-lease`). If you
  identify that an open PR needs rebase because main moved, do it
  now in this cycle.
- **"Log not yet available"** — if classify reports `address-ci-fail`
  the run has reached a failure conclusion and `gh run view --log-failed`
  works. If the run is still in progress, classify reports `wait-ci`
  (skip is correct). Don't conflate the two.
- **"PR-side fixes took the cycle"** — there is no cycle time budget
  (see "No per-cycle time budget" above). If Stage 1 is exhausted
  and Stage 2 has actionable issues, process them. The user observed
  issues #257, #266, #268 stuck for 15+ cycles with this excuse —
  they never got worse, the Coder just never started them.
- **"Deferred — medium-large scope"** — size alone is not a deferral
  reason. See Phase A1 below.

If after walking every Stage 1 actionable item and every Stage 2
actionable item, every remaining item is in a wait state OR
`needs-human`, THEN end the cycle.

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

**Wall-clock time alone is not a reason to defer.** The scheduler's
polling interval is not a budget — see "No per-cycle time budget" above.
Defer only when an issue is:

- **Ambiguous** (`ac_clear=no/partial`, `test_path_clear=needs-design`):
  can't safely start until clarified.
- **Unsafe to start unilaterally** (`high_risk_paths=true`): needs
  operator sign-off via `needs-human`.
- **Genuinely unbounded** (`size_estimate=large` AND the agent's honest
  judgment is that even a focused multi-hour session can't reach a
  reviewable PR — e.g. a cross-cutting refactor touching dozens of
  files across multiple subsystems): trigger `scope-too-large`. Ask
  the human to split the issue.

Note that `size_estimate=large` by itself is not a deferral reason —
plenty of "large" issues (1000–3000 lines of focused work in one area)
are within reach of a single sustained cycle. Reserve `scope-too-large`
for cases where splitting is the right architectural call, not a way
to dodge focused work.

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

### Gate failures during Phase F's `--dry-run` are signals, not obstacles to evade

When `coding-flows-merge --dry-run` reports a gate failure, the fix is
to **do the underlying work**, not to mutate the PR body until the gate
stops complaining. Common evasion patterns to NOT use:

- **Gate 11 (test plan)**: never strip the `[ ]` from `- [ ] item` to
  produce a plain `- item` bullet — Gate 11 catches that too. Either
  actually run the manual verification and mark `- [x]`, OR remove the
  entire bullet line if the item no longer applies.
- **Gate 9 (risks)**: never change a risk's `Category` to `none` to slip
  past the validator — the category enum exists so Reviewer's
  `risks-reviewed=` covers the real categories declared.
- **Gate 10 (scope envelope)**: never add unrelated changed files to
  `## Support files` purely to silence the gate — file follow-up issues
  and split the PR instead.
- **Gate 4 (LGTM coverage)** is Reviewer-side; Coder cannot fix this by
  editing the PR body. Flag as `needs-human` and wait for the Reviewer
  to re-sign with canonical coverage values (see
  [reviewer-cycle.md](reviewer-cycle.md) §"Outcome 1").

**Rotation**: after `git push` the PR is back in `wait-ci` / `wait-review`.

## Phase F — Merge (when `ready-to-merge`)

```
cd "$(coding-flows-worktree-path <branch>)"
scripts/coding-flows-merge <PR>
```

Never call `gh pr merge` directly. The script enforces all 11 gates, and
on success cleans up: removes the worktree, deletes the local branch,
clears `~/.cache/coding-flows/<owner>/<repo>/pr-<N>/`. Use
`--keep-worktree` if you want to inspect the branch state post-merge.

After merge, the script posts a one-line "Shipped" comment on the linked
issue. The item is complete.

## Parallel-cycle safety

If another cycle is already operating on the same branch's worktree (e.g.
two `/loop` invocations overlap), the second cycle should:

- Skip `start` and `address-*` actions for that PR.
- Still allow itself to act on **different** PRs / issues whose worktrees
  it doesn't share.

The skill itself does not currently enforce this — rely on the
scheduler layer to skip-if-running, or set the polling interval
conservatively. A worktree-level `.coding-flows.lock` is a candidate
improvement that would enforce this directly at cycle start.

## Common tool-call pitfalls

Observed in session transcripts. None are skill bugs; all are agent
discipline issues that show up as `is_error=true` in tool results.

- **`File has not been read yet. Read it first before writing to it.`**
  Claude Code requires every `Edit` / `Write` target to be `Read` first
  in the same session. When you switch worktrees or grep finds a file
  you haven't touched yet, **always `Read` before `Edit`**. This is a
  Claude Code constraint, not enforceable from the skill.

- **`No such file or directory` from `sed` / `ls` / `Read`** despite the
  file existing. You're cd'd into the wrong checkout. With per-issue
  worktrees, the main checkout (`<repo>/main/`) typically doesn't
  contain the changed files for an in-flight PR; those live in
  `<repo>/<branch-slug>/`. Before any file operation:
  ```
  cd "$(coding-flows-worktree-path <branch>)"
  ```
  Verify with `pwd` and `git rev-parse --abbrev-ref HEAD`. If you're
  about to operate on PR #N's files, `head` should equal that PR's
  branch.

- **`coding-flows-worktree-create` says "worktree path already exists".**
  You already have a worktree for that branch. Either resume into the
  existing one (`cd "$(coding-flows-worktree-path <branch>)"`) or
  remove the stale worktree first (`coding-flows-worktree-remove
  <branch>`). The script refuses to overwrite, which is correct
  behavior.

- **`HTTP 504: Gateway Timeout (api.github.com/graphql)`** —
  transient. Retry once. If it persists, log a `needs-human` with
  reason `gh-api-degraded` and proceed with the next item.

- **`Cancelled: parallel tool call ... errored`** — when batching tool
  calls in one message, if any one Bash command errors, the harness
  cancels the rest. Issue calls in smaller batches when one
  legitimately may fail (e.g., `gh issue view` for issues that might
  not exist).

- **`failed to delete local branch ... used by worktree at ...`** is
  a cosmetic warning from `gh pr merge --delete-branch` and is filtered
  by `coding-flows-merge` — the branch IS deleted moments later by our
  worktree cleanup. If you see this string in transcripts on an older
  version of the skill, ignore it.

## Hard guardrails (Coder-specific)

Inherited from SKILL.md, plus:

- **One worktree per branch.** Never `git checkout <other-branch>` inside a
  worktree — every branch gets its own worktree (or none).
- **Never abandon a worktree with uncommitted changes.** Commit, stash to
  a named branch, or explicitly `coding-flows-worktree-remove --force`.
- **Never delete the main checkout's branch.** Worktree cleanup only
  removes managed worktrees under `worktree_root`.
