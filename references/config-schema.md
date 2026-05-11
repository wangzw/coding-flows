# `.coding-flows.json` schema

Per-repo configuration. Lives at the repo root. All fields are optional —
defaults documented below.

## Full schema

```jsonc
{
  // GitHub user the skill operates as. Default: result of `gh auth status`.
  "acting_user": "octocat",

  // Human user for notifications (mentioned in needs-human marker comments).
  // Default: same as acting_user.
  "notification": {
    "label": "needs-human",
    "human_user": "octocat"
  },

  // Per-issue worktree location. Each branch gets its own worktree at
  // <root>/<branch-slug> (branch-slug = branch name with / replaced by -).
  // Default: dirname(main-repo-root) — worktrees become siblings of the
  //   main checkout. E.g. main at ~/workspace/castworks/main →
  //   worktrees at ~/workspace/castworks/<slug>/.
  // CODING_FLOWS_WORKTREE_ROOT env var overrides this default (for tests
  //   and CI). The config below overrides everything when set.
  "worktree": {
    "root": "../my-worktrees"      // relative paths anchor to the main repo
                                   // root, not cwd. Absolute paths also OK.
  },

  // Merge behavior.
  "merge": {
    // "squash" | "rebase". Default: "squash" (falls back to "rebase" if
    // squash not allowed by repo settings).
    "method": "squash",
    // Whether to delete branch after merge. Default: true.
    "delete_branch": true,
    // Whether to post a "thanks" comment on the linked issue after merge.
    // Default: true.
    "post_merge_issue_comment": true
  },

  // AC mapping requirements. Default: required=true.
  "ac_mapping": {
    "required": true,
    // Acceptable section headers (case-insensitive substring match).
    "section_headers": ["AC mapping", "AC Mapping", "ACs", "Acceptance Criteria"],
    // Required columns in the table (case-insensitive).
    "required_columns": ["AC", "Description", "Test", "Code", "Commit"]
  },

  // LGTM coverage requirements. Default: required=true.
  // The Reviewer's full plan is a local file; the published artifact is the
  // /lgtm marker, which is what these settings govern.
  "lgtm_coverage": {
    "required": true,
    // Marker prefix used in the HTML comment.
    "marker_prefix": "coding-flows:lgtm"
  },

  // Path-based scope rules. When the diff touches matching paths, the listed
  // skills/standards are loaded into context before reviewing/coding.
  "scope_rules": [
    {
      "paths": ["backend/**", "**/*.go"],
      "skills":    ["backend-coding-standards"],
      "standards": ["docs/standards/backend.md"]
    },
    {
      "paths": ["frontend/**", "**/*.{ts,tsx,jsx}"],
      "skills":    ["frontend-coding-standards"]
    }
  ],

  // Project-specific invariants. Each appears as a row in the Reviewer's
  // review plan when triggered.
  "invariants": [
    {
      "id": "events-before-publish",
      "rule": "every nats.Publish must be preceded by eventstore write",
      "triggered_by_paths": ["**/eventstore/**", "**/messaging/**"]
    }
  ],

  // High-risk PR auto-labeling.
  "high_risk_rules": [
    {
      "paths": ["**/auth/**", "**/security/**"],
      "label": "high-risk:auth"
    },
    {
      "paths": ["**/migrations/**"],
      "exclude_paths": ["**/test/**", "**/fixtures/**"],
      "label": "high-risk:migration"
    },
    {
      "size":  {"lines_changed": 1000},
      "exclude_labels": ["dependencies", "docs-only"],
      "label": "high-risk:large"
    }
  ],

  // Risk declaration enums. The PR body's `## Risks` table's Category
  // column must be one of `allowed_categories`. Default below.
  "risks": {
    "allowed_categories": [
      "migration", "feature-flag", "secret", "perf",
      "external-side-effect", "compat-break", "none"
    ]
  },

  // Scope-envelope exclusions. Changed files matching any of these globs
  // are auto-claimed (don't need an AC mapping row or Support files entry).
  // Use for generated code, lockfiles, docs-only ripples, etc.
  "scope_envelope": {
    "exclude_paths": [
      "*.md", "**/CHANGELOG*", "package-lock.json", "yarn.lock",
      "pnpm-lock.yaml", "go.sum", "Cargo.lock", "poetry.lock",
      "**/*.snap", ".github/dependabot.yml"
    ]
  },

  // Flaky test policy.
  "flake_policy": {
    // How many reruns are allowed before treating a failure as real.
    // Default: 1. Max 1 by design (raising this corrupts CI signal).
    "retry_count": 1,
    // Whether to open an issue when a flake is confirmed.
    "open_issue_on_persistent_failure": true
  },

  // Reviewer behavior.
  "reviewer": {
    // Apply the adversarial default-deny prompt. Default: true.
    "adversarial_prompt": true,
    // Labels that trigger dual-reviewer dispatch.
    "dual_review_label_globs": ["high-risk:*"]
  },

  // Iteration safeguards.
  "iteration": {
    // Trigger iteration-cap notification at this many rounds. Default: 5.
    "round_cap": 5
  }
}
```

## Defaults applied when `.coding-flows.json` is missing

```json
{
  "acting_user": "<from gh auth status>",
  "notification": {"label": "needs-human"},
  "worktree": {},
  "merge": {"method": "squash", "delete_branch": true, "post_merge_issue_comment": true},
  "ac_mapping": {"required": true,
                 "section_headers": ["AC mapping", "AC Mapping", "ACs", "Acceptance Criteria"],
                 "required_columns": ["AC", "Description", "Test", "Code", "Commit"]},
  "lgtm_coverage": {"required": true, "marker_prefix": "coding-flows:lgtm"},
  "scope_rules": [],
  "invariants": [],
  "high_risk_rules": [],
  "flake_policy": {"retry_count": 1, "open_issue_on_persistent_failure": true},
  "reviewer": {"adversarial_prompt": true, "dual_review_label_globs": ["high-risk:*"]},
  "iteration": {"round_cap": 5}
}
```

Core invariants (`ac_mapping.required`, `lgtm_coverage.required`,
`reviewer.adversarial_prompt`) default to `true` regardless of file presence
— they are load-bearing for the skill's strictness guarantees.

## Validation

`scripts/lib/common.sh` exports `read_config <jq-path> [default]` which:

- Locates `.coding-flows.json` by walking up from cwd.
- Returns the value, or `default` if file/key missing.
- Parses with `jq` (strict JSON — comments above are documentation only).

Use JSON without comments in actual config files.
