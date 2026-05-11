# Worktrees

Each issue the Coder picks up gets its own **git worktree**: a sibling
checkout backed by the same `.git` directory, on its own branch. The
Coder rotates between worktrees as items hand off to CI / Reviewer; no
single cycle invocation blocks on either. See
[coder-cycle.md](coder-cycle.md) for the rotation semantics.

## Why worktrees

- **Isolation**: each issue's working tree is separate. No `git checkout`
  thrash, no half-applied stashes, no risk of cross-contamination.
- **Per-item state on disk**: the local Coder plan, the local DB / test
  fixtures, anything generated during build — all stay in the worktree
  and survive between cycle invocations.
- **Clean main checkout**: the main repo's working tree is never touched
  by per-issue work. Pre-flight can stop refusing to start when main has
  unrelated dirty state.
- **Clean rotation**: switching items is just `cd $(coding-flows-worktree-path
  <branch>)`. No git operation needed.

## Where they live

Default: **siblings of the main checkout**, sharing the project parent
directory:

```
~/workspace/castworks/
├── main/            ← main checkout (the cwd of the Coder cycle)
├── fix-240-empty-packages/   ← worktree
├── feat-301-vault-policies/  ← worktree
└── chore-555-bump-deps/      ← worktree
```

The default worktree root is `dirname(main-repo-root)`, so if the main
checkout is at `~/workspace/castworks/main`, worktrees land at
`~/workspace/castworks/<branch-slug>/`.

This layout assumes you put the main checkout in its own subdirectory
under a project parent (e.g. `castworks/main/`). If your main checkout
is at `~/workspace/castworks/` directly, the default puts worktrees as
siblings of `castworks/` in `~/workspace/`, which is workable but
noisier — consider restructuring to the `castworks/main` pattern or
overriding via config (see below).

Plans (Coder + Reviewer) still live under
`~/.cache/coding-flows/<owner>/<repo>/` — those are internal agent
state, not something the user `cd`s into.

Resolution order for worktree root:

1. `.coding-flows.json` `worktree.root` (absolute or relative-to-repo).
2. `$CODING_FLOWS_WORKTREE_ROOT` env var (test/CI override; absolute).
3. Default: `dirname(main-repo-root)`.

Override via `.coding-flows.json`:

```json
"worktree": {
  "root": "../my-worktrees"        // relative to main repo root, OR
  "root": "/var/lib/coding-flows"  // absolute
}
```

Relative paths are anchored to the main repo root, not cwd. Worktrees
must live outside the main repo's working tree (git refuses to nest
them).

## Lifecycle scripts

| Script | When to call |
|--------|--------------|
| `coding-flows-worktree-path <branch>` | Resolve the path for a branch — no I/O |
| `coding-flows-worktree-create <branch> [<base>]` | Phase B (start) or Phase E (resume) |
| `coding-flows-worktree-list` | Phase A (enumerate) — emits `<path>\t<branch>\t<sha>` per managed worktree |
| `coding-flows-worktree-sync [<branch>]` | Run from inside a worktree to rebase onto latest base (use sparingly — only when CI etc. would otherwise replay) |
| `coding-flows-worktree-remove <branch> [--force]` | Called automatically by `coding-flows-merge`; manual for abandoned work |
| `coding-flows-worktree-prune` | Pre-flight (every cycle) — retires worktrees whose PRs have merged/closed |

Only worktrees under the configured root are touched by `list` / `prune` —
manual `git worktree add` paths elsewhere are invisible to coding-flows.

## Phase B integration (creating a worktree)

```bash
WT="$(coding-flows-worktree-create fix/240-empty-pkg origin/main)"
cd "$WT"
```

- Branch must not already exist locally (script refuses; user/skill must
  remove the old worktree first).
- Base ref defaults to `origin/HEAD` → `main` / `master`.
- The script runs `git worktree prune` first to clean up tombstones from
  manual `rm -rf`.

## Phase E integration (resuming a worktree)

If the worktree was cleaned up between cycles (e.g., long gap, machine
restart) but the PR's branch still exists upstream:

```bash
if [[ ! -d "$(coding-flows-worktree-path <branch>)" ]]; then
  git fetch origin <branch>
  # Use --branch path on git worktree add to attach to the existing remote branch
  git worktree add "$(coding-flows-worktree-path <branch>)" -B <branch> origin/<branch>
fi
cd "$(coding-flows-worktree-path <branch>)"
```

(The CLI wrapper doesn't currently expose this exact pattern; the Coder
cycle is expected to combine `coding-flows-worktree-path` + raw `git worktree
add` for the resume path.)

## Phase F integration (auto-cleanup on merge)

`coding-flows-merge` ends with `_post_merge_cleanup`:

1. cd to the main repo root (out of the worktree about to be removed).
2. `worktree_remove "$branch"` — removes the worktree dir and deletes the
   local branch (refuses on uncommitted state without `--force`).
3. `rm -rf ~/.cache/coding-flows/<owner>/<repo>/pr-<N>/` — clears the per-PR
   plan / cache directory.

`--keep-worktree` on `coding-flows-merge` skips step 2/3 — useful for debugging
a merged branch's local state.

## Garbage collection

`coding-flows-worktree-prune` runs at the top of every Coder cycle:

- For each managed worktree, query `gh pr list --head <branch> --state all`.
- If the PR is `MERGED` or `CLOSED` → remove the worktree (with --force,
  since the remote branch is gone too).
- If the PR is `OPEN` → keep.
- If there is no PR for the branch → keep (might be in-progress).
- If `gh` fails → keep (don't punish a transient outage).

Worktrees outside the configured root are never touched.

## Concurrency

The skill does **not** cap concurrent worktrees. Each cycle is serial
within itself (one build/test at a time), and the rotation logic in
[coder-cycle.md](coder-cycle.md) handles work-stealing across items
without needing a parallelism limit.

If two cycle invocations overlap (e.g. a `slock reminder` fires while a
prior `/loop` tick is still running), each cycle's actions on a given
branch are guarded by a `.coding-flows.lock` file inside the worktree (best
effort; stale locks older than 30 min are ignored).

## Pre-flight semantics with worktrees

Old (pre-worktree): "git status shows unrelated dirty state → abort
cycle". This was hostile to long-running work.

New: the main checkout's `git status` is no longer pre-flight-blocking.
Per-worktree state is checked per-item in Phase B / E. The Coder may have
many in-progress worktrees with dirty state simultaneously — that's
expected, not a failure.

The one remaining hard rule: **never** start an item whose target worktree
has uncommitted changes from an interrupted prior cycle. The Coder must
resolve (commit / discard) before continuing.
