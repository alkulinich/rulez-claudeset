#!/usr/bin/env bash
# Shared test helpers for tests/worktree/. Source from run-tests.sh.

TESTS_RUN=${TESTS_RUN:-0}
TESTS_FAILED=${TESTS_FAILED:-0}

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
WORKTREE_ADD="$REPO_ROOT/scripts/git-worktree-add.sh"

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
    printf '  FAIL: %s\n    haystack: %s\n' "$msg" "$haystack"
  fi
}

assert_file_exists() {
  local path="$1" msg="${2:-should exist: $1}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ -e "$path" ]; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n' "$msg"
  fi
}

# Passthrough rtk stub on PATH so the wrapper's `rtk` shim resolves in tests.
install_passthrough_rtk() {
  cat > "$SANDBOX/bin/rtk" <<'EOF'
#!/usr/bin/env bash
"$@"
EOF
  chmod +x "$SANDBOX/bin/rtk"
}

# Fresh scratch repo with a bare origin and one commit on main. Sets globals:
#   SANDBOX, ORIGIN, PROJECT, PROJECT_REAL (symlink-resolved project path)
make_repo() {
  SANDBOX="$(mktemp -d -t worktree-test.XXXXXX)"
  mkdir -p "$SANDBOX/bin"
  install_passthrough_rtk
  export PATH="$SANDBOX/bin:$PATH"

  ORIGIN="$SANDBOX/origin.git"
  PROJECT="$SANDBOX/project"
  git init -q --bare "$ORIGIN"
  git init -q -b main "$PROJECT"
  git -C "$PROJECT" remote add origin "$ORIGIN"
  git -C "$PROJECT" config user.email "test@test"
  git -C "$PROJECT" config user.name "worktree-test"
  printf '# toy\n' > "$PROJECT/README.md"
  git -C "$PROJECT" add -A
  git -C "$PROJECT" commit -qm init
  git -C "$PROJECT" push -q origin main
  # macOS mktemp lives under /var -> /private/var; the wrapper canonicalizes via
  # `pwd -P`, so tests must compare against the resolved path too.
  PROJECT_REAL="$(cd "$PROJECT" && pwd -P)"
}
