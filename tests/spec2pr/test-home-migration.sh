#!/usr/bin/env bash
# Smoke tests for spec2pr home consolidation and setup migration.

SETUP="$REPO_ROOT/bin/setup"
RUNTIME="$REPO_ROOT/scripts/lib/spec2pr-runtime.sh"
WATCH="$REPO_ROOT/scripts/spec2pr-watch.sh"

source_setup_for_migration() {
  RULEZ_SETUP_TESTING=1 source "$SETUP" -- || true
  set +e
}

assert_symlink_target() {
  local path="$1" expected="$2" msg="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ -L "$path" ] && [ "$(readlink "$path")" = "$expected" ]; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    expected symlink: %s -> %s\n' "$msg" "$path" "$expected"
    if [ -e "$path" ] || [ -L "$path" ]; then
      printf '    actual: %s\n' "$(ls -ld "$path")"
    else
      printf '    actual: missing\n'
    fi
  fi
}

assert_path_absent() {
  local path="$1" msg="${2:-should not exist: $1}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n' "$msg"
    if [ -e "$path" ] || [ -L "$path" ]; then
      printf '    actual: %s\n' "$(ls -ld "$path")"
    fi
  fi
}

write_legacy_meta() {
  local legacy="$HOME/.spec2pr"
  mkdir -p "$legacy/project-toy-spec"
  printf 'metadata\n' > "$legacy/project-toy-spec/meta"
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

test_spec2pr_setup_migrates_legacy_home_and_leaves_symlink() {
  make_sandbox
  unset RULEZ_CLAUDESET_HOME
  write_legacy_meta
  source_setup_for_migration

  local output
  output="$(migrate_spec2pr_home 2>&1)"

  assert_file_exists "$HOME/.rulez-claudeset/spec2pr/project-toy-spec/meta" "legacy metadata moved to consolidated home"
  assert_symlink_target "$HOME/.spec2pr" "$HOME/.rulez-claudeset/spec2pr" "legacy path points to migrated state"
  assert_contains "$output" "migrated ~/.spec2pr to $HOME/.rulez-claudeset/spec2pr (left a symlink)" "same-filesystem migration reports success"
}

test_spec2pr_setup_migration_is_idempotent_after_move() {
  make_sandbox
  unset RULEZ_CLAUDESET_HOME
  write_legacy_meta
  source_setup_for_migration
  migrate_spec2pr_home >/dev/null 2>&1

  local output
  output="$(migrate_spec2pr_home 2>&1)"

  assert_eq "" "$output" "second same-filesystem migration emits nothing"
  assert_file_exists "$HOME/.rulez-claudeset/spec2pr/project-toy-spec/meta" "migrated metadata remains in place"
  assert_symlink_target "$HOME/.spec2pr" "$HOME/.rulez-claudeset/spec2pr" "legacy symlink remains unchanged"
}

test_spec2pr_setup_replaces_empty_target_directory() {
  make_sandbox
  unset RULEZ_CLAUDESET_HOME
  write_legacy_meta
  mkdir -p "$HOME/.rulez-claudeset/spec2pr"
  source_setup_for_migration

  local output
  output="$(migrate_spec2pr_home 2>&1)"

  assert_file_exists "$HOME/.rulez-claudeset/spec2pr/project-toy-spec/meta" "legacy metadata moved into formerly empty target"
  assert_symlink_target "$HOME/.spec2pr" "$HOME/.rulez-claudeset/spec2pr" "legacy path points at target after empty-dir replacement"
  assert_contains "$output" "migrated ~/.spec2pr to $HOME/.rulez-claudeset/spec2pr (left a symlink)" "empty target replacement reports migration"
}

test_spec2pr_setup_uses_custom_rulez_home_for_target() {
  make_sandbox
  write_legacy_meta
  export RULEZ_CLAUDESET_HOME="$SANDBOX/custom-rulez-home"
  source_setup_for_migration

  local output
  output="$(migrate_spec2pr_home 2>&1)"

  assert_file_exists "$RULEZ_CLAUDESET_HOME/spec2pr/project-toy-spec/meta" "custom rulez home receives migrated metadata"
  assert_symlink_target "$HOME/.spec2pr" "$RULEZ_CLAUDESET_HOME/spec2pr" "legacy path points at custom target"
  assert_contains "$output" "migrated ~/.spec2pr to $RULEZ_CLAUDESET_HOME/spec2pr (left a symlink)" "custom rulez home migration reports success"
}

test_spec2pr_setup_refuses_non_empty_target() {
  make_sandbox
  unset RULEZ_CLAUDESET_HOME
  write_legacy_meta
  mkdir -p "$HOME/.rulez-claudeset/spec2pr/existing"
  printf 'existing\n' > "$HOME/.rulez-claudeset/spec2pr/existing/meta"
  source_setup_for_migration

  local output
  output="$(migrate_spec2pr_home 2>&1)"

  assert_file_exists "$HOME/.spec2pr/project-toy-spec/meta" "legacy metadata left in place when target has data"
  assert_file_exists "$HOME/.rulez-claudeset/spec2pr/existing/meta" "existing target data left in place"
  assert_contains "$output" "warning: both ~/.spec2pr and $HOME/.rulez-claudeset/spec2pr exist; leaving them unchanged" "non-empty target warning emitted"
}

test_spec2pr_setup_links_new_default_when_legacy_lock_exists() {
  make_sandbox
  unset RULEZ_CLAUDESET_HOME
  write_legacy_meta
  mkdir -p "$HOME/.spec2pr/project-toy-spec.lock"
  source_setup_for_migration

  local output
  output="$(migrate_spec2pr_home 2>&1)"

  assert_file_exists "$HOME/.spec2pr/project-toy-spec/meta" "active legacy metadata stays at legacy path"
  assert_symlink_target "$HOME/.rulez-claudeset/spec2pr" "$HOME/.spec2pr" "new default links back to active legacy state"
  assert_contains "$output" "linked $HOME/.rulez-claudeset/spec2pr to existing ~/.spec2pr (active run; not moved)" "active run link message emitted"
}

test_spec2pr_setup_replaces_empty_target_with_active_run_symlink() {
  make_sandbox
  unset RULEZ_CLAUDESET_HOME
  write_legacy_meta
  mkdir -p "$HOME/.spec2pr/project-toy-spec.lock" "$HOME/.rulez-claudeset/spec2pr"
  source_setup_for_migration

  local output
  output="$(migrate_spec2pr_home 2>&1)"

  assert_file_exists "$HOME/.spec2pr/project-toy-spec/meta" "active legacy metadata stays at legacy path with empty target"
  assert_symlink_target "$HOME/.rulez-claudeset/spec2pr" "$HOME/.spec2pr" "empty target becomes symlink to active legacy state"
  assert_contains "$output" "linked $HOME/.rulez-claudeset/spec2pr to existing ~/.spec2pr (active run; not moved)" "empty active target link message emitted"
}

test_spec2pr_setup_completes_migration_after_active_lock_clears() {
  make_sandbox
  unset RULEZ_CLAUDESET_HOME
  write_legacy_meta
  mkdir -p "$HOME/.spec2pr/project-toy-spec.lock"
  source_setup_for_migration

  migrate_spec2pr_home >/dev/null 2>&1
  assert_symlink_target "$HOME/.rulez-claudeset/spec2pr" "$HOME/.spec2pr" "active run fallback links target to legacy"

  rmdir "$HOME/.spec2pr/project-toy-spec.lock"

  local output
  output="$(migrate_spec2pr_home 2>&1)"

  assert_file_exists "$HOME/.rulez-claudeset/spec2pr/project-toy-spec/meta" "legacy metadata migrates after active lock clears"
  assert_symlink_target "$HOME/.spec2pr" "$HOME/.rulez-claudeset/spec2pr" "legacy path points at target after active lock clears"
  assert_contains "$output" "migrated ~/.spec2pr to $HOME/.rulez-claudeset/spec2pr (left a symlink)" "post-active migration reports success"
}

test_spec2pr_setup_cross_filesystem_links_new_default_to_legacy() {
  make_sandbox
  unset RULEZ_CLAUDESET_HOME
  write_legacy_meta
  source_setup_for_migration
  spec2pr_home_same_filesystem() { return 1; }

  local output
  output="$(migrate_spec2pr_home 2>&1)"

  assert_file_exists "$HOME/.spec2pr/project-toy-spec/meta" "cross-filesystem legacy metadata stays at legacy path"
  assert_symlink_target "$HOME/.rulez-claudeset/spec2pr" "$HOME/.spec2pr" "cross-filesystem target links to legacy state"
  assert_contains "$output" "linked $HOME/.rulez-claudeset/spec2pr to existing ~/.spec2pr (cross-filesystem; not moved)" "cross-filesystem link message emitted"
}

test_spec2pr_setup_cross_filesystem_link_is_idempotent() {
  make_sandbox
  unset RULEZ_CLAUDESET_HOME
  write_legacy_meta
  source_setup_for_migration
  spec2pr_home_same_filesystem() { return 1; }
  migrate_spec2pr_home >/dev/null 2>&1

  local output
  output="$(migrate_spec2pr_home 2>&1)"

  assert_eq "" "$output" "second cross-filesystem run emits nothing"
  assert_symlink_target "$HOME/.rulez-claudeset/spec2pr" "$HOME/.spec2pr" "cross-filesystem target symlink remains unchanged"
}

test_spec2pr_setup_mv_failure_returns_success_with_warning() {
  make_sandbox
  unset RULEZ_CLAUDESET_HOME
  write_legacy_meta
  source_setup_for_migration

  local output rc
  output="$(
    set -e
    mv() { return 1; }
    migrate_spec2pr_home 2>&1
  )"
  rc=$?

  assert_eq "0" "$rc" "migration helper returns success when mv fails"
  assert_file_exists "$HOME/.spec2pr/project-toy-spec/meta" "legacy metadata remains after mv failure"
  assert_contains "$output" "warning: cannot migrate ~/.spec2pr to $HOME/.rulez-claudeset/spec2pr; leaving it unchanged" "mv failure warning emitted"
}

test_spec2pr_setup_testing_mode_does_not_run_installer_body() {
  make_sandbox
  RULEZ_SETUP_TESTING=1 source "$SETUP" -- || true
  set +e

  assert_path_absent "$HOME/.claude/commands/rulez" "testing mode does not symlink Claude commands"
}
