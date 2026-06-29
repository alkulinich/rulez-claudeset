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

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-output should NOT contain: $2}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    unexpectedly contained: %s\n' "$msg" "$needle"
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
  mkdir -p "$SANDBOX/bin" "$SANDBOX/fixtures" "$SANDBOX/claude-fixtures" "$SANDBOX/gh" "$SANDBOX/home" "$SANDBOX/wt"
  export HOME="$SANDBOX/home"

  cp "$TESTS_DIR/stub-codex.sh" "$SANDBOX/bin/stub-codex"
  cp "$TESTS_DIR/stub-claude.sh" "$SANDBOX/bin/stub-claude"
  cp "$TESTS_DIR/stub-gh.sh" "$SANDBOX/bin/gh"
  chmod +x "$SANDBOX/bin/stub-codex" "$SANDBOX/bin/stub-claude" "$SANDBOX/bin/gh"
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
  export SPEC2PR_TEST_CLAUDE_FIXTURES="$SANDBOX/claude-fixtures"
  export SPEC2PR_TEST_GH="$SANDBOX/gh"
  export SPEC2PR_HOME="$SANDBOX/home"
  export SPEC2PR_WORKTREES="$SANDBOX/wt"
  export SPEC2PR_CODEX_BIN="$SANDBOX/bin/stub-codex"
  export SPEC2PR_CLAUDE_BIN="$SANDBOX/bin/stub-claude"
  # Publish-on-halt is ON in production; keep it OFF by default in the harness so
  # existing halt tests don't push to the sandbox origin. The dedicated
  # test-publish-on-halt.sh cases opt in with SPEC2PR_PUBLISH_ON_HALT=1.
  export SPEC2PR_PUBLISH_ON_HALT=0
  export PATH="$SANDBOX/bin:$PATH"
}

# Queue a fixture: enqueue <NN-name> <<'EOF' ... EOF
enqueue() {
  cat > "$SPEC2PR_TEST_FIXTURES/$1.sh"
}

enqueue_claude() {
  cat > "$SPEC2PR_TEST_CLAUDE_FIXTURES/$1.sh"
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

claude_calls() {
  if [ -f "$SPEC2PR_TEST_CLAUDE_FIXTURES/invocations.log" ]; then
    wc -l < "$SPEC2PR_TEST_CLAUDE_FIXTURES/invocations.log" | tr -d ' '
  else
    echo 0
  fi
}

# Queue a claude forecast fixture returning a "fits" verdict whose
# plan_sha256/spec_sha256 match the worktree's committed plan/spec files.
# (Test plan/spec paths are fixed by the toy fixture.)
queue_clean_forecast() {
  enqueue_claude "$1" <<'EOF'
plan_sha="$(sha256sum docs/superpowers/plans/toy-spec-plan.md | awk '{print $1}')"
spec_sha="$(sha256sum docs/superpowers/specs/toy-spec.md | awk '{print $1}')"
base_sha="$(git merge-base origin/main HEAD)"
cur_bytes="$(git diff "$base_sha...HEAD" | wc -c | tr -d ' ')"
est=$((cur_bytes + 40))
printf '{"result":{"plan_sha256":"%s","spec_sha256":"%s","current_diff_bytes":%s,"files":[{"path":"version.txt","loc":1}],"total_loc":1,"implementation_est_bytes":40,"est_bytes":%s,"verdict":"fits"}}' \
  "$plan_sha" "$spec_sha" "$cur_bytes" "$est"
EOF
}

# Queue a claude forecast fixture returning an "exceeds" verdict with parts.
queue_exceeds_forecast() {
  enqueue_claude "$1" <<'EOF'
plan_sha="$(sha256sum docs/superpowers/plans/toy-spec-plan.md | awk '{print $1}')"
spec_sha="$(sha256sum docs/superpowers/specs/toy-spec.md | awk '{print $1}')"
base_sha="$(git merge-base origin/main HEAD)"
cur_bytes="$(git diff "$base_sha...HEAD" | wc -c | tr -d ' ')"
total_loc=4000
impl_bytes=$((total_loc * 40))
est=$((cur_bytes + impl_bytes))
printf '{"result":{"plan_sha256":"%s","spec_sha256":"%s","current_diff_bytes":%s,"files":[{"path":"big.ts","loc":%s}],"total_loc":%s,"implementation_est_bytes":%s,"est_bytes":%s,"verdict":"exceeds","summary":"Forecast exceeds diff limit. Recommended split: part-1 helpers; part-2 wiring + tests.","parts":["part-1: helpers + types","part-2: wiring + tests"]}}' \
  "$plan_sha" "$spec_sha" "$cur_bytes" "$total_loc" "$total_loc" "$impl_bytes" "$est"
EOF
}
