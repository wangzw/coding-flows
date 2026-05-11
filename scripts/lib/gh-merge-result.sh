#!/usr/bin/env bash
# Pure helper for classifying `gh pr merge` outcomes.
#
# `gh pr merge --delete-branch` exits non-zero when the local-side branch
# delete fails — typically because the worktree still has the branch
# checked out. In that case the REMOTE merge has already happened; our
# post-merge worktree cleanup will free the branch moments later. We need
# to distinguish this cosmetic failure from a real merge failure.
#
# Usage (sourced):
#   classify_gh_merge_result <exit_code> <remote_state> <output_text>
#   echo "${GH_MERGE_VERDICT}"   # one of: success | cosmetic-success | real-failure
#
# Pure function — no I/O, no globals besides the GH_MERGE_VERDICT output var.
# Tests call it with fixtures.

# Lines that count as "cosmetic" — anything else means a real problem.
# We accept the literal warning, the "! " prefix gh sometimes adds, and
# the success banner gh prints before the warning.
_gh_merge_is_cosmetic_line() {
  local line="$1"
  # Strip leading whitespace + `! ` prefix for matching.
  line="${line#"${line%%[![:space:]]*}"}"   # ltrim
  line="${line#! }"
  case "$line" in
    "")                                  return 0 ;;
    "failed to delete local branch"*)    return 0 ;;
    "Pull request #"*" merged"*)         return 0 ;;
    "✓ Merged pull request"*)            return 0 ;;
    "✓ Squashed and merged pull request"*) return 0 ;;
    "✓ Rebased and merged pull request"*)  return 0 ;;
  esac
  return 1
}

classify_gh_merge_result() {
  local rc="$1" remote_state="$2" output="$3"
  GH_MERGE_VERDICT="real-failure"

  if [[ "$rc" == "0" ]]; then
    GH_MERGE_VERDICT="success"
    return 0
  fi

  # rc != 0: only call it cosmetic if every non-blank output line is on
  # the allow-list AND the remote says the PR is MERGED.
  if [[ "$remote_state" != "MERGED" ]]; then
    return 0   # real-failure (default)
  fi

  local line
  while IFS= read -r line; do
    if ! _gh_merge_is_cosmetic_line "$line"; then
      return 0   # real-failure (non-cosmetic line present)
    fi
  done <<< "$output"

  GH_MERGE_VERDICT="cosmetic-success"
  return 0
}
