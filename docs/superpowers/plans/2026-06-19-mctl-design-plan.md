# mctl Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `mctl`, a small tmux-backed mission control command for launching and watching detached `spec2pr.sh` and `review-pr.sh` runs.

**Architecture:** Add one Bash entrypoint at `scripts/mctl.sh` that owns a per-run registry under `${RULEZ_CLAUDESET_HOME:-$HOME/.rulez-claudeset}/mctl`, launches one tmux session per run, lists run state, and opens a three-pane dashboard. Reuse `spec2pr-watch.sh` for details, `tail -F` for brief logs, and shell-quoted generated commands everywhere tmux runs shell code.

**Tech Stack:** Bash, tmux, fzf, script, git, existing shell test harness conventions from `tests/spec2pr`.

---

## Source Spec

`docs/superpowers/specs/2026-06-19-mctl-design.md`

## File Structure

- Create `scripts/mctl.sh` - single command entrypoint for `add`, `ls`, and the no-arg dashboard. The file should expose pure-ish helpers when sourced with `MCTL_TESTING=1`, following the `SPEC2PR_WATCH_TESTING=1` pattern in `scripts/spec2pr-watch.sh`.
- Create `tests/mctl/run-tests.sh` - no-framework shell runner that sources helper and test files, matching `tests/spec2pr/run-tests.sh`.
- Create `tests/mctl/helpers.sh` - sandbox setup, assertions, stub installation, and `run_mctl`.
- Create `tests/mctl/stub-tmux.sh` - records `tmux` invocations and simulates `has-session` for configured session names.
- Create `tests/mctl/stub-script.sh` - records `script` invocation arguments and can execute the provided command in tests that inspect wrapper behavior.
- Create `tests/mctl/stub-fzf.sh` - records dashboard command-line arguments and exits immediately.
- Create `tests/mctl/test-add.sh` - add-command tests for naming, validation, metadata, launch commands, duplicate refusal, environment capture, and installed-path resolution.
- Create `tests/mctl/test-ls.sh` - run discovery and state tests.
- Create `tests/mctl/test-dashboard.sh` - dashboard command-builder and tmux/fzf wiring tests.
- Modify `bin/setup` - symlink `scripts/mctl.sh` to `~/.local/bin/mctl` and warn when `~/.local/bin` is not on `PATH`; warn for `tmux`, `script`, and `fzf`.
- Modify `README.md` - replace the manual "Watching progress" tmux dance with a short `mctl` section while keeping direct tmux fallback notes.

## Task 1: Add mctl Test Harness and Stubs

**Files:**
- Create: `tests/mctl/run-tests.sh`
- Create: `tests/mctl/helpers.sh`
- Create: `tests/mctl/stub-tmux.sh`
- Create: `tests/mctl/stub-script.sh`
- Create: `tests/mctl/stub-fzf.sh`

- [ ] **Step 1: Create the test runner**

Create `tests/mctl/run-tests.sh`:

```bash
#!/usr/bin/env bash
# Test runner for mctl. Sources helpers.sh and invokes each test_* function
# defined in tests/mctl/test-*.sh. No external test framework needed.
set -uo pipefail

TESTS_RUN=0
TESTS_FAILED=0

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=helpers.sh
source "$DIR/helpers.sh"

for f in "$DIR"/test-*.sh; do
  [ -f "$f" ] || continue
  # shellcheck disable=SC1090
  source "$f"
done

for fn in $(declare -F | awk '{print $3}' | grep '^test_' || true); do
  printf '%s\n' "$fn"
  "$fn"
done

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
```

- [ ] **Step 2: Create shared test helpers**

Create `tests/mctl/helpers.sh`:

