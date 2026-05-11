# High-risk PRs and dual-reviewer protocol

When the same identity authors *and* reviews PRs, cognitive consistency bias
softens scrutiny. For PRs touching critical surfaces, coding-flows dispatches a
**second reviewer agent** that's blind to the first review.

## Risk labeling

Configured in `.coding-flows.json` → `high_risk_rules[]`. Each rule has:

- `paths` — glob patterns. If any changed file matches → rule fires.
- `size` (optional) — `{lines_changed: N}`. If total diff lines ≥ N → rule fires.
- `label` — label to apply (must start with `high-risk:`).

`scripts/coding-flows-label-risk <PR>` evaluates all rules and applies the union of
labels via `gh pr edit --add-label`.

### Example rules

```json
"high_risk_rules": [
  {"paths": ["**/auth/**", "**/security/**"],        "label": "high-risk:auth"},
  {"paths": ["**/migrations/**", "**/schema/**"],    "label": "high-risk:migration"},
  {"paths": ["**/billing/**", "**/payments/**"],     "label": "high-risk:billing"},
  {"paths": ["docker-compose*.yml", ".github/**"],   "label": "high-risk:deploy"},
  {"size":  {"lines_changed": 1000},                 "label": "high-risk:large"}
]
```

The Coder cycle calls `coding-flows-label-risk` immediately after opening the PR.
The Reviewer cycle re-evaluates if the diff grows.

## Dual reviewer dispatch

When **any** `high-risk:*` label is present:

1. The first Reviewer agent runs normally (Phase A–E). It builds its local
   review plan and signs `/lgtm` with `reviewer=reviewer-1` when satisfied.
2. The skill then dispatches a **second Reviewer agent** with:
   - The same adversarial prompt.
   - Marker `reviewer=reviewer-2`.
   - **Blind to reviewer-1's findings**: the dispatch invokes
     `scripts/coding-flows-fetch-for-reviewer --reviewer reviewer-2 <PR>` and
     passes the resulting filtered JSON to reviewer-2's cycle via
     `--from-file`. Reviewer-2 must use this filtered view, not raw
     `gh pr view`.
3. Reviewer-2 builds its own local plan and signs `/lgtm` with
   `reviewer=reviewer-2` if satisfied.

The merge gate (`coding-flows-merge` Gate 8) requires both reviewers' `/lgtm`
bound to the current head.

### Code-enforced blindness — what the filter covers

`coding-flows-fetch-for-reviewer` drops PR comments whose body carries a
`<!-- coding-flows:<kind> ... reviewer=<id> -->` marker where `<id>` is not the
dispatched reviewer. This hides:

- Other reviewers' `/lgtm` comments (the primary leak vector — these contain
  explicit AC and invariant coverage claims).

The filter does **not** modify:

- PR review bodies (`gh pr review --request-changes` / `--comment`). Under
  single-user authentication, every review is authored by the same gh login,
  so the filter cannot attribute reviews to a `reviewer=` id. The dispatch
  prompt for reviewer-2 must explicitly say "ignore any prior
  `--request-changes` review history; reach your own verdict from the diff,
  the issue, and the AC mapping table".
- Inline review thread comments — same limitation as review bodies.
- Coder ↔ Reviewer prose comments without coding-flows markers — these are kept
  to preserve normal discussion.

This is best-effort code enforcement; the orchestration layer remains the
authoritative isolator for review-body blindness.

## Disagreement handling

If reviewer-2's findings contradict reviewer-1's `/lgtm`:

- reviewer-2 posts `--request-changes` instead of `/lgtm`.
- This invalidates the dual-LGTM requirement.
- Trigger the `dual-review-disagreement` notification.
- The human reviews both review plans side by side and arbitrates.

The skill **does not** attempt to reconcile reviewer-1 and reviewer-2
automatically. Disagreement on a high-risk PR is a signal that human
judgment is required, not noise to be averaged away.

## After the Coder addresses changes

On a new push:

- Both reviewers re-review independently.
- Reviewer-2 remains blind to reviewer-1's new findings.
- Both must sign fresh `/lgtm` against the new head before merge.

## Identity stability

`reviewer=` identifiers are stable across rounds of the same PR. The skill
records the assignment in PR labels:

- `coding-flows:reviewer-1:<agent-session-id>`
- `coding-flows:reviewer-2:<agent-session-id>`

(Labels are added by the skill on first dispatch; same agent picks up its
own role on subsequent cycles by reading these labels.)

## When to NOT dual-review

- Non-high-risk PRs (no `high-risk:*` label) — single Reviewer suffices.
- Documentation-only PRs even if size threshold is hit — controlled by
  `.coding-flows.json` → `high_risk_rules[].exclude_paths` (e.g. `docs/**`).
- Bot/dependency-bump PRs — typically labeled `dependencies`; skip dual review
  for these (configurable via `high_risk_rules[].exclude_labels`).
