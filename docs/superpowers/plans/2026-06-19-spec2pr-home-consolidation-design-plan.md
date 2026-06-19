# spec2pr Home Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the default `spec2pr` state directory from `~/.spec2pr` to `~/.rulez-claudeset/spec2pr` while preserving the `SPEC2PR_HOME` override and safely migrating existing default state during setup.

**Architecture:** Keep runtime behavior unchanged by changing only default path resolution in the shared runtime and standalone watcher. Add a sourceable, best-effort migration function to `bin/setup` that can be exercised directly from shell tests and always returns success after warnings.

**Tech Stack:** Bash, POSIX filesystem operations, existing `tests/spec2pr` shell harness, `jq`, git.

---

## File Structure

- Modify `scripts/lib/spec2pr-runtime.sh` - shared default resolution for `spec2pr.sh` and `review-pr.sh`.
- Modify `scripts/spec2pr-watch.sh` - standalone watcher default resolution kept in lockstep with runtime.
- Modify `bin/setup` - add `spec2pr_home_same_filesystem`, `spec2pr_target_symlink_points_to_legacy`, `spec2pr_dir_is_empty`, `spec2pr_link_target_to_legacy`, and `migrate_spec2pr_home`.
- Create `tests/spec2pr/test-home-migration.sh` - direct tests for default resolution and the setup migration helper.
- Modify `README.md` - update user-facing default state path from `~/.spec2pr` to `~/.rulez-claudeset/spec2pr`.
- Modify `commands/rulez/spec2pr.md` - update status/log path examples to use the new default home.
- Modify `UPGRADE.md` - add a `v1.6.2` section explaining the automatic migration and symlink caveat.
- Modify `VERSION` - bump from `1.6.1` to `1.6.2`.

## Task 1: Default Resolution Tests

**Files:**
- Create: `tests/spec2pr/test-home-migration.sh`
- Read: `tests/spec2pr/helpers.sh`
- Read: `scripts/lib/spec2pr-runtime.sh`
- Read: `scripts/spec2pr-watch.sh`

- [ ] **Step 1: Write failing default-resolution tests**

Create `tests/spec2pr/test-home-migration.sh` with this initial content:

```bash
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
```

- [ ] **Step 2: Run the new tests and verify they fail**

Run:

```bash
tests/spec2pr/run-tests.sh
```

Expected: the four new default-resolution assertions fail because both scripts still default `SPEC2PR_HOME` to `$HOME/.spec2pr`.

- [ ] **Step 3: Commit the failing tests**

```bash
git add tests/spec2pr/test-home-migration.sh
git commit -m "test: cover spec2pr consolidated home defaults"
```

## Task 2: Runtime Default Resolution

**Files:**
- Modify: `scripts/lib/spec2pr-runtime.sh:15-16`
- Modify: `scripts/spec2pr-watch.sh:5-6`
- Test: `tests/spec2pr/test-home-migration.sh`

- [ ] **Step 1: Update the shared runtime defaults**

In `scripts/lib/spec2pr-runtime.sh`, replace:

```bash
SPEC2PR_HOME="${SPEC2PR_HOME:-$HOME/.spec2pr}"
SPEC2PR_WORKTREES="${SPEC2PR_WORKTREES:-$HOME/.worktrees}"
```

with:

```bash
RULEZ_CLAUDESET_HOME="${RULEZ_CLAUDESET_HOME:-$HOME/.rulez-claudeset}"
SPEC2PR_HOME="${SPEC2PR_HOME:-$RULEZ_CLAUDESET_HOME/spec2pr}"
SPEC2PR_WORKTREES="${SPEC2PR_WORKTREES:-$HOME/.worktrees}"
```

- [ ] **Step 2: Update the watcher defaults in lockstep**

In `scripts/spec2pr-watch.sh`, replace:

```bash
SPEC2PR_HOME="${SPEC2PR_HOME:-$HOME/.spec2pr}"
SPEC2PR_WORKTREES="${SPEC2PR_WORKTREES:-$HOME/.worktrees}"
```

with:

```bash
RULEZ_CLAUDESET_HOME="${RULEZ_CLAUDESET_HOME:-$HOME/.rulez-claudeset}"
SPEC2PR_HOME="${SPEC2PR_HOME:-$RULEZ_CLAUDESET_HOME/spec2pr}"
SPEC2PR_WORKTREES="${SPEC2PR_WORKTREES:-$HOME/.worktrees}"
```

