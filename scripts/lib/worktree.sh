# Worktree library.
#
# All functions assume the caller is inside a checkout of the target repo
# (cwd is the main repo or any worktree of it). `git -C` is used where the
# function needs a deterministic anchor, but most operations honor cwd.

# worktree_branch_to_slug <branch> — convert `fix/240-empty-pkg` to a
# filesystem-safe slug `fix-240-empty-pkg`. Slashes → dashes; everything
# else passes through (branch names already constrain to safe chars).
worktree_branch_to_slug() {
  local branch="$1"
  printf '%s' "${branch//\//-}"
}

# worktree_root [<config-path>] — emit the directory under which coding-flows
# manages worktrees. Resolution order:
#   1. .coding-flows.json `worktree.root` (absolute or relative-to-repo).
#   2. Default: $(repo_state_dir)/worktrees
worktree_root() {
  local root
  root="$(read_config '.worktree.root' '')"
  if [[ -n "$root" ]]; then
    if [[ "$root" != /* ]]; then
      local repo_root
      repo_root="$(_main_repo_root)" || return 1
      root="$repo_root/$root"
    fi
    printf '%s' "$root"
    return 0
  fi
  printf '%s/worktrees' "$(repo_state_dir)"
}

# worktree_path_for_branch <branch> — absolute path for this branch's
# managed worktree. Does NOT create anything.
worktree_path_for_branch() {
  local branch="$1"
  local slug
  slug="$(worktree_branch_to_slug "$branch")"
  printf '%s/%s' "$(worktree_root)" "$slug"
}

# worktree_create <branch> [<base-branch>] — create a new worktree at the
# managed path, with a new branch off <base-branch> (default: origin/HEAD
# or origin/main, whichever resolves).
#
# Output: absolute worktree path on stdout (only on success).
# Exit codes:
#   0  — created.
#   1  — branch already checked out somewhere, or worktree path exists.
#   2  — git operation failed.
#  64  — usage error.
worktree_create() {
  local branch="$1"
  local base="${2:-}"

  if [[ -z "$branch" ]]; then
    log_error "worktree_create: missing branch name"
    return 64
  fi

  # Resolve default base if not given
  if [[ -z "$base" ]]; then
    base="$(_default_base_branch)" || base="main"
    base="origin/$base"
  fi

  local path
  path="$(worktree_path_for_branch "$branch")"

  if [[ -d "$path" ]]; then
    log_error "worktree path already exists: $path"
    return 1
  fi

  # Sweep dead worktree records left over from manual rm-rf
  git worktree prune >/dev/null 2>&1 || true

  # Resume vs. fresh-create discrimination.
  # If the branch already exists locally AND another worktree is using it
  # → conflict, refuse.
  # If the branch exists but no worktree owns it → resume mode: attach a new
  # worktree to the existing branch.
  # Otherwise → fresh create from base.
  local mode="create"
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    if git worktree list --porcelain | grep -qE "^branch refs/heads/${branch}$"; then
      log_error "branch '$branch' is already checked out in another worktree"
      return 1
    fi
    mode="resume"
  fi

  if [[ "$mode" == "create" ]]; then
    # Make sure the base ref exists locally
    if ! git rev-parse --verify "$base" >/dev/null 2>&1; then
      git fetch origin "${base#origin/}" >/dev/null 2>&1 || {
        log_error "could not fetch base ref: $base"
        return 2
      }
    fi
  fi

  mkdir -p "$(dirname "$path")"
  if [[ "$mode" == "resume" ]]; then
    log_info "resuming branch '$branch' in a fresh worktree at $path"
    if ! git worktree add "$path" "$branch" >&2; then
      log_error "git worktree add (resume) failed"
      return 2
    fi
  else
    if ! git worktree add "$path" -b "$branch" "$base" >&2; then
      log_error "git worktree add failed"
      return 2
    fi
  fi
  printf '%s\n' "$path"
}

# worktree_list — emit one line per managed worktree:
#   <path>\t<branch>\t<head-sha>
# Only worktrees under $(worktree_root) are returned (so user's manual
# worktrees are not touched by coding-flows operations).
worktree_list() {
  local root
  root="$(worktree_root)"
  git worktree list --porcelain | awk -v root="$root" '
    /^worktree / { wt = substr($0, 10) }
    /^HEAD / { sha = substr($0, 6) }
    /^branch / {
      branch = substr($0, 8); sub("refs/heads/", "", branch)
      if (substr(wt, 1, length(root) + 1) == root "/") {
        printf "%s\t%s\t%s\n", wt, branch, sha
      }
    }
    /^$/ { wt = ""; sha = ""; branch = "" }
  '
}

# worktree_remove <branch> [--force] — remove the worktree + delete the
# local branch. Refuses (returns 1) if the worktree has uncommitted changes,
# unless --force is given. Returns 0 if there is no worktree to remove
# (idempotent).
worktree_remove() {
  local branch="$1"
  local force=0
  [[ "${2:-}" == "--force" ]] && force=1

  if [[ -z "$branch" ]]; then
    log_error "worktree_remove: missing branch name"
    return 64
  fi

  local path
  path="$(worktree_path_for_branch "$branch")"

  # If neither the dir nor the branch exists locally → nothing to do.
  if [[ ! -d "$path" ]] && ! git show-ref --verify --quiet "refs/heads/$branch"; then
    return 0
  fi

  if [[ -d "$path" ]]; then
    local remove_args=("$path")
    [[ $force -eq 1 ]] && remove_args=(--force "$path")
    if ! git worktree remove "${remove_args[@]}" >&2; then
      if [[ $force -eq 0 ]]; then
        log_error "worktree remove refused (uncommitted state?); retry with --force or clean up manually"
        return 1
      fi
      # Force-remove dangling registration
      git worktree prune >/dev/null 2>&1 || true
    fi
  fi

  # Delete local branch. -d (merged-only) when not forcing; -D otherwise.
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    if [[ $force -eq 1 ]]; then
      git branch -D "$branch" >/dev/null 2>&1 || true
    else
      git branch -d "$branch" >/dev/null 2>&1 || {
        log_warn "local branch '$branch' not deleted (not yet merged into upstream); use --force to override"
      }
    fi
  fi

  return 0
}

# worktree_prune — for every managed worktree whose branch has a corresponding
# PR in MERGED or CLOSED state, remove it. Branches without a PR are left
# alone (might be in-progress). Requires `gh` to query PR state.
worktree_prune() {
  local removed=0 kept=0 wt branch sha
  while IFS=$'\t' read -r wt branch sha; do
    [[ -z "$branch" ]] && continue
    local state
    state="$(gh pr list --head "$branch" --state all --limit 1 --json state --jq '.[0].state // "NO_PR"' 2>/dev/null || echo "QUERY_FAILED")"
    case "$state" in
      MERGED|CLOSED)
        log_info "pruning worktree for $branch (PR state=$state)"
        if worktree_remove "$branch" --force; then
          removed=$((removed + 1))
        fi
        ;;
      OPEN|NO_PR|QUERY_FAILED)
        kept=$((kept + 1))
        ;;
    esac
  done < <(worktree_list)
  printf 'WORKTREES_REMOVED=%d\nWORKTREES_KEPT=%d\n' "$removed" "$kept"
}

# Internal helpers ---------------------------------------------------------

# _main_repo_root — absolute path to the primary worktree (main checkout).
# Works from any worktree of the same repo.
_main_repo_root() {
  local common
  common="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  [[ -z "$common" ]] && return 1
  if [[ "$common" != /* ]]; then
    common="$(cd "$common" && pwd)"
  fi
  dirname "$common"
}

# _default_base_branch — best-effort: ref name (e.g. "main" or "master") of
# the repo's default branch. Tries origin/HEAD, falls back to plain "main".
_default_base_branch() {
  local ref
  ref="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)"
  if [[ -n "$ref" ]]; then
    printf '%s' "${ref#refs/remotes/origin/}"
    return 0
  fi
  # No origin/HEAD set — try common defaults
  if git show-ref --verify --quiet refs/remotes/origin/main; then
    printf 'main'; return 0
  fi
  if git show-ref --verify --quiet refs/remotes/origin/master; then
    printf 'master'; return 0
  fi
  return 1
}
