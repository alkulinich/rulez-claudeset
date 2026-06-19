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
