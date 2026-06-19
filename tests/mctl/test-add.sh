#!/usr/bin/env bash

test_mctl_sanitize_matches_spec2pr_family() {
  make_sandbox
  source_mctl

  assert_eq "foo-bar" "$(sanitize " Foo!!Bar ")" "sanitize replaces invalid runs and trims"
  assert_eq "my_repo-7" "$(sanitize "My_Repo-7")" "sanitize keeps underscore and dash"
}

test_mctl_shell_quote_handles_spaces_and_single_quotes() {
  make_sandbox
  source_mctl

  assert_eq "'plain value'" "$(shell_quote "plain value")" "shell_quote wraps spaced values"
  assert_eq "'it'\''s fine'" "$(shell_quote "it's fine")" "shell_quote escapes single quote"
}

test_mctl_script_dir_resolves_real_scripts_directory() {
  make_sandbox
  source_mctl

  assert_eq "$REPO_ROOT/scripts" "$SCRIPT_DIR" "script dir is absolute scripts directory"
  assert_eq "$REPO_ROOT/scripts/spec2pr.sh" "$SPEC2PR_SCRIPT" "spec2pr path is absolute"
  assert_eq "$REPO_ROOT/scripts/review-pr.sh" "$REVIEW_PR_SCRIPT" "review-pr path is absolute"
  assert_eq "$REPO_ROOT/scripts/spec2pr-watch.sh" "$WATCH_SCRIPT" "watch path is absolute"
}

test_add_spec2pr_writes_registry_metadata_and_brief_log() {
  make_sandbox
  run_mctl add spec2pr "$SPEC"

  local run_dir="$RULEZ_CLAUDESET_HOME/mctl/repo-foo-bar"
  assert_eq "0" "$RC" "add spec2pr exits 0"
  assert_contains "$OUT" "repo-foo-bar" "add prints run name"
  assert_file_exists "$run_dir/meta" "meta file created"
  assert_file_exists "$run_dir/brief.log" "brief log created before launch"
  assert_eq "spec2pr" "$(meta_value "$run_dir/meta" kind)" "meta kind"
  assert_eq "repo-foo-bar" "$(meta_value "$run_dir/meta" token)" "meta token is repo-qualified name"
  assert_eq "mctl-repo-foo-bar" "$(meta_value "$run_dir/meta" session)" "meta session"
  assert_eq "$REPO" "$(meta_value "$run_dir/meta" repo)" "spec2pr repo root comes from spec"
  assert_eq "$SPEC2PR_HOME" "$(meta_value "$run_dir/meta" spec2pr_home)" "meta stores effective SPEC2PR_HOME"
  assert_eq "$SPEC2PR_WORKTREES" "$(meta_value "$run_dir/meta" spec2pr_worktrees)" "meta stores effective SPEC2PR_WORKTREES"
}

test_add_review_pr_writes_repo_qualified_pr_metadata() {
  make_sandbox
  run_mctl_in_dir "$REPO" add review-pr 7

  local run_dir="$RULEZ_CLAUDESET_HOME/mctl/repo-pr-7"
  assert_eq "0" "$RC" "add review-pr exits 0"
  assert_file_exists "$run_dir/meta" "review-pr meta file created"
  assert_eq "review-pr" "$(meta_value "$run_dir/meta" kind)" "review-pr meta kind"
  assert_eq "repo-pr-7" "$(meta_value "$run_dir/meta" token)" "review-pr token"
  assert_eq "$REPO" "$(meta_value "$run_dir/meta" repo)" "review-pr repo root comes from cwd"
}

test_add_refuses_missing_spec_non_numeric_pr_and_outside_repo() {
  make_sandbox

  run_mctl add spec2pr "$SANDBOX/missing.md"
  assert_eq "1" "$RC" "missing spec exits 1"
  assert_contains "$OUT" "spec not found" "missing spec message"

  run_mctl_in_dir "$REPO" add review-pr abc
  assert_eq "1" "$RC" "non-numeric pr exits 1"
  assert_contains "$OUT" "pr number must be numeric" "non-numeric pr message"

  mkdir -p "$SANDBOX/notrepo"
  run_mctl_in_dir "$SANDBOX/notrepo" add review-pr 7
  assert_eq "1" "$RC" "review-pr outside repo exits 1"
  assert_contains "$OUT" "not inside a git repository" "outside repo message"
}

test_add_refuses_existing_registry_dir_without_removing_it() {
  make_sandbox
  local run_dir="$RULEZ_CLAUDESET_HOME/mctl/repo-foo-bar"
  mkdir -p "$run_dir"
  printf 'rc=0\nfinished=2026-06-19T00:00:00Z\n' > "$run_dir/exit"

  run_mctl add spec2pr "$SPEC"

  assert_eq "1" "$RC" "existing registry exits 1"
  assert_contains "$OUT" "completed run exists" "completed registry refusal"
  assert_file_exists "$run_dir/exit" "existing exit marker remains"
}
