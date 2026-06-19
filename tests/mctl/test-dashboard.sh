#!/usr/bin/env bash

dashboard_fixture_run() {
  local dir="$RULEZ_CLAUDESET_HOME/mctl/repo-foo"
  mkdir -p "$dir"
  cat > "$dir/meta" <<EOF
kind=spec2pr
token=repo-foo
session=mctl-repo-foo
repo=$REPO
started=2026-06-19T00:00:00Z
spec2pr_home=$SPEC2PR_HOME
spec2pr_worktrees=$SPEC2PR_WORKTREES
target=$SPEC
EOF
  : > "$dir/brief.log"
}

test_dashboard_builds_quoted_brief_and_details_commands() {
  make_sandbox
  dashboard_fixture_run
  source_mctl

  local brief details
  brief="$(build_brief_command "$RULEZ_CLAUDESET_HOME/mctl/repo-foo")"
  details="$(build_details_command "$RULEZ_CLAUDESET_HOME/mctl/repo-foo")"

  assert_eq "tail -F '$(printf "%s" "$RULEZ_CLAUDESET_HOME/mctl/repo-foo/brief.log")'" "$brief" "brief command tails log"
  assert_contains "$details" "SPEC2PR_HOME='$SPEC2PR_HOME'" "details exports stored SPEC2PR_HOME"
  assert_contains "$details" "SPEC2PR_WORKTREES='$SPEC2PR_WORKTREES'" "details exports stored SPEC2PR_WORKTREES"
  assert_contains "$details" "bash '$REPO_ROOT/scripts/spec2pr-watch.sh' 'repo-foo'" "details invokes watcher with token"
}

test_dashboard_empty_state_command_mentions_add() {
  make_sandbox
  source_mctl

  assert_eq "printf '%s\n' 'no runs - mctl add spec2pr <spec>'" "$(build_empty_command)" "empty command"
}

test_dashboard_fzf_command_reloads_every_two_seconds() {
  make_sandbox
  source_mctl

  local cmd
  cmd="$(build_fzf_command)"

  assert_contains "$cmd" "ctrl-r:reload" "fzf has reload binding"
  assert_contains "$cmd" "sleep 2" "fzf refresh driver sleeps two seconds"
  assert_contains "$cmd" "send-keys" "refresh driver asks tmux to trigger reload"
  assert_contains "$cmd" "--track" "fzf tracks the selected run across reloads"
  assert_contains "$cmd" "--id-nth 1" "fzf tracks by stable run name, not the changing state row"
}
