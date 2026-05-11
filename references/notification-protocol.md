# Notification protocol — when human input is required

The human is not always watching; they filter their GitHub by
`is:open label:needs-human`. All notifications must therefore land on a
GitHub item with a recognizable label.

## Label

Default: `needs-human`. Configurable in `.coding-flows.json` →
`notification.label`. Created lazily on first use:

```
gh label create needs-human \
  --color b60205 \
  --description "coding-flows: requires human input"
```

## When a cycle decides an item needs human attention

Do **all** of:

1. **Add the label** to the issue or PR:
   ```
   gh issue edit  <N>  --add-label needs-human
   gh pr    edit  <N>  --add-label needs-human
   ```

2. **Post a marker comment** on the same item. First line is an HTML comment
   that doubles as a dedupe key:
   ```
   <!-- coding-flows:human-needed reason=<reason-tag> -->
   @<human_user> — coding-flows needs your input here.

   reason: <reason-tag>
   <one-paragraph context: what was tried, what's blocking,
    and the specific question/decision you need from the human>
   ```

3. **Add the item to the cycle summary's "Needs human" section.**

4. **When the human resolves it**, they signal "handled" by removing the
   `needs-human` label. The skill **must not** remove the label itself; it
   only removes it once the underlying state has changed (e.g. on a fresh
   push that resolves a `disagreement`, or after a successful re-run that
   clears `repeated-ci-failure`).

## Dedupe rule

Before re-notifying for the same `(item, reason-tag)`:

- If the `needs-human` label is currently present **and** any existing
  comment contains `<!-- coding-flows:human-needed reason=<reason-tag> -->`
  → skip steps 1 and 2 (still include in cycle summary).
- If the label has been removed by the human and the condition recurs →
  re-add label and post a new marker comment.

## Reason tags

Use the most specific tag.

| Tag                          | When to use                                                          |
| ---------------------------- | -------------------------------------------------------------------- |
| `ambiguous-issue`            | Coder cannot safely interpret an issue's requirements.               |
| `scope-mismatch`             | A PR's `Closes #N` no longer matches the work in the diff.           |
| `disagreement`               | Reviewer re-asserts the same objection after Coder pushed back.      |
| `dual-review-disagreement`   | reviewer-2 requested changes after reviewer-1 LGTM'd a high-risk PR. |
| `iteration-cap`              | A PR has hit ≥5 review rounds without converging.                    |
| `repeated-ci-failure`        | Same CI failure persists after a flaky-policy rerun.                 |
| `broken-main`                | Lint/test/build on `main` is red, blocking new PRs.                  |
| `merge-blocked`              | PR is otherwise approved but missing linked issue / no merge method. |
| `auth-broken`                | `gh auth status` is unauthenticated or wrong account.                |
| `unrelated-dirty-tree`       | Pre-flight found unrelated uncommitted changes; cycle aborted.       |
| `ac-mapping-unresolvable`    | Coder cannot derive AC mapping (issue has no AC, no spec).           |
| `invariant-violation-unfixable` | Reviewer found a violation the Coder claims is intentional.       |

## Pre-flight failures with no specific GitHub item

For aborts where there's no issue/PR to label (`auth-broken`,
`unrelated-dirty-tree`, "not in a GitHub repo"), the label-based filter
cannot catch them. In these cases:

- Skip steps 1 and 2 (no label, no marker comment).
- Still record the failure in the cycle summary's "Needs human" section with
  `notified=summary-only` so the scheduler / log shows the abort.
- Exit the cycle. These failures must be resolved by the human at the shell
  before any further cycle can run.
