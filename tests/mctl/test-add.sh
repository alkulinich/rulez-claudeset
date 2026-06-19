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

test_add_launches_tmux_session_with_script_wrapper_and_verbose_env() {
  make_sandbox
  run_mctl add spec2pr "$SPEC"

  local log
  log="$(cat "$SANDBOX/tmux.log")"
  assert_contains "$log" "tmux [new-session] [-d] [-s] [mctl-repo-foo-bar]" "tmux new-session created"
  assert_contains "$log" "SPEC2PR_VERBOSE=1" "runner exports verbose mode"
  assert_contains "$log" "$REPO_ROOT/scripts/spec2pr.sh" "runner uses absolute spec2pr path"
  assert_contains "$log" "$SPEC" "runner uses canonical spec path"
  assert_contains "$log" "$RULEZ_CLAUDESET_HOME/mctl/repo-foo-bar/brief.log" "script writes brief log"
  assert_contains "$log" "$RULEZ_CLAUDESET_HOME/mctl/repo-foo-bar/exit" "runner writes exit marker"
}

test_add_review_pr_launches_review_runner_from_repo_root() {
  make_sandbox
  run_mctl_in_dir "$REPO" add review-pr 7

  local log
  log="$(cat "$SANDBOX/tmux.log")"
  assert_contains "$log" "$REPO_ROOT/scripts/review-pr.sh" "runner uses absolute review-pr path"
  assert_contains "$log" "'7'" "runner passes quoted PR number"
  assert_contains "$log" "$(shell_escape_for_test "$REPO")" "runner cd command mentions repo root"
}

test_add_quotes_paths_with_spaces_in_runner_command() {
  make_sandbox
  run_mctl add spec2pr "$SPEC"

  local log
  log="$(cat "$SANDBOX/tmux.log")"
  assert_contains "$log" "'$RULEZ_CLAUDESET_HOME/mctl/repo-foo-bar/brief.log'" "brief path with spaces is quoted"
  assert_contains "$log" "'$SPEC2PR_HOME'" "SPEC2PR_HOME with spaces is quoted"
  assert_contains "$log" "'$SPEC2PR_WORKTREES'" "SPEC2PR_WORKTREES with spaces is quoted"
}

test_inner_runner_records_child_rc_in_exit_marker() {
  make_sandbox
  run_mctl add spec2pr "$SPEC"
  source_mctl

  local fake_runner run_dir inner inner_rc
  fake_runner="$SANDBOX/fake-spec2pr.sh"
  cat > "$fake_runner" <<'FAKE'
#!/usr/bin/env bash
exit 37
FAKE
  chmod +x "$fake_runner"

  SPEC2PR_SCRIPT="$fake_runner"
  run_dir="$RULEZ_CLAUDESET_HOME/mctl/repo-foo-bar"
  inner="$(build_inner_runner_command "$run_dir")"

  set +e
  bash -c "$inner" >/dev/null 2>&1
  inner_rc=$?

  assert_eq "37" "$inner_rc" "inner runner returns child rc"
  assert_file_exists "$run_dir/exit" "exit marker written by inner command"
  assert_eq "37" "$(meta_value "$run_dir/exit" rc)" "exit marker records child rc"
}

test_add_missing_tmux_or_script_fails_cleanly() {
  make_sandbox
  rm -f "$SANDBOX/bin/tmux"
  run_mctl_with_stubs_only add spec2pr "$SPEC"
  assert_eq "1" "$RC" "missing tmux exits 1"
  assert_contains "$OUT" "missing dependency: tmux" "missing tmux message"

  make_sandbox
  rm -f "$SANDBOX/bin/script"
  run_mctl_with_stubs_only add spec2pr "$SPEC"
  assert_eq "1" "$RC" "missing script exits 1"
  assert_contains "$OUT" "missing dependency: script" "missing script message"
}