```bash
#!/usr/bin/env bash
# Shared test helpers for tests/mctl/. Source from run-tests.sh.

TESTS_RUN=${TESTS_RUN:-0}
TESTS_FAILED=${TESTS_FAILED:-0}

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
MCTL="$REPO_ROOT/scripts/mctl.sh"

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-values not equal}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$expected" = "$actual" ]; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$msg" "$expected" "$actual"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-output should contain needle}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    missing: %s\n    haystack: %s\n' "$msg" "$needle" "$haystack"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-output should not contain needle}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    unexpectedly contained: %s\n' "$msg" "$needle"
  fi
}

assert_file_exists() {
  local path="$1" msg="${2:-file should exist}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ -e "$path" ]; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    missing path: %s\n' "$msg" "$path"
  fi
}

assert_file_absent() {
  local path="$1" msg="${2:-file should be absent}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ ! -e "$path" ]; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    existing path: %s\n' "$msg" "$path"
  fi
}

make_sandbox() {
  SANDBOX="$(mktemp -d -t mctl-test.XXXXXX)"
  mkdir -p "$SANDBOX/bin" "$SANDBOX/home" "$SANDBOX/repo/docs/superpowers/specs"
  export HOME="$SANDBOX/home"
  export RULEZ_CLAUDESET_HOME="$SANDBOX/rulez home"
  export SPEC2PR_HOME="$SANDBOX/spec2pr home"
  export SPEC2PR_WORKTREES="$SANDBOX/worktrees home"
  export PATH="$SANDBOX/bin:$PATH"

  cp "$TESTS_DIR/stub-tmux.sh" "$SANDBOX/bin/tmux"
  cp "$TESTS_DIR/stub-script.sh" "$SANDBOX/bin/script"
  cp "$TESTS_DIR/stub-fzf.sh" "$SANDBOX/bin/fzf"
  chmod +x "$SANDBOX/bin/tmux" "$SANDBOX/bin/script" "$SANDBOX/bin/fzf"
  ln -s "$(command -v dirname)" "$SANDBOX/bin/dirname"

  REPO="$SANDBOX/repo"
  git init -q -b main "$REPO"
  git -C "$REPO" config user.email "test@test"
  git -C "$REPO" config user.name "mctl-test"
  printf '# repo\n' > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit -qm init
  SPEC="$REPO/docs/superpowers/specs/Foo Bar.md"
  printf '# Foo Bar\n' > "$SPEC"

  : > "$SANDBOX/tmux.log"
  : > "$SANDBOX/script.log"
  : > "$SANDBOX/fzf.log"
  export MCTL_TEST_LOG_DIR="$SANDBOX"
}

run_mctl() {
  set +e
  OUT="$("${BASH:-bash}" "$MCTL" "$@" 2>&1)"
  RC=$?
}

run_mctl_in_dir() {
  local cwd="$1"
  shift
  set +e
  OUT="$(cd "$cwd" && "${BASH:-bash}" "$MCTL" "$@" 2>&1)"
  RC=$?
}

run_mctl_with_stubs_only() {
  local saved_path="$PATH"
  PATH="$SANDBOX/bin"
  set +e
  OUT="$("${BASH:-bash}" "$MCTL" "$@" 2>&1)"
  RC=$?
  PATH="$saved_path"
}

source_mctl() {
  local saved_options
  saved_options="$(set +o)"
  MCTL_TESTING=1 source "$MCTL"
  eval "$saved_options"
}

meta_value() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1 == k {print substr($0, length(k) + 2)}' "$file"
}
```

- [ ] **Step 3: Create the tmux stub**

Create `tests/mctl/stub-tmux.sh`:

```bash
#!/usr/bin/env bash
set -eu

log="${MCTL_TEST_LOG_DIR:?}/tmux.log"
printf 'tmux' >> "$log"
for arg in "$@"; do
  printf ' [%s]' "$arg" >> "$log"
done
printf '\n' >> "$log"

cmd="${1:-}"
case "$cmd" in
  has-session)
    target=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t)
          target="$2"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    if [ -f "$MCTL_TEST_LOG_DIR/tmux-sessions" ] && grep -Fxq "$target" "$MCTL_TEST_LOG_DIR/tmux-sessions"; then
      exit 0
    fi
    exit 1
    ;;
  new-session|split-window|select-layout|attach-session|respawn-pane|send-keys)
    exit 0
    ;;
  display-message)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
```

- [ ] **Step 4: Create the script stub**

Create `tests/mctl/stub-script.sh`:

```bash
#!/usr/bin/env bash
set -eu

log="${MCTL_TEST_LOG_DIR:?}/script.log"
printf 'script' >> "$log"
for arg in "$@"; do
  printf ' [%s]' "$arg" >> "$log"
done
printf '\n' >> "$log"

exit 0
```

- [ ] **Step 5: Create the fzf stub**

Create `tests/mctl/stub-fzf.sh`:

```bash
#!/usr/bin/env bash
set -eu

log="${MCTL_TEST_LOG_DIR:?}/fzf.log"
printf 'fzf' >> "$log"
for arg in "$@"; do
  printf ' [%s]' "$arg" >> "$log"
done
printf '\n' >> "$log"

exit 0
```

- [ ] **Step 6: Run the harness before tests exist**

Run:

```bash
tests/mctl/run-tests.sh
```

Expected: PASS with `0 tests run, 0 failed`.

- [ ] **Step 7: Commit the harness**

```bash
git add tests/mctl/run-tests.sh tests/mctl/helpers.sh tests/mctl/stub-tmux.sh tests/mctl/stub-script.sh tests/mctl/stub-fzf.sh
git commit -m "test: add mctl shell harness"
```

## Task 2: Implement Shared mctl Helpers

**Files:**
- Create: `scripts/mctl.sh`
- Create: `tests/mctl/test-add.sh`

- [ ] **Step 1: Write failing helper tests**

Create `tests/mctl/test-add.sh` with initial pure helper coverage:

```bash
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
  assert_eq "'it'\\''s fine'" "$(shell_quote "it's fine")" "shell_quote escapes single quote"
}

test_mctl_script_dir_resolves_real_scripts_directory() {
  make_sandbox
  source_mctl

  assert_eq "$REPO_ROOT/scripts" "$SCRIPT_DIR" "script dir is absolute scripts directory"
  assert_eq "$REPO_ROOT/scripts/spec2pr.sh" "$SPEC2PR_SCRIPT" "spec2pr path is absolute"
  assert_eq "$REPO_ROOT/scripts/review-pr.sh" "$REVIEW_PR_SCRIPT" "review-pr path is absolute"
  assert_eq "$REPO_ROOT/scripts/spec2pr-watch.sh" "$WATCH_SCRIPT" "watch path is absolute"
}
```

