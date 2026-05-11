<!-- coding-flows PR body template. The required sections below are enforced
     by merge gates; do NOT delete them. Render this template via
     `coding-flows-coder-plan render <branch>` so the Coder's local plan
     populates AC mapping, Risks, Support files automatically. -->

## Summary

<1-3 paragraphs describing what changed and why. Reference any design docs.>

Closes #<ISSUE>

## AC mapping

<!-- Every AC from the linked issue must appear here with non-blank Test,
     Code, and Commit. Reviewer verifies each row against the diff. -->

| AC   | Description                                  | Test                                     | Code                              | Commit  |
|------|----------------------------------------------|------------------------------------------|-----------------------------------|---------|
| AC-1 | <copy AC text verbatim from issue>           | <test_file.go:LineStart-LineEnd or name> | <impl_file.go:LineStart-LineEnd>  | <SHA>   |

## Support files

<!-- Files changed in this PR that ARE NOT directly claimed by an AC row
     above and ARE NOT covered by .coding-flows.json scope_envelope.exclude_paths
     must be listed here with a one-line justification. Empty list is OK if
     all changes are claimed by AC mapping + exclude rules. -->

- `<path>` — <why it's in this PR despite not being an AC>

## Risks

<!-- coding-flows:risks categories=<csv-of-non-none-categories> -->

| Category | Description | Mitigation |
|----------|-------------|------------|
| none     | —           | —          |

<!-- Replace the row(s) above. Category must be one of: migration,
     feature-flag, secret, perf, external-side-effect, compat-break, none.
     If "none" appears it must be the only row. Update the HTML marker's
     categories= to match the non-none categories in the table. -->

<!-- coding-flows:coder-self-check invariants-considered=<csv> -->

## Test plan

<!-- Manual verification steps beyond CI. Every bullet in this section
     must be `- [x]` before merge (Gate 11). Plain bullets, `- [ ]`,
     `- [.]`, or any other non-`[x]` form blocks merge — Coder must
     either run the verification and mark `- [x]`, or remove the entire
     bullet line (don't strip just the `[ ]`).

     Drop this whole section for PRs with no manual verification. -->

- [ ] …