- [ ] **Step 3: Run default-resolution tests**

Run:

```bash
tests/spec2pr/run-tests.sh
```

Expected: the four new default-resolution tests pass. Existing tests continue to pass because `tests/spec2pr/helpers.sh` exports `SPEC2PR_HOME`.

- [ ] **Step 4: Commit runtime default changes**

```bash
git add scripts/lib/spec2pr-runtime.sh scripts/spec2pr-watch.sh
git commit -m "feat: default spec2pr state under rulez home"
```

## Task 3: Migration Tests

**Files:**
- Modify: `tests/spec2pr/test-home-migration.sh`
- Read: `bin/setup`

- [ ] **Step 1: Add symlink assertion helpers to the test file**

Append these helper functions near the top of `tests/spec2pr/test-home-migration.sh`, after `source_setup_for_migration()`:

```bash
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

write_legacy_meta() {
  local legacy="$HOME/.spec2pr"
  mkdir -p "$legacy/project-toy-spec"
  printf 'metadata\n' > "$legacy/project-toy-spec/meta"
}
```

- [ ] **Step 2: Add same-filesystem migration tests**

Append these tests to `tests/spec2pr/test-home-migration.sh`:

```bash
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
```

- [ ] **Step 3: Add active-run and cross-filesystem tests**

Append these tests to `tests/spec2pr/test-home-migration.sh`:

```bash
test_spec2pr_setup_links_new_default_when_legacy_lock_exists() {
  make_sandbox
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
  write_legacy_meta
  mkdir -p "$HOME/.spec2pr/project-toy-spec.lock" "$HOME/.rulez-claudeset/spec2pr"
  source_setup_for_migration

  local output
  output="$(migrate_spec2pr_home 2>&1)"

  assert_file_exists "$HOME/.spec2pr/project-toy-spec/meta" "active legacy metadata stays at legacy path with empty target"
  assert_symlink_target "$HOME/.rulez-claudeset/spec2pr" "$HOME/.spec2pr" "empty target becomes symlink to active legacy state"
  assert_contains "$output" "linked $HOME/.rulez-claudeset/spec2pr to existing ~/.spec2pr (active run; not moved)" "empty active target link message emitted"
}

test_spec2pr_setup_cross_filesystem_links_new_default_to_legacy() {
  make_sandbox
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
  write_legacy_meta
  source_setup_for_migration
  spec2pr_home_same_filesystem() { return 1; }
  migrate_spec2pr_home >/dev/null 2>&1

  local output
  output="$(migrate_spec2pr_home 2>&1)"

  assert_eq "" "$output" "second cross-filesystem run emits nothing"
  assert_symlink_target "$HOME/.rulez-claudeset/spec2pr" "$HOME/.spec2pr" "cross-filesystem target symlink remains unchanged"
}
```

- [ ] **Step 4: Add guarded failure and setup testing-mode tests**

Append these tests to `tests/spec2pr/test-home-migration.sh`:

```bash
test_spec2pr_setup_mv_failure_returns_success_with_warning() {
  make_sandbox
  write_legacy_meta
  source_setup_for_migration

  local output rc
  output="$(
    set -e
    mv() { return 1; }
    migrate_spec2pr_home
  2>&1)"
  rc=$?

  assert_eq "0" "$rc" "migration helper returns success when mv fails"
  assert_file_exists "$HOME/.spec2pr/project-toy-spec/meta" "legacy metadata remains after mv failure"
  assert_contains "$output" "warning: cannot migrate ~/.spec2pr to $HOME/.rulez-claudeset/spec2pr; leaving it unchanged" "mv failure warning emitted"
}

test_spec2pr_setup_testing_mode_does_not_run_installer_body() {
  make_sandbox
  RULEZ_SETUP_TESTING=1 source "$SETUP"

  assert_file_absent "$HOME/.claude/commands/rulez" "testing mode does not symlink Claude commands"
}
```

- [ ] **Step 5: Run migration tests and verify they fail**

Run:

```bash
tests/spec2pr/run-tests.sh
```

Expected: migration tests fail because `bin/setup` does not yet support `RULEZ_SETUP_TESTING` and does not define `migrate_spec2pr_home`.

- [ ] **Step 6: Commit failing migration tests**