- [ ] **Step 2: Run tests to verify helper failures**

Run:

```bash
tests/mctl/run-tests.sh
```

Expected: FAIL because `scripts/mctl.sh` does not exist or does not define `sanitize`, `shell_quote`, and script path globals.

- [ ] **Step 3: Create `scripts/mctl.sh` with shared helpers**

Create `scripts/mctl.sh` with executable mode:

```bash
#!/usr/bin/env bash
set -euo pipefail

real_script_path() {
  local src="${BASH_SOURCE[0]}"
  while [ -L "$src" ]; do
    local dir link
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    link="$(readlink "$src")"
    case "$link" in
      /*) src="$link" ;;
      *) src="$dir/$link" ;;
    esac
  done
  cd -P "$(dirname "$src")" && pwd
}

SCRIPT_DIR="$(real_script_path)"
SPEC2PR_SCRIPT="$SCRIPT_DIR/spec2pr.sh"
REVIEW_PR_SCRIPT="$SCRIPT_DIR/review-pr.sh"
WATCH_SCRIPT="$SCRIPT_DIR/spec2pr-watch.sh"
RULEZ_CLAUDESET_HOME="${RULEZ_CLAUDESET_HOME:-$HOME/.rulez-claudeset}"
MCTL_HOME="$RULEZ_CLAUDESET_HOME/mctl"
DASH_SESSION="mctl-dash"

sanitize() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//'
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

die() {
  printf 'mctl: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"
}

if [ "${MCTL_TESTING:-0}" = "1" ]; then
  return 0
fi

main() {
  case "${1:-}" in
    add)
      shift
      cmd_add "$@"
      ;;
    ls)
      shift
      cmd_ls "$@"
      ;;
    "")
      cmd_dashboard
      ;;
    *)
      die "usage: mctl [add spec2pr <spec.md>|add review-pr <pr#>|ls]"
      ;;
  esac
}

main "$@"
```

- [ ] **Step 4: Run helper tests**

Run:

```bash
tests/mctl/run-tests.sh
```

Expected: PASS for the three helper tests.

- [ ] **Step 5: Commit helpers**

```bash
git add scripts/mctl.sh tests/mctl/test-add.sh
git commit -m "feat: add mctl helper shell"
```

## Task 3: Implement `mctl add` Validation, Naming, and Metadata

**Files:**
- Modify: `scripts/mctl.sh`
- Modify: `tests/mctl/test-add.sh`

- [ ] **Step 1: Append failing add metadata tests**

Append to `tests/mctl/test-add.sh`:

```bash
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
```

- [ ] **Step 2: Run tests to verify add failures**

Run:

```bash
tests/mctl/run-tests.sh
```

Expected: FAIL because `cmd_add`, metadata writing, and validation are not implemented.

- [ ] **Step 3: Add metadata and validation helpers**

Insert these functions in `scripts/mctl.sh` above `main()`:

```bash
utc_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

git_root_for_path() {
  local path="$1" dir
  dir="$(cd -P "$(dirname "$path")" && pwd)" || return 1
  git -C "$dir" rev-parse --show-toplevel 2>/dev/null
}

git_root_for_cwd() {
  git rev-parse --show-toplevel 2>/dev/null
}

canonical_file_path() {
  local path="$1" dir base
  dir="$(cd -P "$(dirname "$path")" && pwd)" || return 1
  base="$(basename "$path")"
  printf '%s/%s\n' "$dir" "$base"
}

effective_spec2pr_home() {
  printf '%s\n' "${SPEC2PR_HOME:-$HOME/.spec2pr}"
}

effective_spec2pr_worktrees() {
  printf '%s\n' "${SPEC2PR_WORKTREES:-$HOME/.worktrees}"
}

meta_get() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1 == k {print substr($0, length(k) + 2)}' "$file"
}

write_meta() {
  local run_dir="$1" kind="$2" token="$3" session="$4" repo="$5" started="$6" spec_home="$7" wt_home="$8" target="$9"
  cat > "$run_dir/meta" <<EOF
kind=$kind
token=$token
session=$session
repo=$repo
started=$started
spec2pr_home=$spec_home
spec2pr_worktrees=$wt_home
target=$target
EOF
}

ensure_new_run_slot() {
  local run_dir="$1" session="$2"
  if tmux has-session -t "$session" 2>/dev/null; then
    die "session already exists: $session"
  fi
  if [ -e "$run_dir" ]; then
    if [ -f "$run_dir/exit" ]; then
      die "completed run exists at $run_dir; remove it and kill any tmux session before reusing this name"
    fi
    die "live or lost run exists at $run_dir; inspect it before reusing this name"
  fi
}
```

- [ ] **Step 4: Add `cmd_add` without tmux launch details**

Insert this function in `scripts/mctl.sh` above `main()`:

