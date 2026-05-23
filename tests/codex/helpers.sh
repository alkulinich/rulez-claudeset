#!/usr/bin/env bash
# Shared helpers for tests/codex/. Source from run-tests.sh.

TESTS_RUN=${TESTS_RUN:-0}
TESTS_FAILED=${TESTS_FAILED:-0}

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

make_temp_home() {
  mktemp -d -t codextest-home.XXXXXX
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="${3:-values not equal}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$expected" = "$actual" ]; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$msg" "$expected" "$actual"
  fi
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  local msg="${3:-string should contain expected text}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    expected to contain: %s\n    actual: %s\n' "$msg" "$needle" "$haystack"
  fi
}

assert_symlink_target() {
  local link_path="$1"
  local expected_target="$2"
  local msg="${3:-symlink target should match}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ ! -L "$link_path" ]; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    not a symlink: %s\n' "$msg" "$link_path"
    return
  fi

  local actual_target
  actual_target="$(readlink "$link_path")"
  if [ "$actual_target" = "$expected_target" ]; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$msg" "$expected_target" "$actual_target"
  fi
}
