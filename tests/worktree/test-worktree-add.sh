#!/usr/bin/env bash

# Run the wrapper inside <dir> with the given args. Captures:
#   WT_PATH = stdout (the worktree path, single line)
#   WT_ERR  = stderr (narration)
#   WT_RC   = exit code
run_wta() {
  local dir="$1"; shift
  local errfile; errfile="$(mktemp)"
  WT_PATH="$(cd "$dir" && bash "$WORKTREE_ADD" "$@" 2>"$errfile")"
  WT_RC=$?
  WT_ERR="$(cat "$errfile")"
  rm -f "$errfile"
}

test_worktree_add_new_branch() {
  make_repo
  run_wta "$PROJECT" feature/foo
  assert_eq "0" "$WT_RC" "new branch: exits 0"
  assert_eq "$PROJECT_REAL/.worktrees/feature/foo" "$WT_PATH" \
    "new branch: path is project-root .worktrees/<branch>"
  assert_file_exists "$WT_PATH" "new branch: worktree dir exists"
  assert_eq "feature/foo" "$(git -C "$WT_PATH" branch --show-current)" \
    "new branch: worktree is on feature/foo"
}

test_worktree_add_existing_local_branch() {
  make_repo
  git -C "$PROJECT" branch existing-local
  run_wta "$PROJECT" existing-local
  assert_eq "0" "$WT_RC" "existing local: exits 0"
  assert_eq "existing-local" "$(git -C "$WT_PATH" branch --show-current)" \
    "existing local: worktree is on that branch"
}

test_worktree_add_remote_only_branch() {
  make_repo
  git -C "$PROJECT" branch remote-feature
  git -C "$PROJECT" push -q origin remote-feature
  git -C "$PROJECT" branch -D remote-feature
  git -C "$PROJECT" fetch -q origin
  run_wta "$PROJECT" remote-feature
  assert_eq "0" "$WT_RC" "remote-only: exits 0"
  assert_eq "remote-feature" "$(git -C "$WT_PATH" branch --show-current)" \
    "remote-only: worktree tracks the origin branch"
}

test_worktree_add_gitignores_without_commit() {
  make_repo
  rm -f "$PROJECT/.gitignore"
  run_wta "$PROJECT" feature/ig
  assert_eq "0" "$WT_RC" "gitignore: exits 0"
  assert_file_exists "$PROJECT/.gitignore" "gitignore: .gitignore created"
  assert_contains "$(cat "$PROJECT/.gitignore")" ".worktrees/" \
    "gitignore: contains .worktrees/"
  assert_contains "$(git -C "$PROJECT" status --porcelain -- .gitignore)" ".gitignore" \
    "gitignore: left uncommitted (shows in git status)"
}

test_worktree_add_gitignore_no_duplicate_when_preignored() {
  make_repo
  # The failing case: pattern already present, but no .worktrees dir on disk yet
  # — a trailing-slash pattern does not match the bare path until the dir exists.
  printf '.worktrees/\n' > "$PROJECT/.gitignore"
  run_wta "$PROJECT" feature/pre
  assert_eq "0" "$WT_RC" "preignored: exits 0"
  assert_eq "1" "$(grep -c '^\.worktrees/$' "$PROJECT/.gitignore")" \
    "preignored: .worktrees/ not duplicated when already ignored"
}

test_worktree_add_anchors_at_main_root_from_inside_worktree() {
  make_repo
  run_wta "$PROJECT" feature/first
  assert_eq "0" "$WT_RC" "anchor: first worktree created"
  local first="$WT_PATH"
  run_wta "$first" feature/second
  assert_eq "0" "$WT_RC" "anchor: second worktree created from inside first"
  assert_eq "$PROJECT_REAL/.worktrees/feature/second" "$WT_PATH" \
    "anchor: lands at main root, not nested inside the first worktree"
}

test_worktree_add_respects_base_ref() {
  make_repo
  local base_sha; base_sha="$(git -C "$PROJECT" rev-parse HEAD)"
  printf 'second\n' >> "$PROJECT/README.md"
  git -C "$PROJECT" commit -qam second
  run_wta "$PROJECT" feature/frombase "$base_sha"
  assert_eq "0" "$WT_RC" "base: exits 0"
  assert_eq "$base_sha" "$(git -C "$WT_PATH" rev-parse HEAD)" \
    "base: new branch forks from the given base ref"
}