```bash
cmd_add() {
  [ "$#" -eq 2 ] || die "usage: mctl add spec2pr <spec.md> | mctl add review-pr <pr#>"
  require_cmd tmux
  require_cmd script

  local kind="$1" arg="$2" repo target repo_slug name token session run_dir started
  case "$kind" in
    spec2pr)
      [ -f "$arg" ] || die "spec not found: $arg"
      repo="$(git_root_for_path "$arg")" || die "spec is not inside a git repository"
      target="$(canonical_file_path "$arg")" || die "could not resolve spec path: $arg"
      repo_slug="$(sanitize "$(basename "$repo")")"
      local spec_base spec_stem spec_slug
      spec_base="$(basename "$target")"
      spec_stem="${spec_base%.*}"
      spec_slug="$(sanitize "$spec_stem")"
      [ -n "$repo_slug" ] || die "empty repository slug"
      [ -n "$spec_slug" ] || die "empty spec slug"
      name="$repo_slug-$spec_slug"
      token="$name"
      ;;
    review-pr)
      [[ "$arg" =~ ^[0-9]+$ ]] || die "pr number must be numeric: $arg"
      repo="$(git_root_for_cwd)" || die "not inside a git repository"
      target="$arg"
      repo_slug="$(sanitize "$(basename "$repo")")"
      [ -n "$repo_slug" ] || die "empty repository slug"
      name="$repo_slug-pr-$arg"
      token="$name"
      ;;
    *)
      die "unknown add kind: $kind"
      ;;
  esac

  session="mctl-$name"
  run_dir="$MCTL_HOME/$name"
  ensure_new_run_slot "$run_dir" "$session"

  mkdir -p "$run_dir"
  : > "$run_dir/brief.log"
  started="$(utc_now)"
  write_meta "$run_dir" "$kind" "$token" "$session" "$repo" "$started" \
    "$(effective_spec2pr_home)" "$(effective_spec2pr_worktrees)" "$target"

  launch_run "$run_dir"
  printf '%s\n' "$name"
}
```

- [ ] **Step 5: Add a temporary `launch_run` shim**

Insert this function above `cmd_add()` so tests can pass before the runner wrapper is implemented:

```bash
launch_run() {
  local run_dir="$1" meta="$run_dir/meta" session
  session="$(meta_get "$meta" session)"
  tmux new-session -d -s "$session" "printf '%s\n' mctl launch pending; read -r _"
}
```

- [ ] **Step 6: Run add metadata tests**

Run:

```bash
tests/mctl/run-tests.sh
```

Expected: PASS for helper and metadata tests.

- [ ] **Step 7: Commit add metadata**

```bash
git add scripts/mctl.sh tests/mctl/test-add.sh
git commit -m "feat: add mctl registry metadata"
```

## Task 4: Implement Add-Time Runner Wrapper

**Files:**
- Modify: `scripts/mctl.sh`
- Modify: `tests/mctl/test-add.sh`

- [ ] **Step 1: Append failing runner command tests**

Append to `tests/mctl/test-add.sh`:

```bash
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
```

Add this helper to `tests/mctl/helpers.sh`:

```bash
shell_escape_for_test() {
  printf '%s' "$1"
}
```

- [ ] **Step 2: Run tests to verify runner failures**

Run:

```bash
tests/mctl/run-tests.sh
```

Expected: FAIL because `launch_run` still uses the temporary command.

- [ ] **Step 3: Add cross-platform `script` command builder**

Replace the temporary `launch_run()` in `scripts/mctl.sh` with these functions:

```bash
runner_for_kind() {
  case "$1" in
    spec2pr) printf '%s\n' "$SPEC2PR_SCRIPT" ;;
    review-pr) printf '%s\n' "$REVIEW_PR_SCRIPT" ;;
    *) return 1 ;;
  esac
}

build_inner_runner_command() {
  local run_dir="$1" meta="$run_dir/meta"
  local kind repo target spec_home wt_home runner exit_path
  kind="$(meta_get "$meta" kind)"
  repo="$(meta_get "$meta" repo)"
  target="$(meta_get "$meta" target)"
  spec_home="$(meta_get "$meta" spec2pr_home)"
  wt_home="$(meta_get "$meta" spec2pr_worktrees)"
  runner="$(runner_for_kind "$kind")"
  exit_path="$run_dir/exit"

  printf 'cd %s && SPEC2PR_HOME=%s SPEC2PR_WORKTREES=%s SPEC2PR_VERBOSE=1 bash %s %s; rc=$?; printf %s "$rc" "$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)" > %s; exit "$rc"' \
    "$(shell_quote "$repo")" \
    "$(shell_quote "$spec_home")" \
    "$(shell_quote "$wt_home")" \
    "$(shell_quote "$runner")" \
    "$(shell_quote "$target")" \
    "$(shell_quote $'rc=%s\nfinished=%s\n')" \
    "$(shell_quote "$exit_path")"
}

build_script_command() {
  local inner="$1" brief="$2" os_name
  os_name="$(uname -s)"
  case "$os_name" in
    Linux)
      if script --help 2>&1 | grep -q -- '--return'; then
        printf 'script --flush --return -c %s %s' "$(shell_quote "$inner")" "$(shell_quote "$brief")"
      else
        printf 'script --flush -c %s %s' "$(shell_quote "$inner")" "$(shell_quote "$brief")"
      fi
      ;;
    Darwin|FreeBSD|OpenBSD|NetBSD)
      printf 'script -F -q %s /bin/sh -c %s' "$(shell_quote "$brief")" "$(shell_quote "$inner")"
      ;;
    *)
      printf 'script --flush -c %s %s' "$(shell_quote "$inner")" "$(shell_quote "$brief")"
      ;;
  esac
}

launch_run() {
  local run_dir="$1" meta="$run_dir/meta" session brief inner script_cmd tmux_cmd
  session="$(meta_get "$meta" session)"
  brief="$run_dir/brief.log"
  inner="$(build_inner_runner_command "$run_dir")"
  script_cmd="$(build_script_command "$inner" "$brief")"
  tmux_cmd="$script_cmd; printf '\n[mctl] run finished; press Enter to close this pane... '; read -r _"
  tmux new-session -d -s "$session" "$tmux_cmd"
}
```

