#!/usr/bin/env bash
# Tests for scripts/lib/worktree.sh. Uses a real temp git repo (git init +
# initial commit) so create/list/remove can be exercised end-to-end without
# touching a real GitHub remote.
set -uo pipefail

TEST_FILE="test_worktree.sh"
TEST_PASS=0
TEST_FAIL=0

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$THIS_DIR/.." && pwd)"
export SKILL_DIR

# shellcheck source=lib/assert.sh
source "$THIS_DIR/lib/assert.sh"
# shellcheck source=../scripts/lib/common.sh
source "$SKILL_DIR/scripts/lib/common.sh"
# shellcheck source=../scripts/lib/worktree.sh
source "$SKILL_DIR/scripts/lib/worktree.sh"

# --- Slug computation (pure, no git) --------------------------------------
assert_eq "slug: simple" "fix-240-foo" "$(worktree_branch_to_slug "fix/240-foo")"
assert_eq "slug: nested" "feat-some-feature" "$(worktree_branch_to_slug "feat/some/feature")"
assert_eq "slug: no slash" "topic" "$(worktree_branch_to_slug "topic")"

# --- Set up a real git repo + cache root for integration tests -----------
TMP_PARENT="$(mktemp -d)"
REPO="$TMP_PARENT/repo"
CACHE="$TMP_PARENT/cache"
mkdir -p "$REPO" "$CACHE"

# Per-cycle env. Exported so subshells in `(...)` inherit.
export CODING_FLOWS_CACHE_DIR="$CACHE"
export CODING_FLOWS_REPO_NWO="acme/widget"

(
  cd "$REPO"
  git init -q -b main
  # Defang any host-wide hooks (commitlint, gpg-sign, etc.) so the test
  # repo's commits are unconstrained.
  git config core.hooksPath /dev/null
  git config commit.gpgsign false
  git config user.email "test@example.com"
  git config user.name "Test"
  echo "hello" > README.md
  git add README.md
  git commit -q -m "initial"
  # Use the same dir as `origin` so fetch sets up remote-tracking refs.
  git remote add origin "$REPO"
  git fetch origin -q
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
) >/dev/null

# Run a function in the repo cwd, with our test env. Funcs are already
# sourced into THIS shell, so a subshell `(cd ... && f ...)` is sufficient.
in_repo() ( cd "$REPO" && "$@" )
in_path() ( cd "$1" && shift && "$@" )

# Path resolution honors cache root + per-repo namespacing
got="$(in_repo worktree_path_for_branch "fix/1-foo")"
expected="$CACHE/acme/widget/worktrees/fix-1-foo"
assert_eq "path: cache-rooted" "$expected" "$got"

# Path resolution honors .coding-flows.json `worktree.root` (relative to repo)
echo '{"worktree":{"root":".wt"}}' > "$REPO/.coding-flows.json"
got="$(in_repo worktree_path_for_branch "chore/9-x")"
assert_eq "path: config-rooted relative" "$REPO/.wt/chore-9-x" "$got"
rm -f "$REPO/.coding-flows.json"

# --- worktree_create -----------------------------------------------------
got="$(in_repo worktree_create "fix/100-bar" "origin/main" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code "create: ok" 0 "$rc"
expected="$CACHE/acme/widget/worktrees/fix-100-bar"
assert_eq         "create: emits path" "$expected" "$got"
[[ -d "$got" ]] && rc=0 || rc=1
assert_exit_code  "create: dir exists" 0 "$rc"

# Branch is checked out at the new path
branch_in_wt="$(cd "$got" && git rev-parse --abbrev-ref HEAD)"
assert_eq         "create: branch in worktree" "fix/100-bar" "$branch_in_wt"

# Re-creating the same branch is refused
in_repo worktree_create "fix/100-bar" "origin/main" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code  "create: duplicate refused" 1 "$rc"

# --- worktree_list -------------------------------------------------------
out="$(in_repo worktree_list)"
assert_contains   "list: includes new worktree" "fix/100-bar" "$out"
line="$(printf '%s\n' "$out" | grep 'fix/100-bar' | head -n1)"
tabs="$(awk -F'\t' '{print NF}' <<<"$line")"
assert_eq         "list: tab-separated 3 cols" "3" "$tabs"

# --- worktree_remove -----------------------------------------------------
# Commit something in the worktree, then remove. Hooks already disabled
# at the repo level, so this is a plain commit.
( cd "$got"
  git config core.hooksPath /dev/null
  git config commit.gpgsign false
  echo "stuff" > new.txt
  git add new.txt
  git commit -q -m "stuff"
) >/dev/null

in_repo worktree_remove "fix/100-bar" >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code  "remove: ok (no force)" 0 "$rc"
[[ -d "$got" ]] && rc=1 || rc=0
assert_exit_code  "remove: dir gone" 0 "$rc"

# --- Resume path: branch still exists locally, no active worktree ---------
# Because the branch has an unmerged commit ("stuff"), the previous remove
# left the local branch in place. worktree_create should resume against it
# rather than refusing.
in_repo git show-ref --verify --quiet "refs/heads/fix/100-bar" && rc=0 || rc=$?
assert_exit_code  "resume-prep: branch still exists" 0 "$rc"
got_resume="$(in_repo worktree_create "fix/100-bar" "origin/main" 2>/dev/null)" && rc=0 || rc=$?
assert_exit_code  "resume: exit 0" 0 "$rc"
[[ -d "$got_resume" ]] && rc=0 || rc=1
assert_exit_code  "resume: dir exists" 0 "$rc"
resume_branch="$(cd "$got_resume" && git rev-parse --abbrev-ref HEAD)"
assert_eq         "resume: same branch attached" "fix/100-bar" "$resume_branch"
( cd "$got_resume" && git log --oneline | grep -q stuff ) && rc=0 || rc=$?
assert_exit_code  "resume: prior commit preserved" 0 "$rc"

# Idempotent cleanup
in_repo worktree_remove "fix/100-bar" --force >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code  "remove: post-resume cleanup" 0 "$rc"
in_repo worktree_remove "fix/100-bar" --force >/dev/null 2>&1 && rc=0 || rc=$?
assert_exit_code  "remove: idempotent" 0 "$rc"

# --- _main_repo_root from a worktree -------------------------------------
in_repo worktree_create "feat/200-x" "origin/main" >/dev/null 2>&1
new_wt="$CACHE/acme/widget/worktrees/feat-200-x"
[[ -d "$new_wt" ]] && rc=0 || rc=1
assert_exit_code  "create feat/200-x: dir exists" 0 "$rc"

main_root_from_wt="$(in_path "$new_wt" _main_repo_root)"
# git may return the realpath; normalize via realpath for stable comparison
expected_root="$(realpath "$REPO" 2>/dev/null || echo "$REPO")"
actual_root="$(realpath "$main_root_from_wt" 2>/dev/null || echo "$main_root_from_wt")"
assert_eq "_main_repo_root from worktree" "$expected_root" "$actual_root"

# --- find_repo_config fallback to main repo from worktree ----------------
echo '{"acting_user":"tu"}' > "$REPO/.coding-flows.json"
got_cfg="$(in_path "$new_wt" find_repo_config)"
expected_cfg="$expected_root/.coding-flows.json"
actual_cfg="$(realpath "$got_cfg" 2>/dev/null || echo "$got_cfg")"
assert_eq "find_repo_config: works from worktree" "$expected_cfg" "$actual_cfg"

# Clean up
in_repo worktree_remove "feat/200-x" --force >/dev/null 2>&1
rm -rf "$TMP_PARENT"

test_summary
