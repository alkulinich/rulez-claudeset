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
