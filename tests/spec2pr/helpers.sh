#!/usr/bin/env bash
# Shared test helpers for tests/spec2pr/. Source from run-tests.sh.

TESTS_RUN=${TESTS_RUN:-0}
TESTS_FAILED=${TESTS_FAILED:-0}

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
SPEC2PR="$REPO_ROOT/scripts/spec2pr.sh"

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
  local haystack="$1" needle="$2" msg="${3:-output should contain: $2}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    haystack: %s\n' "$msg" "$haystack"
  fi
}

assert_file_exists() {
  local path="$1" msg="${2:-file should exist: $1}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ -f "$path" ] || [ -d "$path" ]; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n' "$msg"
  fi
}

assert_file_absent() {
  local path="$1" msg="${2:-should not exist: $1}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ ! -e "$path" ]; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n' "$msg"
  fi
}

# Fresh sandbox: scratch project with a bare file origin, stub binaries,
# isolated SPEC2PR_HOME / worktrees root. Sets globals:
#   SANDBOX, SPEC (abs path to toy spec), PROJECT, ORIGIN, ID, BRANCH
make_sandbox() {
  SANDBOX="$(mktemp -d -t spec2pr-test.XXXXXX)"
  mkdir -p "$SANDBOX/bin" "$SANDBOX/fixtures" "$SANDBOX/gh" "$SANDBOX/home" "$SANDBOX/wt"

  cp "$TESTS_DIR/stub-codex.sh" "$SANDBOX/bin/stub-codex"
  cp "$TESTS_DIR/stub-gh.sh" "$SANDBOX/bin/gh"
  chmod +x "$SANDBOX/bin/stub-codex" "$SANDBOX/bin/gh"
  printf 'https://example.com/pr/1\n' > "$SANDBOX/gh/pr-create-url"

  ORIGIN="$SANDBOX/origin.git"
  PROJECT="$SANDBOX/project"
  git init -q --bare "$ORIGIN"
  git init -q -b main "$PROJECT"
  git -C "$PROJECT" remote add origin "$ORIGIN"
  git -C "$PROJECT" config user.email "test@test"
  git -C "$PROJECT" config user.name "spec2pr-test"
  mkdir -p "$PROJECT/docs/superpowers/specs" "$PROJECT/docs/superpowers/plans"
  printf '# toy project\n' > "$PROJECT/README.md"
  git -C "$PROJECT" add -A
  git -C "$PROJECT" commit -qm init
  git -C "$PROJECT" push -q origin main
  # Toy spec stays UNTRACKED in main: mirrors a freshly brainstormed spec and
  # lets tests assert the import commit. (A repo that already tracks the spec
  # in main is handled by the --allow-empty import gate, not this fixture.)
  printf '# Toy spec\n\nAdd a --version flag.\n' > "$PROJECT/docs/superpowers/specs/toy-spec.md"

  SPEC="$PROJECT/docs/superpowers/specs/toy-spec.md"
  ID="project-toy-spec"
  BRANCH="spec2pr/toy-spec"

  export SPEC2PR_TEST_FIXTURES="$SANDBOX/fixtures"
  export SPEC2PR_TEST_GH="$SANDBOX/gh"
  export SPEC2PR_HOME="$SANDBOX/home"
  export SPEC2PR_WORKTREES="$SANDBOX/wt"
  export SPEC2PR_CODEX_BIN="$SANDBOX/bin/stub-codex"
  export PATH="$SANDBOX/bin:$PATH"
}

# Queue a fixture: enqueue <NN-name> <<'EOF' ... EOF
enqueue() {
  cat > "$SPEC2PR_TEST_FIXTURES/$1.sh"
}

# Run the script, capturing combined output and exit code into OUT / RC.
run_spec2pr() {
  set +e
  OUT="$(bash "$SPEC2PR" "$@" 2>&1)"
  RC=$?
  # Leave errexit OFF: run-tests.sh runs under `set -uo pipefail` only, and
  # enabling -e here would abort the whole runner on any failing command
  # instead of recording a FAIL.
}

last_status_line() {
  tail -1 "$SPEC2PR_HOME/$ID.status"
}

codex_calls() {
  if [ -f "$SPEC2PR_TEST_FIXTURES/invocations.log" ]; then
    wc -l < "$SPEC2PR_TEST_FIXTURES/invocations.log" | tr -d ' '
  else
    echo 0
  fi
}
