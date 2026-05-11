# Reviewer cycle

The Reviewer runs with a **default-deny adversarial stance**. Its job is to
find reasons NOT to approve. `/lgtm` is signed only when every row of the
internal review plan has a non-blank verdict backed by a specific code/test
reference.

The review plan itself is a **local working file**, not a PR comment. See
[review-plan.md](review-plan.md). The only artifacts that touch the PR are:

- a final `/lgtm` comment with a compact coverage marker, **or**
- a `gh pr review --request-changes` with natural-language blockers, **or**
- inline file:line comments for spot-specific findings.

Format discipline: [pr-comment-format.md](pr-comment-format.md).

## Adversarial prompt (apply every cycle)

> You are reviewing a PR. Your default disposition is **do not approve**. Your
> job is to find reasons this change should not be merged. Look for: AC items
> the diff fails to cover, invariants from project standards that the diff
> violates, edge cases not exercised by tests, design weaknesses, security
> concerns, performance regressions.
>
> You may sign `/lgtm` only when **every row** of your local review plan has a
> non-blank verdict backed by a specific code or test reference. Blank verdicts
> mean "not yet checked" and block approval — they do not mean "fine".
>
> If you find yourself agreeing with the Coder's reasoning without independent
> verification, stop and verify. Cognitive consistency bias is the failure
> mode this prompt exists to counter.
>
> Do not publish your review plan to the PR. The PR is for humans and for the
> Coder; your plan is your working notes. Publish only `/lgtm` (with the
> coverage marker) or `--request-changes` (with natural-language findings).

When this skill is used with a model-routing layer, prefer a different model
for Reviewer than Coder (e.g. Coder=Sonnet, Reviewer=Opus) to further reduce
identity bias.

## Phase A — List open PRs to review

```
gh pr list --assignee <acting_user> --state open \
  --json number,title,author,isDraft,headRefName,headRefOid,labels
```

Skip drafts (`isDraft: true`).

## Phase B — Decide what to do per PR

**Do NOT classify by head-SHA-unchanged alone.** A common failure mode:
the Reviewer concludes "head SHA matches my last LGTM → idle" while
Gate 4 silently blocks merge because the LGTM marker's
`acs=`/`invariants=`/`risks-reviewed=` claims don't actually cover what
the Coder declared. The PR sits skipped forever in cycle summaries.

Run `coding-flows-classify-pr-reviewer <PR>` — it executes the full
merge gate suite in dry-run mode and maps the result to a Reviewer-side
action:

| `PR_REVIEWER_STATE` | What to do |
|--------------------|------------|
| `needs-review`      | No LGTM yet, or head SHA changed since LGTM. Proceed to Phase B0 (build review plan + audit diff). |
| `needs-resign`      | LGTM bound to head but Gate 4 (coverage) fails — your marker's `acs=`/`invariants=`/`risks-reviewed=` doesn't cover the Coder's declarations. Run `coding-flows-show-coverage <PR>` for canonical values, then either `coding-flows-revoke-lgtm` and post a fresh `/lgtm`, or just post a corrected `/lgtm` (claim sets union). **No diff re-review required** — the diff is unchanged; only the marker is wrong. |
| `needs-second-lgtm` | High-risk PR (`high-risk:*` label) with one valid LGTM. If you are reviewer-2, run Phase B0. |
| `idle-merge-ready`  | Every gate passes. Coder owns the merge step. Truly skip. |
| `idle-coder-blocked`| A Coder-side gate is failing (CI, AC mapping, Risks, scope, test plan, threads, ...). The reason is in the script's `REASON=` output. You can't fix this from your side — truly skip. |

For the underlying gh data, the script does its own `gh pr view`. You
don't need to fetch separately for classification — but you will need
the full PR view + diff for Phase B0 work.

## Phase B0 — Build the local review plan (no PR posting)

Compute the working artifact on disk before reading the diff. This forces
explicit enumeration of what must be checked, anchoring the audit and
counter-acting framing effects from the Coder's PR description.

```
plan_dir="$(repo_state_dir <PR>)/reviewer-<id>"
mkdir -p "$plan_dir"
# Write plan-v1.json with all verdicts blank.
```

Steps:

1. Read the linked issue (parse `Closes #N` from PR body). Extract every AC
   bullet as a row.
2. Read the AC mapping table from the PR body. For each AC the Coder claimed,
   note the test+code+commit reference.
3. Run `scripts/coding-flows-detect-scope --pr <PR>` to enumerate which
   coding-standards skills and invariant docs apply. **Read each.**
4. For each invariant in `.coding-flows.json` `invariants[]` whose
   `triggered_by_paths` matches the diff, add a row.
5. Write `plan-v1.json` to the local cache. All verdicts blank.

## Phase C — Fill verdicts (locally)

Read the diff: `gh pr diff <PR>`.

For **every row** in the plan, fill `verdict` + `evidence`:

- `acceptance_criteria` rows: locate test + code; verdict ∈
  {`covered`, `gap`, `not-applicable`}.
- `invariants` rows: search diff for any code that would violate the rule;
  verdict ∈ {`ok`, `violation`, `not-applicable`}.

Update `plan-vN.json` in place (or write `plan-vN+1.json` on re-review). **The
file never leaves disk.**

After every row has a verdict, also evaluate (these don't become plan rows
but inform whether to LGTM or request changes):

1. Correctness beyond stated AC — regressions in adjacent paths, obvious edge
   cases.
