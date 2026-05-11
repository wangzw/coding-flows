# AC mapping table

The AC mapping table is the **Coder's** structured claim of "every AC in the
linked issue is implemented at this code location and tested by this test."
The Reviewer's job in Phase C is to verify each row, not to derive AC mapping
from scratch.

## Where it lives

In the PR body, under a section header `## AC mapping` (case-insensitive,
extra trailing characters allowed). Followed immediately by a Markdown table
with at least the columns below in any order.

## Required columns

| Column     | Purpose |
|------------|---------|
| `AC`       | Acceptance criterion identifier (e.g. `AC-1`). Stable across rounds. |
| `Description` | One-line statement of the AC, copied from issue. |
| `Test`     | File path + line range or test name (e.g. `auth_test.go:42-58` or `TestRejectsMissingHeader`). |
| `Code`     | File path + line range of implementation (e.g. `handler.go:120-135`). |
| `Commit`   | Short SHA of the commit that implements/tests this AC. |

Extra columns are allowed and ignored by the verifier (e.g. `Notes`).

## Validation rules (enforced by `coding-flows-verify-ac-mapping`)

1. Section header `## AC mapping` (or `## AC Mapping`, `## ACs`) exists in PR body.
2. Followed by a Markdown table with header row and ≥1 data row.
3. All required columns present (case-insensitive match).
4. Every data row has **every required column non-blank**. Values matching
   any of these are treated as blank: empty string, `-`, `—`, `TBD`, `…`,
   `n/a`, `?`.
5. Every `Commit` SHA (≥7 hex chars) matches a commit on the PR
   (`gh pr view <PR> --json commits`).
6. AC IDs are unique within the table.

## Example

```markdown
## Summary

Adds rate limiting to the messages proxy. Closes #142.

## AC mapping

| AC   | Description                                    | Test                                          | Code                                | Commit  |
|------|------------------------------------------------|-----------------------------------------------|-------------------------------------|---------|
| AC-1 | 429 on >100 rps per api key                    | proxy_test.go:RateLimit/Throttles             | proxy.go:84-110                     | a1b2c3d |
| AC-2 | Retry-After header reflects window remainder   | proxy_test.go:RateLimit/RetryAfter            | proxy.go:112-120                    | a1b2c3d |
| AC-3 | Bypass for keys with `unlimited` scope         | proxy_test.go:RateLimit/UnlimitedBypass       | proxy.go:75-83                      | e5f6g7h |
```

## What this protects against

Without this table, the Reviewer has to:

1. Read the issue and extract AC by themselves.
2. Read the diff and try to map each AC to code by themselves.
3. Hope they didn't miss one.

That's the failure mode where Reviewers `/lgtm` PRs that miss an AC entirely
because the AC was never in their working memory while they read the diff.

With the table, the Reviewer's job becomes the much easier and more
verifiable: "for each row, does the referenced code/test actually fulfill the
referenced AC?" Omissions become structural (a row is missing or blank), not
attentional.

## When to update mid-iteration

The Coder updates the AC mapping when:

- They push commits that change a test or code location.
- They add tests that previously were missing.
- They split an AC into sub-rows (rare; better to keep AC count fixed and
  expand `Description`).

The Coder must not change the **AC IDs** mid-iteration. AC IDs are the join
key between the AC mapping table (PR body) and the review plan
(`acceptance_criteria[].id`).

## Auto-derivation note

The skill does not auto-generate the AC mapping. The Coder writes it. This is
intentional — the act of writing the table is the Coder's explicit
verification that every AC is covered before requesting review.

`templates/pr-body.md` includes a starter table with placeholders that fail
verification — the Coder must replace placeholders with real references.
