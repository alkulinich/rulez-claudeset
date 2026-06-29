#!/usr/bin/env bash

test_mctl_sanitize_matches_spec2pr_family() {
  make_sandbox
  source_mctl

  assert_eq "foo-bar" "$(sanitize " Foo!!Bar ")" "sanitize replaces invalid runs and trims"
  assert_eq "foo-bar" "$(sanitize "Foo - Bar")" "sanitize collapses punctuation dashes"
  assert_eq "foo-bar" "$(sanitize "Foo--Bar")" "sanitize collapses repeated dashes"
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

test_add_spec2pr_collapses_spec_slug_dashes_for_registry_token() {
  make_sandbox
  local spaced_spec="$REPO/docs/superpowers/specs/Foo - Bar.md"
  printf '# Foo - Bar\n' > "$spaced_spec"

  run_mctl add spec2pr "$spaced_spec"

  local run_dir="$RULEZ_CLAUDESET_HOME/mctl/repo-foo-bar"
  assert_eq "0" "$RC" "add spec2pr with spaced punctuation exits 0"
  assert_contains "$OUT" "repo-foo-bar" "add prints collapsed run name"
  assert_file_exists "$run_dir/meta" "collapsed slug meta file created"
  assert_eq "repo-foo-bar" "$(meta_value "$run_dir/meta" token)" "meta token uses collapsed slug"
  assert_eq "mctl-repo-foo-bar" "$(meta_value "$run_dir/meta" session)" "session uses collapsed slug"
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

test_add_review_pr_with_reviewer_persists_and_forwards_flag() {
  make_sandbox
  run_mctl_in_dir "$REPO" add review-pr 7 --reviewer codex

  local run_dir="$RULEZ_CLAUDESET_HOME/mctl/repo-pr-7"
  local log
  log="$(cat "$SANDBOX/tmux.log")"

  assert_eq "0" "$RC" "add review-pr with reviewer exits 0"
  assert_file_exists "$run_dir/meta" "review-pr reviewer meta file created"
  assert_eq "codex" "$(meta_value "$run_dir/meta" reviewer)" "reviewer persisted in meta"
  assert_contains "$log" "$REPO_ROOT/scripts/review-pr.sh" "runner uses review-pr script"
  assert_contains "$log" "--reviewer" "runner forwards reviewer flag"
  assert_contains "$log" "'codex'" "runner forwards reviewer value"
  assert_contains "$log" "'7'" "runner forwards PR number"
}

test_add_spec2pr_with_fast_persists_and_forwards_flag() {
  make_sandbox
  run_mctl add --fast spec2pr "$SPEC"

  local run_dir="$RULEZ_CLAUDESET_HOME/mctl/repo-foo-bar"
  local log
  log="$(cat "$SANDBOX/tmux.log")"

  assert_eq "0" "$RC" "add --fast spec2pr exits 0"
  assert_eq "1" "$(meta_value "$run_dir/meta" fast)" "fast persisted in meta"
  assert_contains "$log" "$REPO_ROOT/scripts/spec2pr.sh" "runner uses spec2pr script"
  assert_contains "$log" "--fast" "runner forwards fast flag"
  assert_contains "$log" "$SPEC" "runner forwards spec path"
}

test_add_spec2pr_forwards_size_override_flags() {
  make_sandbox
  run_mctl add spec2pr --ignore-plan-limit --ignore-pr-limit "$SPEC"

  local run_dir="$RULEZ_CLAUDESET_HOME/mctl/repo-foo-bar"
  local log
  log="$(cat "$SANDBOX/tmux.log")"

  assert_eq "0" "$RC" "add spec2pr override flags exits 0"
  assert_eq "--ignore-plan-limit --ignore-pr-limit" "$(meta_value "$run_dir/meta" override_flags)" "override flags persisted"
  assert_contains "$log" "$REPO_ROOT/scripts/spec2pr.sh" "runner uses spec2pr script"
  assert_contains "$log" "--ignore-plan-limit" "runner forwards plan override"
  assert_contains "$log" "--ignore-pr-limit" "runner forwards pr override"
  assert_contains "$log" "$SPEC" "runner forwards spec path"
}

test_add_spec2pr_accepts_fast_after_target() {
  make_sandbox
  run_mctl add spec2pr "$SPEC" --fast

  local run_dir="$RULEZ_CLAUDESET_HOME/mctl/repo-foo-bar"
  local log
  log="$(cat "$SANDBOX/tmux.log")"

  assert_eq "0" "$RC" "add spec2pr accepts --fast after target"
  assert_eq "1" "$(meta_value "$run_dir/meta" fast)" "suffix fast persisted in meta"
  assert_contains "$log" "--fast" "suffix fast forwards fast flag"
}

test_add_review_pr_forwards_ignore_pr_limit() {
  make_sandbox
  run_mctl_in_dir "$REPO" add review-pr --ignore-pr-limit 7 --reviewer codex

  local run_dir="$RULEZ_CLAUDESET_HOME/mctl/repo-pr-7"
  local log
  log="$(cat "$SANDBOX/tmux.log")"

  assert_eq "0" "$RC" "add review-pr ignore-pr-limit exits 0"
  assert_eq "--ignore-pr-limit" "$(meta_value "$run_dir/meta" override_flags)" "review-pr override flag persisted"
  assert_contains "$log" "$REPO_ROOT/scripts/review-pr.sh" "runner uses review-pr script"
  assert_contains "$log" "--ignore-pr-limit" "runner forwards review-pr override"
  assert_contains "$log" "--reviewer" "runner still forwards reviewer flag"
  assert_contains "$log" "'codex'" "runner forwards reviewer value"
  assert_contains "$log" "'7'" "runner forwards PR number"
}

test_add_review_pr_with_fast_and_reviewer_persists_and_forwards_flags() {
  make_sandbox
  run_mctl_in_dir "$REPO" add --fast review-pr 7 --reviewer codex

  local run_dir="$RULEZ_CLAUDESET_HOME/mctl/repo-pr-7"
  local log
  log="$(cat "$SANDBOX/tmux.log")"

  assert_eq "0" "$RC" "add --fast review-pr with reviewer exits 0"
  assert_eq "1" "$(meta_value "$run_dir/meta" fast)" "fast persisted in review-pr meta"
  assert_eq "codex" "$(meta_value "$run_dir/meta" reviewer)" "reviewer still persisted"
  assert_contains "$log" "$REPO_ROOT/scripts/review-pr.sh" "runner uses review-pr script"
  assert_contains "$log" "--fast" "runner forwards fast flag"
  assert_contains "$log" "--reviewer" "runner still forwards reviewer flag"
  assert_contains "$log" "'codex'" "runner forwards reviewer value"
  assert_contains "$log" "'7'" "runner forwards PR number"
}

test_add_review_pr_default_reviewer_does_not_write_meta_line() {
  make_sandbox
  run_mctl_in_dir "$REPO" add review-pr 7

  local run_dir="$RULEZ_CLAUDESET_HOME/mctl/repo-pr-7"
  local log
  log="$(cat "$SANDBOX/tmux.log")"

  assert_eq "0" "$RC" "add review-pr default reviewer exits 0"
  assert_eq "" "$(meta_value "$run_dir/meta" reviewer)" "default reviewer omitted from meta"
  assert_not_contains "$log" "--reviewer" "default review-pr runner does not forward reviewer flag"
}

test_add_review_pr_explicit_claude_reviewer_uses_default_behavior() {
  make_sandbox
  run_mctl_in_dir "$REPO" add review-pr 7 --reviewer claude

  local run_dir="$RULEZ_CLAUDESET_HOME/mctl/repo-pr-7"
  local log
  log="$(cat "$SANDBOX/tmux.log")"

  assert_eq "0" "$RC" "add review-pr explicit claude reviewer exits 0"
  assert_eq "" "$(meta_value "$run_dir/meta" reviewer)" "explicit claude reviewer omitted from meta"
  assert_not_contains "$log" "--reviewer" "explicit claude reviewer is not forwarded"
}

test_add_default_runs_do_not_write_or_forward_fast() {
  make_sandbox
  run_mctl add spec2pr "$SPEC"

  local run_dir="$RULEZ_CLAUDESET_HOME/mctl/repo-foo-bar"
  local log
  log="$(cat "$SANDBOX/tmux.log")"

  assert_eq "0" "$RC" "default add spec2pr exits 0"
  assert_eq "" "$(meta_value "$run_dir/meta" fast)" "default fast omitted from meta"
  assert_not_contains "$log" "--fast" "default runner does not forward fast"
}

test_add_review_pr_rejects_ignore_plan_limit() {
  make_sandbox
  run_mctl_in_dir "$REPO" add review-pr --ignore-plan-limit 7

  assert_eq "1" "$RC" "review-pr rejects ignore-plan-limit"
  assert_contains "$OUT" "--ignore-plan-limit is only supported for spec2pr" "review-pr plan override rejection message"
}

test_add_rejects_reviewer_for_spec2pr_and_invalid_review_pr_value() {
  make_sandbox

  run_mctl add spec2pr "$SPEC" --reviewer codex
  assert_eq "1" "$RC" "spec2pr reviewer flag exits 1"
  assert_contains "$OUT" "--reviewer is only supported for review-pr" "spec2pr reviewer rejection message"

  run_mctl_in_dir "$REPO" add review-pr 7 --reviewer gpt
  assert_eq "1" "$RC" "invalid review-pr reviewer exits 1"
  assert_contains "$OUT" "usage: mctl add [--fast] spec2pr [--ignore-plan-limit] [--ignore-pr-limit] <spec.md> | mctl add [--fast] review-pr [--ignore-pr-limit] <pr#> [--reviewer <claude|codex>]" "invalid reviewer prints add usage"
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

test_add_refuses_existing_tmux_session() {
  make_sandbox
  printf 'mctl-repo-foo-bar\n' > "$SANDBOX/tmux-sessions"

  run_mctl add spec2pr "$SPEC"

  assert_eq "1" "$RC" "existing tmux session exits 1"
  assert_contains "$OUT" "session already exists: mctl-repo-foo-bar" "existing tmux session refusal"
  assert_file_absent "$RULEZ_CLAUDESET_HOME/mctl/repo-foo-bar" "registry dir is not created after session refusal"
}

test_add_refuses_existing_live_or_lost_registry_dir_without_removing_it() {
  make_sandbox
  local run_dir="$RULEZ_CLAUDESET_HOME/mctl/repo-foo-bar"
  mkdir -p "$run_dir"
  : > "$run_dir/brief.log"

  run_mctl add spec2pr "$SPEC"

  assert_eq "1" "$RC" "existing live or lost registry exits 1"
  assert_contains "$OUT" "live or lost run exists" "live or lost registry refusal"
  assert_file_exists "$run_dir/brief.log" "existing live or lost registry remains"
}

test_runner_helpers_work_under_nounset_when_sourced() {
  make_sandbox
  run_mctl add spec2pr "$SPEC"
  source_mctl

  local helper_run_dir inner helper_rc
  helper_run_dir="$RULEZ_CLAUDESET_HOME/mctl/repo-foo-bar"
  unset run_dir meta

  set +e
  (
    set -u
    build_inner_runner_command "$helper_run_dir" >/dev/null
    launch_run "$helper_run_dir" >/dev/null
  )
  helper_rc=$?
  set -e

  assert_eq "0" "$helper_rc" "runner helpers tolerate nounset when sourced"
  inner="$(build_inner_runner_command "$helper_run_dir")"
  assert_contains "$inner" "$helper_run_dir/exit" "inner runner still uses requested run dir"
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

test_build_script_command_wraps_harmless_inner_command() {
  make_sandbox
  source_mctl

  local inner brief linux_cmd bsd_cmd
  inner="printf ok"
  brief="$SANDBOX/brief log"

  linux_cmd="$(build_script_command "$inner" "$brief")"
  assert_contains "$linux_cmd" "script --flush" "linux script wrapper flushes output"
  assert_contains "$linux_cmd" "-c 'printf ok'" "linux script wrapper passes inner command"
  assert_contains "$linux_cmd" "'$brief'" "linux script wrapper quotes brief log"

  uname() { printf 'Darwin\n'; }
  bsd_cmd="$(build_script_command "$inner" "$brief")"
  unset -f uname

  assert_contains "$bsd_cmd" "script -F -q" "bsd script wrapper flushes output quietly"
  assert_contains "$bsd_cmd" "/bin/sh -c 'printf ok'" "bsd script wrapper passes inner command through shell"
  assert_contains "$bsd_cmd" "'$brief'" "bsd script wrapper quotes brief log"
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

test_symlinked_mctl_resolves_companion_scripts_from_real_path() {
  make_sandbox
  mkdir -p "$SANDBOX/local-bin"
  ln -s "$MCTL" "$SANDBOX/local-bin/mctl"

  MCTL_TESTING=1 source "$SANDBOX/local-bin/mctl"
  assert_eq "$REPO_ROOT/scripts/spec2pr.sh" "$SPEC2PR_SCRIPT" "symlinked mctl resolves spec2pr path"
  assert_eq "$REPO_ROOT/scripts/review-pr.sh" "$REVIEW_PR_SCRIPT" "symlinked mctl resolves review-pr path"
  assert_eq "$REPO_ROOT/scripts/spec2pr-watch.sh" "$WATCH_SCRIPT" "symlinked mctl resolves watch path"

  set +e
  OUT="$(cd "$SANDBOX" && PATH="$SANDBOX/local-bin:$PATH" "${BASH:-bash}" "$SANDBOX/local-bin/mctl" add spec2pr "$SPEC" 2>&1)"
  RC=$?

  local log
  log="$(cat "$SANDBOX/tmux.log")"
  assert_eq "0" "$RC" "symlinked mctl add exits 0"
  assert_contains "$log" "$REPO_ROOT/scripts/spec2pr.sh" "symlinked mctl uses real spec2pr path"
}
