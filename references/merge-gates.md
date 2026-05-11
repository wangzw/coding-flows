# Merge gates

All 10 gates are enforced mechanically by `scripts/coding-flows-merge`. Agents
must never call `gh pr merge` directly.

Gates 1–8 are Reviewer-and-handoff oriented; Gates 9–10 are Coder-quality
gates (declared risks, scope tightness) and run before Gate 4 so the
Reviewer's coverage check (Gate 4) operates on a PR body that already
satisfies structure requirements.

## Gate 1 — CI green

```
gh pr checks <PR>
```

All required checks must be `SUCCESS` on the current head SHA. If any is
`FAILURE`, apply [flaky-test-policy.md](flaky-test-policy.md) first.

## Gate 2 — Linked issue

PR body must contain one of: `Closes #N`, `Fixes #N`, `Resolves #N`
(case-insensitive). Extracted by regex.

## Gate 3 — AC mapping table

PR body must contain a `## AC mapping` section with a complete table. Format
spec: [ac-mapping.md](ac-mapping.md). Validated by
`scripts/coding-flows-verify-ac-mapping`.

## Gate 4 — LGTM coverage

The union of `acs=` claims across all `/lgtm` markers bound to the current
head must cover every AC ID in the AC mapping table. Likewise,
`invariants=` claims must cover every invariant whose `triggered_by_paths`
in `.coding-flows.json` matches a path in the diff.

Validated by `scripts/coding-flows-verify-lgtm-coverage`:

1. Read AC IDs from the AC mapping table.
2. Compute triggered invariants from `.coding-flows.json` `invariants[]` against
   the changed files.
3. Parse `acs=` and `invariants=` from every current-head `/lgtm` marker;
   union the values.
4. Demand: claimed AC ⊇ AC mapping IDs; claimed invariants ⊇ triggered set.
5. Fail with a specific list of missing IDs if not.

This is the gate that **forces structural enumeration**: a reviewer cannot
LGTM without naming what they verified, and cannot silently skip an
invariant — but no plan content is ever posted to the PR. The marker is an
HTML comment, invisible in the rendered PR conversation.

## Gate 5 — LGTM bound to current head

The most recent `/lgtm` comment must carry a marker
`<!-- coding-flows:lgtm sha=<sha> reviewer=<id> acs=… invariants=… -->` and the
`sha=` field must match current head. Validated by `scripts/coding-flows-check-lgtm`.

A stale LGTM (different SHA) returns exit code 2 — wait for fresh LGTM
against new head.

## Gate 6 — No unresolved review threads

Approximated as: no reviewer's most-recent review is `CHANGES_REQUESTED`. If
the Coder pushed a fix, the Reviewer must post a fresh `--comment` or
`/lgtm` review to clear the prior `CHANGES_REQUESTED` state.

## Gate 7 — Merge method allowed

`merge.method` in `.coding-flows.json` is `squash` or `rebase` (default
`squash`). Merge commits are never used.

The gate:

1. Validates the configured method is `squash` or `rebase` (sanity).
2. Calls `repo_allowed_merge_methods` (in `scripts/lib/common.sh`) which
   wraps `gh repo view --json squashMergeAllowed,rebaseMergeAllowed,mergeCommitAllowed`
   and emits a CSV of methods the repo permits.
3. Demands the configured method is in that CSV.

Override paths for testing / cross-repo orchestration:

- `$CODING_FLOWS_REPO_ALLOWS=squash,rebase` — explicit override, used by anyone
  who wants to skip the gh call.
- `PR_VIEW_SOURCE=file` (set automatically by `load_pr_view` in
  `--from-file` mode) — falls back to a permissive `squash,rebase`
  default since fixture-driven tests can't call gh against the test repo.

## Coder self-check marker (informational, NOT a gate)

PR bodies rendered by `coding-flows-coder-plan render` include an HTML marker:

```
<!-- coding-flows:coder-self-check invariants-considered=<csv> -->
```

This is the Coder's own claim of which invariants they thought about
while writing the code. Reviewers read it for accountability — it's
context that helps them decide where to look harder. The merge gates do
**not** enforce it; the Reviewer's own LGTM marker (Gate 4) is the
authoritative invariant-coverage signal. If a Coder lies in the
self-check marker, only Gate 4's independent verification by the
Reviewer catches it.

The marker exists so that systematic gaps in Coder self-checks become
visible over time (compare claims to actual invariant violations
discovered in review) without adding another structural gate that the
Coder could rubber-stamp themselves.

## Gate 9 — Risks declared

PR body must contain a `## Risks` section with a Markdown table
(Category | Description | Mitigation), an `<!-- coding-flows:risks
categories=<csv> -->` HTML marker matching the non-`none` categories in
the table, and every Category value from `.coding-flows.json`
`risks.allowed_categories` (defaults: migration, feature-flag, secret,
perf, external-side-effect, compat-break, none).

`none` may appear only as the sole row. The marker's `categories=` value
must equal the sorted, distinct, non-`none` categories from the table —
catches stale markers when categories are added/removed.

Validated by `scripts/coding-flows-verify-risks`. Exit code 20 on failure.

## Gate 10 — Scope envelope

Every changed file in the PR must be **claimed** by one of:

1. A row in the AC mapping table (path appears in the Code or Test
   column — prefix-before-`:` is the claim).
2. A bullet under `## Support files` in the PR body.
3. A glob in `.coding-flows.json` `scope_envelope.exclude_paths` (defaults to
   `*.md`, lockfiles, snapshots — see config-schema.md).

Unclaimed files block merge. This catches "while I was in there I
refactored X" creep without relying on the Reviewer to notice.

Path matching is exact OR by suffix — `service.go` in the AC mapping
matches `backend/foo/service.go` in the changed-files list.

Validated by `scripts/coding-flows-verify-scope-envelope`. Exit code 19 on
failure with the unclaimed file list in stderr + stdout.

## Gate 8 — High-risk dual LGTM

If the PR carries any `high-risk:*` label, the union of `LGTM_REVIEWERS`
from current-head markers must include at least 2 distinct reviewer IDs.

Note: Gate 4 (coverage) already unions all reviewers' claims, so two
reviewers can split AC coverage between them. The merge gate accepts
combined coverage; it doesn't demand each reviewer name every item.

See [high-risk-pr.md](high-risk-pr.md) for the full dual-reviewer protocol.

## Failure semantics

`scripts/coding-flows-merge` exits with a specific code:

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

The Coder cycle parses this and:

- `stale-lgtm` / `lgtm-missing` / `dual-lgtm-missing` → wait for Reviewer.
- `unresolved-threads` → push fix or push back.
- `lgtm-coverage-incomplete` → ping Reviewer (their LGTM marker is missing
  rows); do **not** silently edit the AC mapping to match the marker.
- `ac-mapping-incomplete` → fix the PR body.
- `ci-failing` → push a fix (after flake handling).
- `merge-method-disallowed` → trigger `merge-blocked` notification.

The merge script does no mutating I/O until the final `gh pr merge`. All
gates are read-only.

## After successful merge

1. `gh pr merge <PR> --<method> --delete-branch` (per config).
2. Post a one-line "Shipped in #PR — thanks!" comment on the linked issue
   (if `merge.post_merge_issue_comment` is true).
3. Return 0.