- [ ] **Step 4: Run runner tests**

Run:

```bash
tests/mctl/run-tests.sh
```

Expected: PASS for add metadata and runner command tests.

- [ ] **Step 5: Commit runner wrapper**

```bash
git add scripts/mctl.sh tests/mctl/test-add.sh tests/mctl/helpers.sh
git commit -m "feat: launch mctl runs through script"
```

## Task 5: Implement `mctl ls`

**Files:**
- Modify: `scripts/mctl.sh`
- Create: `tests/mctl/test-ls.sh`

- [ ] **Step 1: Write failing `ls` tests**

Create `tests/mctl/test-ls.sh`:

```bash
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
```

- [ ] **Step 2: Run tests to verify `ls` failures**

Run:

```bash
tests/mctl/run-tests.sh
```

Expected: FAIL because `cmd_ls` is not implemented.

- [ ] **Step 3: Add `cmd_ls` and state helper**

Insert these functions in `scripts/mctl.sh` above `main()`:

```bash
run_state() {
  local run_dir="$1" session="$2"
  if [ -f "$run_dir/exit" ]; then
    printf 'done\n'
  elif tmux has-session -t "$session" 2>/dev/null; then
    printf 'running\n'
  else
    printf 'lost\n'
  fi
}

cmd_ls() {
  [ "$#" -eq 0 ] || die "usage: mctl ls"
  require_cmd tmux

  [ -d "$MCTL_HOME" ] || return 0

  local run_dir meta name kind session started state
  for run_dir in "$MCTL_HOME"/*; do
    [ -d "$run_dir" ] || continue
    meta="$run_dir/meta"
    [ -f "$meta" ] || continue
    name="$(basename "$run_dir")"
    kind="$(meta_get "$meta" kind)"
    session="$(meta_get "$meta" session)"
    started="$(meta_get "$meta" started)"
    state="$(run_state "$run_dir" "$session")"
    printf '%s %s %s %s\n' "$name" "$kind" "$state" "$started"
  done | sort
}
```

- [ ] **Step 4: Run `ls` tests**

Run:

```bash
tests/mctl/run-tests.sh
```

Expected: PASS for `ls` tests.

- [ ] **Step 5: Commit `ls`**

```bash
git add scripts/mctl.sh tests/mctl/test-ls.sh
git commit -m "feat: list mctl run state"
```

## Task 6: Implement Dashboard Command Builders

**Files:**
- Modify: `scripts/mctl.sh`
- Create: `tests/mctl/test-dashboard.sh`

- [ ] **Step 1: Write failing dashboard builder tests**

Create `tests/mctl/test-dashboard.sh`:

```bash
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
  assert_contains "$cmd" "--track" "fzf tracks the selected row across reloads"
}
```

- [ ] **Step 2: Run tests to verify builder failures**

Run:

```bash
tests/mctl/run-tests.sh
```

Expected: FAIL because dashboard command builders are absent.

- [ ] **Step 3: Add dashboard command builders**

Insert these functions in `scripts/mctl.sh` above `main()`:

```bash
build_empty_command() {
  printf "printf '%%s\\n' 'no runs - mctl add spec2pr <spec>'"
}

first_run_dir() {
  [ -d "$MCTL_HOME" ] || return 1
  find "$MCTL_HOME" -mindepth 1 -maxdepth 1 -type d | sort | head -n 1
}

run_dir_for_name() {
  local name="$1"
  [ -n "$name" ] || return 1
  [ -d "$MCTL_HOME/$name" ] || return 1
  printf '%s\n' "$MCTL_HOME/$name"
}

build_brief_command() {
  local run_dir="$1"
  printf 'tail -F %s' "$(shell_quote "$run_dir/brief.log")"
}

build_details_command() {
  local run_dir="$1" meta="$run_dir/meta" spec_home wt_home token
  spec_home="$(meta_get "$meta" spec2pr_home)"
  wt_home="$(meta_get "$meta" spec2pr_worktrees)"
  token="$(meta_get "$meta" token)"
  printf 'SPEC2PR_HOME=%s SPEC2PR_WORKTREES=%s bash %s %s' \
    "$(shell_quote "$spec_home")" \
    "$(shell_quote "$wt_home")" \
    "$(shell_quote "$WATCH_SCRIPT")" \
    "$(shell_quote "$token")"
}

build_list_command() {
  printf 'while :; do clear; bash %s ls; sleep 2; done' "$(shell_quote "$SCRIPT_DIR/mctl.sh")"
}

build_fzf_command() {
  local list_cmd reload focus refresh_driver start_bind
  list_cmd="bash $(shell_quote "$SCRIPT_DIR/mctl.sh") ls"
  reload="ctrl-r:reload($list_cmd)"
  focus="focus:execute-silent(bash $(shell_quote "$SCRIPT_DIR/mctl.sh") __retarget {1})"
  refresh_driver="while tmux has-session -t $(shell_quote "$DASH_SESSION") 2>/dev/null; do sleep 2; tmux send-keys -t $(shell_quote "$DASH_SESSION:0.0") C-r; done >/dev/null 2>&1 &"
  start_bind="start:execute-silent($refresh_driver)+reload($list_cmd)"
  printf '%s | fzf --ansi --no-sort --disabled --track --bind %s --bind %s --bind %s --header %s' \
    "$list_cmd" \
    "$(shell_quote "$start_bind")" \
    "$(shell_quote "$reload")" \
    "$(shell_quote "$focus")" \
    "$(shell_quote "mctl runs")"
}
```

