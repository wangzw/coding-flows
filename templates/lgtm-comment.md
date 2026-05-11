/lgtm

<!-- coding-flows:lgtm sha=<FULL_HEAD_SHA> reviewer=<REVIEWER_ID> acs=<AC-1,AC-2,...> invariants=<id1,id2,...> risks-reviewed=<cat1,cat2,...> -->
Verified <AC IDs> against <test files referenced>. Confirmed <invariant IDs>
in <code locations>. <Reviewed risks: e.g. migration plan looks safe;
external-side-effect mitigated by retry budget>. <Optional one-sentence
caveat — e.g. flake noted in #<flake-issue>>. CI green.

<!--
  Marker values are NOT free-form labels — they are enum identifiers:

    acs=             AC IDs from the PR body's `## AC mapping` table
                     (AC-1, AC-2, ...). Must be a superset of those IDs.
    invariants=      IDs from .coding-flows.json `invariants[].id`,
                     limited to those triggered by the diff. Empty CSV
                     if no invariants apply.
    risks-reviewed=  Category enum values from the PR body's
                     `<!-- coding-flows:risks categories=... -->` marker
                     (migration | feature-flag | secret | perf |
                     external-side-effect | compat-break). Do NOT write
                     descriptive prose like "stacked-modal-handling" or
                     "dom-mutation-outside-react" — only the enum
                     identifiers.

  Cheat: `coding-flows-show-coverage <PR>` emits the exact required
  values for this marker. Copy them in literally.
-->
