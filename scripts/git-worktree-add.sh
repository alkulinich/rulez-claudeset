#!/usr/bin/env bash
# git-worktree-add.sh — create a git worktree under the project-root .worktrees/
# directory (kept gitignored), instead of an arbitrary path.
#
# Usage: git-worktree-add.sh <branch> [<base>]
#   <branch>  branch to check out in the new worktree. Created if it does not
#             exist (as a local or origin/ branch); checked out if it does.
#   <base>    optional base ref for a NEW branch (default: HEAD). Ignored when
#             <branch> already exists.
#
# Narration goes to stderr; the worktree's absolute path is the only stdout
# line, so this works:  cd "$(git-worktree-add.sh feature/foo)"
set -euo pipefail

if command -v rtk &>/dev/null; then rtk() { command rtk "$@"; }; else rtk() { "$@"; }; fi

BRANCH="${1:-}"
BASE="${2:-}"

if [ -z "$BRANCH" ]; then
  echo "usage: git-worktree-add.sh <branch> [<base>]" >&2
  exit 1
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "error: not inside a git repository" >&2
  exit 1
fi

# Anchor at the MAIN repo root (not the current worktree) so that running this
# from inside a worktree still lands the new one at the top level, never nested.
COMMON="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
MAIN_ROOT="$(dirname "$COMMON")"
WORKTREES_DIR="$MAIN_ROOT/.worktrees"
TARGET="$WORKTREES_DIR/$BRANCH"

# Ensure .worktrees/ is gitignored. The ignore takes effect immediately, so we
# do NOT commit (honors "commit only when asked"). Probe the target path *under*
# .worktrees/, not the bare directory: a trailing-slash pattern only matches a
# directory, and `check-ignore .worktrees` returns "not ignored" until that dir
# exists on disk — which would append a duplicate line on the first run.
if ! git -C "$MAIN_ROOT" check-ignore -q ".worktrees/$BRANCH"; then
  printf '.worktrees/\n' >> "$MAIN_ROOT/.gitignore"
  echo "note: added .worktrees/ to $MAIN_ROOT/.gitignore (uncommitted)" >&2
fi

# Resolve the branch (existing local, existing remote, or new), mirroring
# git-start-issue.sh's order. Build the argument list for git worktree add.
add_args=()
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  if [ -n "$BASE" ]; then
    echo "warning: branch '$BRANCH' already exists; ignoring base '$BASE'" >&2
  fi
  add_args=("$TARGET" "$BRANCH")
elif git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  if [ -n "$BASE" ]; then
    echo "warning: branch 'origin/$BRANCH' already exists; ignoring base '$BASE'" >&2
  fi
  add_args=(--track -b "$BRANCH" "$TARGET" "origin/$BRANCH")
else
  if [ -n "$BASE" ]; then
    add_args=(-b "$BRANCH" "$TARGET" "$BASE")
  else
    add_args=(-b "$BRANCH" "$TARGET")
  fi
fi

# Run once; send git's own progress to stderr so stdout carries only the path.
if ! rtk git worktree add "${add_args[@]}" >&2; then
  echo "error: 'git worktree add' failed — target may exist or the branch is checked out in another worktree" >&2
  exit 1
fi

echo "worktree ready: branch '$BRANCH' at $TARGET" >&2
printf '%s\n' "$TARGET"