- [ ] **Step 4: Run builder tests**

Run:

```bash
tests/mctl/run-tests.sh
```

Expected: PASS for dashboard command builder tests.

- [ ] **Step 5: Commit builders**

```bash
git add scripts/mctl.sh tests/mctl/test-dashboard.sh
git commit -m "feat: build mctl dashboard commands"
```

## Task 7: Implement Dashboard tmux Layout and Retargeting

**Files:**
- Modify: `scripts/mctl.sh`
- Modify: `tests/mctl/test-dashboard.sh`

- [ ] **Step 1: Append failing dashboard layout tests**

Append to `tests/mctl/test-dashboard.sh`:

```bash
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
  assert_contains "$log" "tmux [new-session] [-d] [-s] [mctl-dash]" "dashboard creates session"
  assert_contains "$log" "tmux [split-window] [-h] [-t] [mctl-dash:0.0]" "dashboard creates right column"
  assert_contains "$log" "tmux [split-window] [-v] [-t] [mctl-dash:0.1]" "dashboard splits right column"
  assert_contains "$log" "tmux [attach-session] [-t] [mctl-dash]" "dashboard attaches after layout"
}

test_dashboard_empty_registry_shows_message_in_task_list() {
  make_sandbox

  run_mctl

  local log
  log="$(cat "$SANDBOX/tmux.log")"
  assert_eq "0" "$RC" "empty dashboard exits 0"
  assert_contains "$log" "no runs - mctl add spec2pr <spec>" "empty dashboard shows message in task list"
}

test_dashboard_retarget_respawns_brief_and_details() {
  make_sandbox
  dashboard_fixture_run

  run_mctl __retarget repo-foo

  local log
  log="$(cat "$SANDBOX/tmux.log")"
  assert_eq "0" "$RC" "retarget exits 0"
  assert_contains "$log" "tmux [respawn-pane] [-k] [-t] [mctl-dash:0.1]" "retarget respawns brief pane"
  assert_contains "$log" "tail -F" "retarget brief tails log"
  assert_contains "$log" "tmux [respawn-pane] [-k] [-t] [mctl-dash:0.2]" "retarget respawns details pane"
  assert_contains "$log" "spec2pr-watch.sh" "retarget details invokes watcher"
}
```

- [ ] **Step 2: Run tests to verify layout failures**

Run:

```bash
tests/mctl/run-tests.sh
```

Expected: FAIL because `cmd_dashboard` and `cmd_retarget` are absent.

- [ ] **Step 3: Add hidden retarget dispatch**

Modify the `main()` case in `scripts/mctl.sh` so it includes this hidden testable/internal command before the default case:

```bash
    __retarget)
      shift
      cmd_retarget "$@"
      ;;
```

- [ ] **Step 4: Add dashboard layout functions**

Insert these functions in `scripts/mctl.sh` above `main()`:

```bash
cmd_retarget() {
  [ "$#" -eq 1 ] || die "usage: mctl __retarget <name>"
  require_cmd tmux
  local run_dir="$MCTL_HOME/$1"
  [ -d "$run_dir" ] || die "unknown run: $1"
  tmux respawn-pane -k -t "$DASH_SESSION:0.1" "$(build_brief_command "$run_dir")"
  tmux respawn-pane -k -t "$DASH_SESSION:0.2" "$(build_details_command "$run_dir")"
}

cmd_dashboard() {
  require_cmd tmux
  require_cmd fzf

  if tmux has-session -t "$DASH_SESSION" 2>/dev/null; then
    tmux attach-session -t "$DASH_SESSION"
    return 0
  fi

  local first left_cmd brief_cmd details_cmd
  first="$(first_run_dir || true)"
  if [ -n "$first" ]; then
    left_cmd="$(build_fzf_command)"
    brief_cmd="$(build_brief_command "$first")"
    details_cmd="$(build_details_command "$first")"
  else
    left_cmd="$(build_empty_command)"
    brief_cmd="$(build_empty_command)"
    details_cmd="$(build_empty_command)"
  fi

  tmux new-session -d -s "$DASH_SESSION" "$left_cmd"
  tmux split-window -h -t "$DASH_SESSION:0.0" "$brief_cmd"
  tmux split-window -v -t "$DASH_SESSION:0.1" "$details_cmd"
  tmux select-layout -t "$DASH_SESSION" main-vertical
  tmux attach-session -t "$DASH_SESSION"
}
```

