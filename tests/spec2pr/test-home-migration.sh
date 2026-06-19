#!/usr/bin/env bash
# Smoke tests for spec2pr home consolidation and setup migration.

SETUP="$REPO_ROOT/bin/setup"
RUNTIME="$REPO_ROOT/scripts/lib/spec2pr-runtime.sh"
WATCH="$REPO_ROOT/scripts/spec2pr-watch.sh"

source_setup_for_migration() {
  RULEZ_SETUP_TESTING=1 source "$SETUP"
  set +e
}

test_spec2pr_runtime_default_home_uses_rulez_home() {
  make_sandbox
  unset SPEC2PR_HOME
  export RULEZ_CLAUDESET_HOME="$SANDBOX/data-home"

  local actual
  actual="$(
    source "$RUNTIME"
    printf '%s\n' "$SPEC2PR_HOME"
    FINISHED=1
  )"

  assert_eq "$RULEZ_CLAUDESET_HOME/spec2pr" "$actual" "runtime default SPEC2PR_HOME uses RULEZ_CLAUDESET_HOME"
}

test_spec2pr_runtime_preserves_explicit_home() {
  make_sandbox
  export SPEC2PR_HOME="$SANDBOX/explicit-spec2pr"
  export RULEZ_CLAUDESET_HOME="$SANDBOX/data-home"

  local actual
  actual="$(
    source "$RUNTIME"
    printf '%s\n' "$SPEC2PR_HOME"
    FINISHED=1
  )"

  assert_eq "$SANDBOX/explicit-spec2pr" "$actual" "runtime preserves explicit SPEC2PR_HOME"
}

test_spec2pr_watcher_default_home_uses_rulez_home() {
  make_sandbox
  unset SPEC2PR_HOME
  export RULEZ_CLAUDESET_HOME="$SANDBOX/data-home"

  local actual
  actual="$(
    SPEC2PR_WATCH_TESTING=1 source "$WATCH"
    printf '%s\n' "$SPEC2PR_HOME"
  )"

  assert_eq "$RULEZ_CLAUDESET_HOME/spec2pr" "$actual" "watcher default SPEC2PR_HOME uses RULEZ_CLAUDESET_HOME"
}

test_spec2pr_watcher_preserves_explicit_home() {
  make_sandbox
  export SPEC2PR_HOME="$SANDBOX/explicit-spec2pr"
  export RULEZ_CLAUDESET_HOME="$SANDBOX/data-home"

  local actual
  actual="$(
    SPEC2PR_WATCH_TESTING=1 source "$WATCH"
    printf '%s\n' "$SPEC2PR_HOME"
  )"

  assert_eq "$SANDBOX/explicit-spec2pr" "$actual" "watcher preserves explicit SPEC2PR_HOME"
}
