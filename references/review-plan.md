# Review plan — local working artifact + LGTM coverage marker

The review plan is the Reviewer's **internal checklist**. It is **not** posted
to the PR. Posting wall-of-JSON plans to GitHub destroys the PR as a human
artifact (a real failure mode observed in early coding-flows PRs).

The plan exists only on the Reviewer agent's filesystem. The PR sees only the
final, compact `/lgtm` (or natural-language `--request-changes` review).

## Where the plan lives

Per-project, per-PR, per-reviewer:

```
$CODING_FLOWS_CACHE_DIR/<owner>/<repo>/pr-<N>/reviewer-<id>/plan-v<V>.json
```

Default `$CODING_FLOWS_CACHE_DIR` is `~/.cache/coding-flows`. The skill writes a fresh
`plan-vN+1.json` when re-reviewing after a new push — old versions stay on
disk for the Reviewer's own audit; the human never sees them.

`scripts/lib/common.sh` exposes `repo_state_dir [PR-number]` which returns
the correct path; the Reviewer cycle creates the directory before writing.

The cache directory pattern keeps multiple repos cleanly separated. Override
`CODING_FLOWS_CACHE_DIR` for tests (point at a tmpdir).

## Plan structure

The JSON format mirrors what the Reviewer needs in working memory. Use it
as a working buffer; do not paste it into PR comments.

```json
{
  "acceptance_criteria": [
    {
      "id": "AC-1",
      "text": "Given a request with no auth header, When POST /v1/messages, Then return 401",
      "verdict": "covered",
      "evidence": "backend/auth/middleware_test.go:42-58 — TestRejectsMissingHeader exercises the path; handler.go:120 returns httperr.Unauthorized"
    }
  ],
  "invariants": [
    {
      "id": "events-before-publish",
      "rule": "every nats.Publish must be preceded by eventstore write in same fn",
      "verdict": "ok",
      "evidence": "Only nats.Publish in diff is sse/broker.go:88, preceded by eventstore.Append at :85"
    }
  ],
  "files_audited": [
    {"path": "backend/auth/middleware.go", "standards": ["backend-coding-standards"]}
  ]
}
```

### Verdict enums

`acceptance_criteria[].verdict` ∈ {`covered`, `gap`, `not-applicable`}.
`invariants[].verdict` ∈ {`ok`, `violation`, `not-applicable`}.

A blank or unset verdict means "not yet checked". Reviewer must not signal
`/lgtm` while any verdict is blank.

## How the plan is sourced

Reviewer Phase B0:

1. Parse `Closes #N` from PR body → `gh issue view <N> --json body`.
2. Extract AC bullets from sections under `## Acceptance Criteria`,
   `## Requirements`, `## ACs`, or any Given/When/Then block.
3. Cross-reference against the AC mapping table in the PR body — every AC
   the Coder claimed should appear as a row. Disagreement is flagged as
   `scope-mismatch`.
4. Run `scripts/coding-flows-detect-scope --pr <PR>` → enumerate the
   coding-standards skills + invariant docs triggered by the diff.
5. For each triggered invariant in `.coding-flows.json` `invariants[]`, add a row.

Save initial plan to `plan-v1.json` with all verdicts blank.

## Audit (Phase C)

Reviewer reads `gh pr diff <PR>` and the relevant standards, then fills
every verdict + evidence. The file is updated in place per row (or rewritten
as `plan-v2.json` after a Coder push). **The file is never published.**

## What the PR actually sees

Two outcomes:

### a) All verdicts are `covered` / `ok` / `not-applicable`

Post a single `/lgtm` comment with a compact coverage marker — see below.
That's it. No "Review plan v=1" comment, no "verdicts filled" comment.

### b) Any verdict is `gap` or `violation`

Post `gh pr review --request-changes` with a natural-language body listing
the blockers. Use inline file:line comments for spot-specific findings.
Format rules: see [pr-comment-format.md](pr-comment-format.md).

## LGTM coverage marker (what becomes machine-verifiable)

The `/lgtm` comment carries an HTML-comment marker. This is the **only**
machine-readable artifact the Reviewer publishes:

```
/lgtm

<!-- coding-flows:lgtm sha=<full-head-sha> reviewer=<reviewer-id> acs=AC-1,AC-2,AC-3 invariants=events-before-publish,no-secrets-in-logs -->
Verified AC-1..AC-3 against tests in env_test.go and proxy_test.go.
Confirmed events-before-publish in sse/broker.go:88; no logging of secrets in
the new auth path. CI green.
```

### Marker fields

| Field | Required | Meaning |
|-------|----------|---------|
| `sha`        | yes | Full head commit SHA at time of LGTM. Any new push invalidates. |
| `reviewer`   | yes | Stable identifier for this reviewer agent (e.g. `r1`). |
| `acs`        | yes | Comma-separated AC IDs verified. Value may be empty if there are no ACs in the PR. |
| `invariants` | yes | Comma-separated invariant IDs verified. Value may be empty if none triggered. |

All four keys must appear, even with empty values. An empty value is an
explicit claim of "nothing to check"; absence of the key is a malformed
marker and disqualifies the LGTM.

### How the merge gate uses the marker

`scripts/coding-flows-verify-lgtm-coverage`:

1. Compute the set of AC IDs from the AC mapping table (Coder's claim).
2. Compute the set of triggered invariant IDs from `.coding-flows.json`
   `invariants[]` against the current diff.
3. Union the `acs=` claims from all LGTM markers bound to the current head
   (so dual-reviewer high-risk PRs can split the verification between two
   reviewers if they choose).
4. Union the `invariants=` claims similarly.
5. Demand: `LGTM_ACS ⊇ AC mapping IDs` and `LGTM_INVARIANTS ⊇ triggered
   invariants`. Any missing element fails the gate with a specific list of
   what's missing.

This means a Reviewer **cannot** sign `/lgtm` without enumerating exactly
what they verified, and **cannot** silently skip a triggered invariant —
the merge gate names what's missing. Without dumping anything onto the PR.