```bash
git add tests/spec2pr/test-home-migration.sh
git commit -m "test: cover spec2pr home migration"
```

## Task 4: Sourceable Setup Guard

**Files:**
- Modify: `bin/setup`
- Test: `tests/spec2pr/test-home-migration.sh`

- [ ] **Step 1: Wrap the installer body in a `main` function**

In `bin/setup`, keep the shebang and `set -e`, then replace the top-level body with a `main()` function. The top of the file should become:

```bash
#!/bin/bash
set -e

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_DIR="$HOME/.claude"
QUIET=false

[[ "${1:-}" == "-q" ]] && QUIET=true

log() { $QUIET || echo "$@"; }
warn() { echo "$@" >&2; }

ask_replace() {
  # In quiet mode (auto-update), always skip
  $QUIET && return 1
  local what="$1"
  printf "%s already configured. Replace? [y/N] " "$what"
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

main() {
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required (brew install jq)"
    exit 1
  fi
```

Move the existing setup body from the `jq` check through the final `log "Done! ..."` line inside `main()`.

- [ ] **Step 2: Add the testing-mode footer**

At the end of `bin/setup`, after the closing `}` for `main()`, add:

```bash
if [ "${RULEZ_SETUP_TESTING:-}" != "1" ]; then
  main "$@"
fi
```

- [ ] **Step 3: Run the setup testing-mode test**

Run:

```bash
tests/spec2pr/run-tests.sh
```

Expected: `test_spec2pr_setup_testing_mode_does_not_run_installer_body` passes. Migration tests that call `migrate_spec2pr_home` still fail because the helper is not defined yet.

- [ ] **Step 4: Commit setup sourceability**

```bash
git add bin/setup
git commit -m "test: make setup sourceable for migration tests"
```

## Task 5: Migration Helper Implementation

**Files:**
- Modify: `bin/setup`
- Test: `tests/spec2pr/test-home-migration.sh`

- [ ] **Step 1: Add migration helper functions**

In `bin/setup`, insert these functions after `ask_replace()` and before `main()`:

```bash
spec2pr_home_same_filesystem() {
  local legacy="$1" rulez_home="$2"
  local legacy_dev rulez_dev
  legacy_dev="$(stat -c %d "$legacy" 2>/dev/null || stat -f %d "$legacy" 2>/dev/null || true)"
  rulez_dev="$(stat -c %d "$rulez_home" 2>/dev/null || stat -f %d "$rulez_home" 2>/dev/null || true)"
  [ -n "$legacy_dev" ] && [ "$legacy_dev" = "$rulez_dev" ]
}

spec2pr_target_symlink_points_to_legacy() {
  local target="$1" legacy="$2"
  [ -L "$target" ] && [ "$(readlink "$target")" = "$legacy" ]
}

spec2pr_dir_is_empty() {
  local dir="$1"
  [ -d "$dir" ] || return 1
  [ -z "$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]
}

spec2pr_link_target_to_legacy() {
  local target="$1" legacy="$2" reason="$3" link_warning="$4" empty_warning="$5"
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    if ln -s "$legacy" "$target"; then
      log "linked $target to existing ~/.spec2pr ($reason; not moved)"
      return 0
    fi
    warn "$link_warning"
    return 0
  fi

  if spec2pr_dir_is_empty "$target"; then
    if rmdir "$target" && ln -s "$legacy" "$target"; then
      log "linked $target to existing ~/.spec2pr ($reason; not moved)"
      return 0
    fi
    warn "$empty_warning"
    return 0
  fi

  if [ "$reason" = "active run" ]; then
    warn "warning: active ~/.spec2pr run and target is not empty; leaving both unchanged"
  else
    warn "warning: cannot atomically migrate ~/.spec2pr to $target and target is not empty; leaving both unchanged"
  fi
  return 0
}

migrate_spec2pr_home() {
  local legacy="$HOME/.spec2pr"
  local rulez_home="${RULEZ_CLAUDESET_HOME:-$HOME/.rulez-claudeset}"
  local target="$rulez_home/spec2pr"

  [ -d "$legacy" ] || return 0
  [ ! -L "$legacy" ] || return 0

  if ! mkdir -p "$rulez_home"; then
    warn "warning: cannot create $rulez_home; leaving ~/.spec2pr unchanged"
    return 0
  fi

  if spec2pr_target_symlink_points_to_legacy "$target" "$legacy"; then
    return 0
  fi

  if find "$legacy" -mindepth 1 -maxdepth 1 -type d -name '*.lock' -print -quit | grep -q .; then
    spec2pr_link_target_to_legacy \
      "$target" \
      "$legacy" \
      "active run" \
      "warning: cannot link $target to active ~/.spec2pr; leaving ~/.spec2pr unchanged" \
      "warning: cannot replace empty $target with symlink; leaving active ~/.spec2pr unchanged"
    return 0
  fi

  if ! spec2pr_home_same_filesystem "$legacy" "$rulez_home"; then
    spec2pr_link_target_to_legacy \
      "$target" \
      "$legacy" \
      "cross-filesystem" \
      "warning: cannot link $target to ~/.spec2pr; leaving ~/.spec2pr unchanged" \
      "warning: cannot replace empty $target with symlink; leaving ~/.spec2pr unchanged"
    return 0
  fi

  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    if mv "$legacy" "$target"; then
      if ln -s "$target" "$legacy"; then
        log "migrated ~/.spec2pr to $target (left a symlink)"
      else
        warn "warning: migrated ~/.spec2pr to $target but could not create legacy symlink"
      fi
    else
      warn "warning: cannot migrate ~/.spec2pr to $target; leaving it unchanged"
    fi
    return 0
  fi

  if spec2pr_dir_is_empty "$target"; then
    if rmdir "$target" && mv "$legacy" "$target"; then
      if ln -s "$target" "$legacy"; then
        log "migrated ~/.spec2pr to $target (left a symlink)"
      else
        warn "warning: migrated ~/.spec2pr to $target but could not create legacy symlink"
      fi
    else
      warn "warning: cannot replace empty $target with migrated ~/.spec2pr; leaving it unchanged"
    fi
    return 0
  fi

  warn "warning: both ~/.spec2pr and $target exist; leaving them unchanged"
  return 0
}
```