- [ ] **Step 5: Run dashboard layout tests**

Run:

```bash
tests/mctl/run-tests.sh
```

Expected: PASS for dashboard layout and retarget tests.

- [ ] **Step 6: Commit dashboard layout**

```bash
git add scripts/mctl.sh tests/mctl/test-dashboard.sh
git commit -m "feat: add mctl dashboard layout"
```

## Task 8: Add Dependency Failure Tests

**Files:**
- Modify: `tests/mctl/test-add.sh`
- Modify: `tests/mctl/test-dashboard.sh`
- Modify: `scripts/mctl.sh`

- [ ] **Step 1: Add failing missing-dependency tests**

Append to `tests/mctl/test-add.sh`:

```bash
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
```

Append to `tests/mctl/test-dashboard.sh`:

```bash
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
```

- [ ] **Step 2: Run dependency tests**

Run:

```bash
tests/mctl/run-tests.sh
```

Expected: PASS if `require_cmd` is already called before side effects; FAIL if command order creates partial state before the dependency check.

- [ ] **Step 3: Fix dependency ordering if tests fail**

If the test output shows a partial dashboard session when `fzf` is missing, make `cmd_dashboard()` start exactly like this:

```bash
cmd_dashboard() {
  require_cmd tmux
  require_cmd fzf

  if tmux has-session -t "$DASH_SESSION" 2>/dev/null; then
    tmux attach-session -t "$DASH_SESSION"
    return 0
  fi
```

If the test output shows a run directory created when `script` is missing, make `cmd_add()` start exactly like this:

```bash
cmd_add() {
  [ "$#" -eq 2 ] || die "usage: mctl add spec2pr <spec.md> | mctl add review-pr <pr#>"
  require_cmd tmux
  require_cmd script
```

- [ ] **Step 4: Re-run dependency tests**

Run:

```bash
tests/mctl/run-tests.sh
```

Expected: PASS.

- [ ] **Step 5: Commit dependency behavior**

```bash
git add scripts/mctl.sh tests/mctl/test-add.sh tests/mctl/test-dashboard.sh
git commit -m "test: cover mctl dependency failures"
```

## Task 9: Add Installed-Path Smoke Test

**Files:**
- Modify: `tests/mctl/test-add.sh`
- Modify: `scripts/mctl.sh`

- [ ] **Step 1: Append failing symlink invocation test**

Append to `tests/mctl/test-add.sh`:

```bash
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
```

- [ ] **Step 2: Run symlink test**

Run:

```bash
tests/mctl/run-tests.sh
```

Expected: PASS if `real_script_path()` follows symlinks correctly; FAIL if companion scripts are resolved from the symlink directory.

- [ ] **Step 3: Fix symlink resolution if needed**

If the symlink test fails, replace `real_script_path()` with this implementation:

```bash
real_script_path() {
  local src="${BASH_SOURCE[0]}"
  while [ -L "$src" ]; do
    local dir link
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    link="$(readlink "$src")"
    case "$link" in
      /*) src="$link" ;;
      *) src="$dir/$link" ;;
    esac
  done
  cd -P "$(dirname "$src")" && pwd
}
```

- [ ] **Step 4: Re-run symlink test**

Run:

```bash
tests/mctl/run-tests.sh
```

Expected: PASS.

- [ ] **Step 5: Commit installed-path behavior**

```bash
git add scripts/mctl.sh tests/mctl/test-add.sh
git commit -m "test: cover symlinked mctl invocation"
```

## Task 10: Wire `mctl` Into Setup

**Files:**
- Modify: `bin/setup`
- Create: `tests/mctl/test-setup.sh`

- [ ] **Step 1: Write failing setup tests**

Create `tests/mctl/test-setup.sh`:

```bash
#!/usr/bin/env bash

test_setup_symlinks_mctl_and_warns_when_local_bin_missing_from_path() {
  make_sandbox
  local claude_dir="$SANDBOX/claude"
  local local_bin="$HOME/.local/bin"
  mkdir -p "$claude_dir"
  export HOME="$SANDBOX/home"
  export PATH="$SANDBOX/bin:/usr/bin:/bin"
  printf '#!/usr/bin/env bash\nprintf "{}"\n' > "$SANDBOX/bin/jq"
  chmod +x "$SANDBOX/bin/jq"

  set +e
  OUT="$(bash "$REPO_ROOT/bin/setup" 2>&1)"
  RC=$?

  assert_eq "0" "$RC" "setup exits 0"
  assert_file_exists "$local_bin/mctl" "mctl symlink created"
  assert_contains "$OUT" "~/.local/bin is not on PATH" "PATH warning"
}
```

- [ ] **Step 2: Run setup test to verify failure**

Run:

```bash
tests/mctl/run-tests.sh
```

