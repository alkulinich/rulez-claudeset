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
  assert_contains "$cmd" "$RULEZ_CLAUDESET_HOME/mctl/dashboard-panes" "refresh driver reads persisted pane registry"
  assert_not_contains "$cmd" "mctl-dash:0.0" "refresh driver does not hardcode tmux pane index"
  assert_contains "$cmd" "--track" "fzf tracks the selected run across reloads"
  assert_contains "$cmd" "--id-nth 1" "fzf tracks by stable run name, not the changing state row"
}

test_dashboard_fzf_subprocesses_preserve_registry_home() {
  make_sandbox
  source_mctl

  local cmd export_prefix
  cmd="$(build_fzf_command)"
  export_prefix="RULEZ_CLAUDESET_HOME='$(printf "%s" "$RULEZ_CLAUDESET_HOME")'"

  assert_contains "$cmd" "$export_prefix bash '$REPO_ROOT/scripts/mctl.sh' ls" "fzf input command preserves registry home"
  assert_contains "$cmd" "reload(RULEZ_CLAUDESET_HOME=" "fzf reload includes registry home assignment"
  assert_contains "$cmd" "execute-silent(RULEZ_CLAUDESET_HOME=" "fzf focus retarget includes registry home assignment"
  assert_contains "$cmd" "$RULEZ_CLAUDESET_HOME" "fzf subprocess commands include active registry home path"
  assert_contains "$cmd" "__retarget {1}" "fzf focus still retargets the selected run"
}

test_dashboard_attaches_existing_session() {
  make_sandbox
  printf 'mctl-dash\n' > "$SANDBOX/tmux-sessions"

  run_mctl

  local log
  log="$(cat "$SANDBOX/tmux.log")"
  assert_eq "0" "$RC" "dashboard attach exits 0"
  assert_contains "$log" "tmux [attach-session] [-t] [mctl-dash]" "dashboard attaches existing session"
  assert_not_contains "$log" "tmux [new-session] [-d] [-s] [mctl-dash]" "dashboard does not create duplicate session"
}

test_dashboard_creates_three_pane_layout() {
  make_sandbox
  dashboard_fixture_run

  run_mctl

  local log
  log="$(cat "$SANDBOX/tmux.log")"
  assert_eq "0" "$RC" "dashboard exits 0"
  assert_contains "$log" "tmux [new-session] [-d] [-s] [mctl-dash] [-P] [-F] [#{pane_id}]" "dashboard captures list pane id"
  assert_contains "$log" "tmux [split-window] [-h] [-t] [%1] [-P] [-F] [#{pane_id}]" "dashboard creates right column from captured list pane"
  assert_contains "$log" "tmux [split-window] [-v] [-t] [%2] [-P] [-F] [#{pane_id}]" "dashboard splits captured brief pane"
  assert_file_exists "$RULEZ_CLAUDESET_HOME/mctl/dashboard-panes" "dashboard persists pane registry"
  assert_contains "$log" "tmux [attach-session] [-t] [mctl-dash]" "dashboard attaches after layout"
  assert_not_contains "$log" "mctl-dash:0.0" "dashboard does not hardcode list pane index"
  assert_not_contains "$log" "mctl-dash:0.1" "dashboard does not hardcode brief pane index"
}

test_dashboard_empty_registry_shows_message_in_task_list() {
  make_sandbox

  run_mctl

  local log
  log="$(cat "$SANDBOX/tmux.log")"
  assert_eq "0" "$RC" "empty dashboard exits 0"
  assert_contains "$log" "no runs - mctl add spec2pr <spec>" "empty dashboard shows message in task list"
}

test_dashboard_ignores_stale_run_dir_without_meta() {
  make_sandbox
  mkdir -p "$RULEZ_CLAUDESET_HOME/mctl/stale-empty"

  run_mctl

  local log
  log="$(cat "$SANDBOX/tmux.log")"
  assert_eq "0" "$RC" "dashboard exits 0 with stale empty run dir"
  assert_contains "$log" "no runs - mctl add spec2pr <spec>" "stale run dir falls back to empty state"
  assert_not_contains "$OUT" "No such file" "dashboard does not try to read missing meta"
}

test_dashboard_retarget_respawns_brief_and_details() {
  make_sandbox
  dashboard_fixture_run
  cat > "$RULEZ_CLAUDESET_HOME/mctl/dashboard-panes" <<EOF
list=%1
brief=%2
details=%3
EOF

  run_mctl __retarget repo-foo

  local log
  log="$(cat "$SANDBOX/tmux.log")"
  assert_eq "0" "$RC" "retarget exits 0"
  assert_contains "$log" "tmux [respawn-pane] [-k] [-t] [%2]" "retarget respawns brief pane by persisted pane id"
  assert_contains "$log" "tail -F" "retarget brief tails log"
  assert_contains "$log" "tmux [respawn-pane] [-k] [-t] [%3]" "retarget respawns details pane by persisted pane id"
  assert_contains "$log" "spec2pr-watch.sh" "retarget details invokes watcher"
  assert_not_contains "$log" "mctl-dash:0.1" "retarget does not hardcode brief pane index"
  assert_not_contains "$log" "mctl-dash:0.2" "retarget does not hardcode details pane index"
}

test_dashboard_missing_fzf_fails_before_creating_session() {
  make_sandbox
  rm -f "$SANDBOX/bin/fzf"

  run_mctl_with_stubs_only

  local log
  log="$(cat "$SANDBOX/tmux.log")"
  assert_eq "1" "$RC" "missing fzf exits 1"
  assert_contains "$OUT" "missing dependency: fzf" "missing fzf message"
  assert_not_contains "$log" "tmux [new-session]" "dashboard does not create partial session"
}
