#!/usr/bin/env bash
# Shared test helpers for tests/cycle/. Source from run-tests.sh.

TESTS_RUN=${TESTS_RUN:-0}
TESTS_FAILED=${TESTS_FAILED:-0}

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
CYCLE_PROMPT="$REPO_ROOT/scripts/cycle-prompt.sh"

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
  local haystack="$1" needle="$2" msg="${3:-should contain: $2}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    needle:   %s\n    haystack: %s\n' "$msg" "$needle" "$haystack"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-should not contain: $2}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    unexpected needle present: %s\n' "$msg" "$needle"
  fi
}

# Run the builder; capture stdout (CY_OUT), stderr (CY_ERR), exit code (CY_RC).
run_cycle() {
  local errfile; errfile="$(mktemp)"
  CY_OUT="$(bash "$CYCLE_PROMPT" "$@" 2>"$errfile")"
  CY_RC=$?
  CY_ERR="$(cat "$errfile")"
  rm -f "$errfile"
}