Expected: FAIL because `bin/setup` does not create `~/.local/bin/mctl` or warn about the path yet.

- [ ] **Step 3: Update `bin/setup`**

In `bin/setup`, after the existing command symlink block and before settings merge, add:

```bash
# Symlink mctl into a user PATH location for shell use.
LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$LOCAL_BIN"
ln -sfn "$SKILL_DIR/scripts/mctl.sh" "$LOCAL_BIN/mctl"
log "Linked mctl -> ~/.local/bin/mctl"

case ":$PATH:" in
  *":$LOCAL_BIN:"*) ;;
  *) log "Warning: ~/.local/bin is not on PATH; add it or run scripts/mctl.sh directly" ;;
esac

for dep in tmux script fzf; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    log "Warning: $dep is required for mctl"
  fi
done
```

- [ ] **Step 4: Run setup test**

Run:

```bash
tests/mctl/run-tests.sh
```

Expected: PASS for setup behavior.

- [ ] **Step 5: Commit setup wiring**

```bash
git add bin/setup tests/mctl/test-setup.sh
git commit -m "feat: install mctl on setup"
```

## Task 11: Document mctl in README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update README `spec2pr & review-pr` section**

In `README.md`, after the `review-pr.sh` description and before the existing manual watcher commands, add:

```markdown
### mctl mission control

`mctl` launches unattended runs in detached tmux sessions and opens one dashboard
for all active and completed runs:

```bash
mctl add spec2pr docs/superpowers/specs/feature-a.md
mctl add review-pr 7
mctl
mctl ls
```

State lives under `${RULEZ_CLAUDESET_HOME:-~/.rulez-claudeset}/mctl/<name>/`.
Run names are repo-qualified, such as `my-repo-feature-a` and `my-repo-pr-7`.
The dashboard has a task list on the left, the captured pipeline console on the
top right, and `spec2pr-watch.sh` details on the bottom right.

Use tmux directly for operations not built into the first cut:

```bash
tmux attach -t mctl-my-repo-feature-a
tmux kill-session -t mctl-my-repo-feature-a
```
```

Rename the old `### Watching progress` heading to:

```markdown
### Manual tmux fallback
```

- [ ] **Step 2: Verify README mentions the install path**

In the `Install (claude)` explanation list, add this fourth item:

```markdown
4. Symlink `scripts/mctl.sh` to `~/.local/bin/mctl` when `bin/setup` runs
```

- [ ] **Step 3: Commit README docs**

```bash
git add README.md
git commit -m "docs: document mctl"
```

## Task 12: Final Verification

**Files:**
- Verify: `scripts/mctl.sh`
- Verify: `tests/mctl/`
- Verify: `bin/setup`
- Verify: `README.md`

- [ ] **Step 1: Run mctl tests**

Run:

```bash
tests/mctl/run-tests.sh
```

Expected: PASS with all `tests/mctl` tests passing and `0 failed`.

- [ ] **Step 2: Run existing spec2pr tests**

Run:

```bash
tests/spec2pr/run-tests.sh
```

Expected: PASS with `0 failed`. This catches accidental regressions in `spec2pr-watch.sh` assumptions and shared setup behavior.

- [ ] **Step 3: Run shell syntax checks**

Run:

```bash
bash -n scripts/mctl.sh tests/mctl/run-tests.sh tests/mctl/helpers.sh tests/mctl/stub-tmux.sh tests/mctl/stub-script.sh tests/mctl/stub-fzf.sh bin/setup
```

Expected: exit 0 with no output.

- [ ] **Step 4: Manual dashboard smoke**

From a disposable repo with a spec file, run:

```bash
bash scripts/mctl.sh add spec2pr docs/superpowers/specs/smoke.md
bash scripts/mctl.sh ls
bash scripts/mctl.sh
```

Expected:

- `add` prints a repo-qualified run name.
- `ls` shows that name with state `running`, `done`, or `lost`.
- The dashboard opens a three-pane tmux session named `mctl-dash`.
- The brief pane tails `${RULEZ_CLAUDESET_HOME:-$HOME/.rulez-claudeset}/mctl/<name>/brief.log`.
- The details pane runs `spec2pr-watch.sh <name>` with the stored `SPEC2PR_HOME` and `SPEC2PR_WORKTREES`.

- [ ] **Step 5: Commit any verification-only fixes**

If verification required fixes, commit only the files changed by those fixes:

```bash
git add scripts/mctl.sh tests/mctl bin/setup README.md
git commit -m "fix: stabilize mctl verification"
```

If no fixes were needed, do not create an empty commit.

## Self-Review Notes

- Spec coverage: `add spec2pr`, `add review-pr`, run registry layout, `ls`, dashboard panes, shell quoting, stored watcher environment, `script` wrapper, duplicate refusal, setup symlink, dependency failures, and README updates are each covered by tasks above.
- Placeholder scan: no task relies on deferred behavior; each implementation step includes concrete code or an exact command and expected result.
- Type consistency: run metadata keys are consistently `kind`, `token`, `session`, `repo`, `started`, `spec2pr_home`, `spec2pr_worktrees`, and `target`; dashboard and runner helpers read the same keys.
