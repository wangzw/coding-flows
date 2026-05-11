# Flaky test policy

A "flake" is a CI failure that looks intermittent and unrelated to the PR's
diff. When a check fails, before treating it as a blocker:

1. **Re-run the failed job once.**
   ```
   gh run rerun <run-id> --failed
   ```

2. **If the same test fails again on rerun**, file a **new issue** titled
   `Flaky test: <suite>::<name>` with the failure log and a link to the PR,
   and leave a PR comment linking to that issue. Then proceed as if the test
   were a pre-existing failure — the flake itself does **not** block this PR.

3. The Reviewer mentions the flake in their `/lgtm` comment if it surfaced
   during review.

## Rules

- **Do not silently retry.** Every rerun is logged in a PR comment.
- **Do not edit the test to make it pass.** If the test is wrong, file an
  issue saying so and treat it as out of scope for this PR.
- **Do not increase the rerun count.** One rerun is the policy. Persistent
  failure after one rerun triggers the `repeated-ci-failure` notification.

## Distinguishing flake from real failure

Heuristics (the agent makes a judgment call):

- **Likely flaky** — the failed test touches code paths far from the diff;
  the error message mentions timeouts, DNS, container start, "address in
  use", or other infrastructure terms; the same test has flaked recently on
  other PRs (check `gh issue list --search "flaky <test-name>"`).
- **Likely real** — the failed test directly exercises code modified by the
  diff; the error message is a logic/assertion failure on values the PR
  would change; the test passes locally only by chance.

When ambiguous: treat as real (don't risk merging a regression). Push a fix
or file a `repeated-ci-failure` notification.

## Why "one rerun only"

The trap with flaky-test policy is reruns becoming a way to ignore
deterministic failures. One rerun is enough to confirm "it's actually
flaky"; more reruns drift into "keep trying until green", which corrupts CI
signal.