2. Test quality — meaningful, or passing trivially?
3. Design — API shape, naming, error handling.
4. Security — input validation, authz, secret handling.
5. Performance — N+1, unbounded allocations, blocking I/O.
6. Style / convention — matches `CLAUDE.md`/`AGENTS.md`, commitlint scopes.
7. PR hygiene — linked issue present, scope tight, conventional commits.
8. **Test plan completion** — if the PR body has a `## Test plan` section,
   every `- [ ]` must be `- [x]` (or removed). Unchecked items mean the
   Coder claimed manual verification but didn't run it. Gate 11 will block
   merge if you LGTM with unchecked items present, but catching it during
   review is cheaper than discovering it at merge time. Quick check:

   ```
   coding-flows-verify-test-plan <PR>
   ```

## Phase D — Publish exactly one of two outcomes

### Outcome 1 — All verdicts pass → `/lgtm`

Every `acceptance_criteria[].verdict` is `covered` or `not-applicable`. Every
`invariants[].verdict` is `ok` or `not-applicable`. No `gap` / `violation`.
No outstanding objections from the 7-item evaluation.

Post **one** `/lgtm` comment using [templates/lgtm-comment.md](../templates/lgtm-comment.md):

```
/lgtm

<!-- coding-flows:lgtm sha=<full-head-sha> reviewer=<reviewer-id> acs=AC-1,AC-2,AC-3 invariants=events-before-publish,no-secrets-in-logs -->
<1-3 sentence summary of evidence — what AC items, what invariants, what
edge cases, any caveats.>
```

The HTML-comment marker is parsed by `scripts/coding-flows-verify-lgtm-coverage`.
It must include all four fields (`sha`, `reviewer`, `acs`, `invariants`).

**Marker values are enum identifiers, not prose.** A common failure mode:
the Reviewer writes descriptive labels like
`risks-reviewed=stacked-modals,dom-mutation-outside-react` instead of the
enum categories the Coder declared (`migration | feature-flag | secret |
perf | external-side-effect | compat-break`). Gate 4 then blocks merge
because the claimed set doesn't match the declared categories.

Before composing the marker, run:

```
coding-flows-show-coverage <PR>
```

It emits the exact values for `acs=`, `invariants=`, and
`risks-reviewed=` based on what the Coder declared in the PR body and
what the diff triggers. Copy them in literally — no transformation
needed.
Empty `acs=` / `invariants=` values are allowed only when the PR truly has
no AC mapping rows or no triggered invariants.

For high-risk PRs (`high-risk:*` label), **two** distinct reviewers each
post their own LGTM with distinct `reviewer=` markers. See
[high-risk-pr.md](high-risk-pr.md). The two markers may divide AC/invariant
coverage between them — the merge gate unions the claims.

### Outcome 2 — Any verdict is `gap` / `violation` → `--request-changes`

Post a single review:

```
gh pr review <PR> --request-changes --body "$(cat <<'EOF'
<one-sentence summary of what blocks /lgtm>

- <file:line> — <one-sentence finding> — <one-sentence suggested fix>
- ...

EOF
)"
```

Plus inline comments where line-level anchoring helps:

```
gh pr review <PR> --comment --body "..."  # if a non-blocking observation
```

Body format rules in [pr-comment-format.md](pr-comment-format.md). **Never**
paste the JSON plan into the review body — translate `evidence` into prose,
keep the body short, anchor specifics inline.

**Never** use `gh pr review --approve` — GitHub will reject self-approval
and this skill uses the LGTM signal protocol instead.

## Revoking a prior LGTM

If you signed `/lgtm` and later discover the change is incorrect (your
own re-read, a new constraint that surfaces, or anything else that
should have blocked you the first time), **revoke the LGTM by posting
`gh pr review --request-changes`** with your new findings. The script
wrapper does this in one line:

```
coding-flows-revoke-lgtm <PR> -m "$(cat <<'EOF'
Revoking prior /lgtm — I missed that ... .

- src/foo.go:42 — finding + suggested fix
EOF
)"
```

Why this works without an explicit "unlgtm" marker: `/lgtm` is a
comment, not a formal review. A subsequent `--request-changes` from the
same reviewer becomes your **most-recent review state** in GitHub's
timeline. Merge Gate 6 picks the latest review per reviewer; if it's
`CHANGES_REQUESTED` and you haven't posted a later `/lgtm` to supersede
it, merge is blocked.

The previous `/lgtm` comment stays in the PR history (don't delete it
— it's the audit trail). The gate doesn't honor it once you've posted
`--request-changes`.

When the Coder pushes a fix and you're satisfied, post a **fresh** `/lgtm`
against the new head SHA. That supersedes the `--request-changes` (per
Gate 6's same-author timeline logic) and merge becomes possible again.

Body format rules — same as a fresh `--request-changes` review per
[pr-comment-format.md](pr-comment-format.md): 1-2 sentence summary of
what blocks `/lgtm`, then bulleted findings with `file:line` + suggested
fix. Don't paste your local review plan JSON; translate to prose.

## Phase E — Re-review on new commits

When the Coder pushes new commits after your previous round:

1. Read the new diff range.
2. Write `plan-vN+1.json` to the cache: copy rows forward, re-verdict every
   row touched by the new range. Untouched rows keep their prior verdict.
3. Publish exactly one new outcome (Outcome 1 or 2 above). The previous
   `/lgtm` (if any) is implicitly invalidated by the SHA change — you don't
   need to retract it.

## Disagreement escalation

If the Coder pushed back on a comment and you re-assert the same objection
in the next round (same concern surfaces twice on the same line/topic
without resolution), trigger the `disagreement` notification per
[notification-protocol.md](notification-protocol.md). Both sides summarize
their position in the marker comment for the human to arbitrate.

## Iteration cap

If a single PR has been through ≥5 review rounds without converging on
`/lgtm`, trigger `iteration-cap`. Long-running threads usually mean missing
context the agents can't recover.