- [ ] **Step 2: Call the migration from setup main**

Inside `main()`, immediately after the `jq` dependency check and before symlinking commands, add:

```bash
  migrate_spec2pr_home
```

- [ ] **Step 3: Run migration tests**

Run:

```bash
tests/spec2pr/run-tests.sh
```

Expected: all `tests/spec2pr/test-home-migration.sh` tests pass.

- [ ] **Step 4: Run setup manually in a sandbox**

Run:

```bash
SANDBOX="$(mktemp -d -t setup-spec2pr.XXXXXX)"
HOME="$SANDBOX/home" bash bin/setup -q
test ! -e "$SANDBOX/home/.spec2pr"
```

Expected: exit 0. Because there is no legacy `~/.spec2pr`, setup performs no migration and creates no spec2pr state directory.

- [ ] **Step 5: Commit migration implementation**

```bash
git add bin/setup
git commit -m "feat: migrate spec2pr home during setup"
```

## Task 6: Documentation and Version

**Files:**
- Modify: `README.md`
- Modify: `commands/rulez/spec2pr.md`
- Modify: `UPGRADE.md`
- Modify: `VERSION`

- [ ] **Step 1: Update the README state path**

In `README.md`, replace the `scripts/spec2pr.sh` paragraph with:

```markdown
**`scripts/spec2pr.sh <spec.md>`** - run from inside a repo, pointed at a feature spec. It works in an isolated worktree (`~/.worktrees/<id>`, branch `spec2pr/<slug>`, logs/state under `~/.rulez-claudeset/spec2pr/<id>/`) and runs: spec-review loop -> plan -> plan-review loop -> implement -> push + open a GitHub PR -> diff gate -> PR-review loop. Each review loop fixes blocker/major findings and repeats up to `MAX_FIX_ROUNDS`. Ends on `SPEC2PR DONE pr=<url> worktree=<path>` (exit 0), or HALT (1) / SPLIT (2, diff too big) / DIRTY (3, findings remain after the cap).
```

- [ ] **Step 2: Update the slash-command status listing**

In `commands/rulez/spec2pr.md`, replace the status-list command:

