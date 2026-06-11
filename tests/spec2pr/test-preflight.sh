#!/usr/bin/env bash
# Preflight contract for scripts/spec2pr.sh.

test_preflight_no_args_usage() {
  make_sandbox
  run_spec2pr
  assert_eq "1" "$RC" "no args exits 1"
  assert_contains "$OUT" "SPEC2PR HALT preflight: usage: spec2pr.sh <spec-path>" "no args prints usage halt"
}

test_preflight_missing_spec() {
  make_sandbox
  run_spec2pr "$PROJECT/docs/superpowers/specs/missing.md"
  assert_eq "1" "$RC" "missing spec exits 1"
  assert_contains "$OUT" "SPEC2PR HALT preflight:" "missing spec prints preflight halt"
}

test_preflight_oversized_spec_splits_before_dependency_gate() {
  make_sandbox
  perl -e 'print "x" x 40000' > "$SPEC"
  SPEC2PR_MAX_SPEC=32768 SPEC2PR_CODEX_BIN="$SANDBOX/bin/not-codex" run_spec2pr "$SPEC"
  assert_eq "2" "$RC" "oversized spec exits 2"
  assert_contains "$OUT" "SPEC2PR SPLIT spec size=40000 limit=32768" "oversized spec prints split"
}

test_preflight_missing_dependency() {
  make_sandbox
  SPEC2PR_CODEX_BIN="$SANDBOX/bin/not-codex" run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "missing dependency exits 1"
  assert_contains "$OUT" "missing dependency" "missing dependency named"
}

test_preflight_empty_slug() {
  make_sandbox
  local empty_slug_spec="$PROJECT/docs/superpowers/specs/!!!.md"
  printf '# Empty slug\n' > "$empty_slug_spec"
  run_spec2pr "$empty_slug_spec"
  assert_eq "1" "$RC" "empty slug exits 1"
  assert_contains "$OUT" "empty slug" "empty slug named"
}

test_preflight_spec_outside_git_repo() {
  make_sandbox
  local outside_dir="$SANDBOX/outside"
  local outside_spec="$outside_dir/spec.md"
  mkdir -p "$outside_dir"
  printf '# Outside repo\n' > "$outside_spec"
  run_spec2pr "$outside_spec"
  assert_eq "1" "$RC" "outside repo exits 1"
  assert_contains "$OUT" "SPEC2PR HALT preflight: spec is not inside a git repository" "outside repo prints planned halt"
}

test_preflight_partial_run_writes_flat_status_file() {
  make_sandbox
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "partial run exits 1 through later-stage halt"
  assert_file_exists "$SPEC2PR_HOME/$ID.status" "partial run writes flat status file"
  assert_contains "$(last_status_line)" "SPEC2PR HALT spec-review: codex spec-review-r1 failed" "later-stage halt recorded in status"
}

test_preflight_sanitize_preserves_underscore() {
  make_sandbox
  local underscore_spec="$PROJECT/docs/superpowers/specs/foo_bar.md"
  local underscore_id="project-foo_bar"
  printf '# Underscore slug\n' > "$underscore_spec"
  run_spec2pr "$underscore_spec"
  assert_file_exists "$SPEC2PR_HOME/$underscore_id.status" "underscore slug retained in status file"
}

test_preflight_first_run_creates_worktree_and_imports_spec() {
  make_sandbox
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "valid pre-review run exits through later-stage halt"
  assert_file_exists "$SPEC2PR_WORKTREES/$ID" "worktree created"
  assert_file_exists "$SPEC2PR_WORKTREES/$ID/docs/superpowers/specs/toy-spec.md" "spec copied into worktree"
  assert_eq "$BRANCH" "$(git -C "$SPEC2PR_WORKTREES/$ID" branch --show-current)" "worktree is on spec branch"
  assert_eq "spec2pr: import spec" "$(git -C "$SPEC2PR_WORKTREES/$ID" log -1 --pretty=%s)" "import commit created"
  assert_file_exists "$SPEC2PR_HOME/$ID/source-path" "source path metadata recorded"
  assert_file_exists "$SPEC2PR_HOME/$ID/source-sha256" "source hash metadata recorded"
  assert_file_exists "$SPEC2PR_HOME/$ID/base-sha" "base sha metadata recorded"
  local canonical_spec
  canonical_spec="$(cd "$(dirname "$SPEC")" && pwd -P)/$(basename "$SPEC")"
  assert_eq "$canonical_spec" "$(cat "$SPEC2PR_HOME/$ID/source-path")" "source path metadata matches"
  assert_contains "$(cat "$SPEC2PR_HOME/$ID.status")" "SPEC2PR OK preflight: preflight ok" "preflight ok logged"
}

test_preflight_foreign_lock_blocks_and_remains() {
  make_sandbox
  mkdir -p "$SPEC2PR_HOME/$ID.lock"
  printf '999999\n' > "$SPEC2PR_HOME/$ID.lock/pid"
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "foreign lock exits 1"
  assert_contains "$OUT" "SPEC2PR HALT preflight:" "foreign lock halts"
  assert_file_exists "$SPEC2PR_HOME/$ID.lock/pid" "foreign lock pid remains"
  assert_eq "999999" "$(cat "$SPEC2PR_HOME/$ID.lock/pid")" "foreign lock pid untouched"
}

test_preflight_changed_source_after_import_halts() {
  make_sandbox
  run_spec2pr "$SPEC"
  printf '\nChanged after import.\n' >> "$SPEC"
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "changed source exits 1"
  assert_contains "$OUT" "source spec changed since import" "changed source halt named"
}

test_preflight_same_id_different_source_path_halts() {
  make_sandbox
  run_spec2pr "$SPEC"
  local other_project="$SANDBOX/other/project"
  mkdir -p "$SANDBOX/other"
  git clone -q "$ORIGIN" "$other_project"
  git -C "$other_project" config user.email "test@test"
  git -C "$other_project" config user.name "spec2pr-test"
  mkdir -p "$other_project/docs/superpowers/specs"
  printf '# Toy spec\n\nAdd a --version flag.\n' > "$other_project/docs/superpowers/specs/toy-spec.md"
  run_spec2pr "$other_project/docs/superpowers/specs/toy-spec.md"
  assert_eq "1" "$RC" "same id different path exits 1"
  assert_contains "$OUT" "worktree belongs to" "different source path halt named"
}

test_preflight_dotted_lock_slug_is_ref_safe() {
  make_sandbox
  local dotted_spec="$PROJECT/docs/superpowers/specs/foo.bar.lock.md"
  local dotted_id="project-foo-bar-lock"
  printf '# Dotted lock slug\n' > "$dotted_spec"
  run_spec2pr "$dotted_spec"
  assert_file_exists "$SPEC2PR_WORKTREES/$dotted_id" "dotted lock slug worktree created"
  assert_eq "spec2pr/foo-bar-lock" "$(git -C "$SPEC2PR_WORKTREES/$dotted_id" branch --show-current)" "dotted lock slug branch is safe"
}
