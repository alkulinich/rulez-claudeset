#!/usr/bin/env bash

make_run_dir() {
  local name="$1" kind="$2" started="$3"
  local dir="$RULEZ_CLAUDESET_HOME/mctl/$name"
  mkdir -p "$dir"
  cat > "$dir/meta" <<EOF
kind=$kind
token=$name
session=mctl-$name
repo=$REPO
started=$started
spec2pr_home=$SPEC2PR_HOME
spec2pr_worktrees=$SPEC2PR_WORKTREES
target=target
EOF
  : > "$dir/brief.log"
}

test_ls_lists_running_done_and_lost_runs() {
  make_sandbox
  make_run_dir "repo-a" "spec2pr" "2026-06-19T00:00:01Z"
  make_run_dir "repo-b" "review-pr" "2026-06-19T00:00:02Z"
  make_run_dir "repo-c" "spec2pr" "2026-06-19T00:00:03Z"
  printf 'mctl-repo-a\n' > "$SANDBOX/tmux-sessions"
  printf 'rc=0\nfinished=2026-06-19T00:05:00Z\n' > "$RULEZ_CLAUDESET_HOME/mctl/repo-b/exit"

  run_mctl ls

  assert_eq "0" "$RC" "ls exits 0"
  assert_contains "$OUT" "repo-a spec2pr running 2026-06-19T00:00:01Z" "running row"
  assert_contains "$OUT" "repo-b review-pr done 2026-06-19T00:00:02Z" "done row"
  assert_contains "$OUT" "repo-c spec2pr lost 2026-06-19T00:00:03Z" "lost row"
}

test_ls_empty_registry_prints_nothing() {
  make_sandbox
  run_mctl ls

  assert_eq "0" "$RC" "empty ls exits 0"
  assert_eq "" "$OUT" "empty ls has no rows"
}