```markdown
   `for f in ~/.spec2pr/*.status; do [ -f "$f" ] && printf '%s -> %s\n' "$(basename "$f" .status)" "$(tail -1 "$f")"; done`
```

with:

```markdown
   `for f in ~/.rulez-claudeset/spec2pr/*.status; do [ -f "$f" ] && printf '%s -> %s\n' "$(basename "$f" .status)" "$(tail -1 "$f")"; done`
```

- [ ] **Step 3: Update the slash-command log path**

In `commands/rulez/spec2pr.md`, replace:

```markdown
  `~/.spec2pr/<id>/`.
```

with:

```markdown
  `~/.rulez-claudeset/spec2pr/<id>/`.
```

- [ ] **Step 4: Add an upgrade note**

At the top of `UPGRADE.md`, above `## To v1.6.1 - from v1.6.0`, insert:

```markdown
## To v1.6.2 - from v1.6.1

**Action:** None. `bin/setup` migrates the default `spec2pr` state dir
automatically when it is safe.

**Caveat:** `/rulez:spec2pr` state now defaults to
`~/.rulez-claudeset/spec2pr/`; worktrees stay at `~/.worktrees/`.
On normal same-filesystem installs, existing `~/.spec2pr/` is moved there
and the old path becomes a deletable symlink after no local scripts still
reference it. With a cross-filesystem custom `RULEZ_CLAUDESET_HOME`, or
while a legacy run is locked, the new default may be a symlink back to the
old path until you manually migrate the state.

```

- [ ] **Step 5: Bump the version**

Replace the full contents of `VERSION` with:

```text
1.6.2
```

- [ ] **Step 6: Search for stale user-facing legacy path references**

Run:

```bash
rg -n "~/.spec2pr|\\$HOME/\\.spec2pr" README.md commands/rulez/spec2pr.md UPGRADE.md scripts tests bin
```

Expected: remaining matches are either migration implementation/tests, compatibility warnings, or upgrade history for old releases. No current README or command instructions point users at `~/.spec2pr` as the default.

- [ ] **Step 7: Commit docs and version**

```bash
git add README.md commands/rulez/spec2pr.md UPGRADE.md VERSION
git commit -m "docs: document consolidated spec2pr home"
```

## Task 7: Final Verification

**Files:**
- Read: all changed files

- [ ] **Step 1: Run the full spec2pr test suite**

Run:

```bash
tests/spec2pr/run-tests.sh
```

Expected: all tests pass with `0 failed`.

- [ ] **Step 2: Run the setup script in quiet mode**

Run:

```bash
SANDBOX="$(mktemp -d -t setup-final.XXXXXX)"
mkdir -p "$SANDBOX/home/.spec2pr/final-run"
printf 'meta\n' > "$SANDBOX/home/.spec2pr/final-run/meta"
HOME="$SANDBOX/home" bash bin/setup -q
test -f "$SANDBOX/home/.rulez-claudeset/spec2pr/final-run/meta"
test -L "$SANDBOX/home/.spec2pr"
```

Expected: exit 0 and the legacy state is migrated under `~/.rulez-claudeset/spec2pr`.

- [ ] **Step 3: Verify no unintended files changed**

Run:

```bash
git status --short
```

Expected: only files listed in this plan are modified after the final commit, or the working tree is clean if every task was committed.

- [ ] **Step 4: Commit final fixes if verification required changes**

If Step 1 or Step 2 exposed a small correction, commit exactly those files:

```bash
git add bin/setup scripts/lib/spec2pr-runtime.sh scripts/spec2pr-watch.sh tests/spec2pr/test-home-migration.sh README.md commands/rulez/spec2pr.md UPGRADE.md VERSION
git commit -m "fix: stabilize spec2pr home migration"
```

Skip this commit when no verification fixes were made.

## Self-Review Notes

- Spec coverage: default resolution changes are in Task 2; `SPEC2PR_HOME` override preservation is tested in Task 1; setup migration, idempotency, active locks, same-filesystem moves, cross-filesystem symlinks, non-empty target refusal, and contained failures are covered in Tasks 3-5; docs and version are covered in Task 6.
- Placeholder scan: this plan contains concrete paths, commands, expected results, and code blocks for every implementation step.
- Type/name consistency: the setup helper names used in tests match the helper names defined in Task 5: `migrate_spec2pr_home`, `spec2pr_home_same_filesystem`, `spec2pr_target_symlink_points_to_legacy`, `spec2pr_dir_is_empty`, and `spec2pr_link_target_to_legacy`.
