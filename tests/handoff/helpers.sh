#!/usr/bin/env bash
# Shared test helpers for tests/handoff/. Source from run-tests.sh.

# Test counters (set in run-tests.sh).
TESTS_RUN=${TESTS_RUN:-0}
TESTS_FAILED=${TESTS_FAILED:-0}

# Resolve paths relative to repo root.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"
# Overridable so the suite can be pointed at an older revision of the script
# to confirm these tests actually fail against it.
HANDOFF_SH="${HANDOFF_SH:-$SCRIPTS_DIR/git-commit-handoff.sh}"
DECISION_HITS_SH="${DECISION_HITS_SH:-$SCRIPTS_DIR/handoff-decision-hits.sh}"
PUSH_RECORDS_SH="${PUSH_RECORDS_SH:-$SCRIPTS_DIR/handoff-push-records.sh}"

# Repo with a bare `origin`, one commit on main, then switched to a feature
# branch — the normal shape for record publishing. Echoes the work-tree path;
# pass it to rm_repo_with_origin to clean up the whole fixture.
make_repo_with_origin() {
  local root repo
  root="$(mktemp -d -t handoffremote.XXXXXX)"
  git init -q --bare "$root/origin.git"
  git init -q "$root/work"
  repo="$root/work"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test Runner"
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" checkout -q -b main
  git -C "$repo" remote add origin "$root/origin.git"
  mkdir -p "$repo/scripts"
  printf 'seed\n' > "$repo/scripts/thing.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "seed"
  git -C "$repo" push -q -u origin main
  git -C "$repo" checkout -q -b feature/work
  printf '%s\n' "$repo"
}

rm_repo_with_origin() {
  rm -rf "$(dirname "$1")"
}

# Write a scratch lesson into the working tree. Args: <repo> <slug> [<body>]
write_lesson() {
  local repo="$1" slug="$2" body="${3:-Do the thing.}"
  mkdir -p "$repo/docs/lessons"
  cat > "$repo/docs/lessons/$slug.md" <<EOF
---
slug: $slug
date: 2026-07-28
files: [scripts/thing.sh]
sessions: [test-session]
---

# $slug

## Rule

$body
EOF
}

# Run handoff-push-records.sh with <repo> as cwd. Sets PUSH_OUT and RC.
PUSH_OUT=""
run_push_records() {
  local repo="$1"
  shift
  PUSH_OUT="$(cd "$repo" && bash "$PUSH_RECORDS_SH" "$@" 2>&1)"
  RC=$?
}

# Sorted, space-separated record paths present on <repo>'s origin/<branch>.
stored_records() {
  local repo="$1" branch="${2:-main}"
  git -C "$repo" fetch -q origin "$branch"
  git -C "$repo" ls-tree -r --name-only FETCH_HEAD -- docs LESSONS.md DECISIONS.md \
    2>/dev/null | sort | tr '\n' ' '
}

# Fresh git repo with one commit and deliberately NO upstream, so the script's
# push step short-circuits on "No upstream set" and never touches a network.
make_temp_repo() {
  local tmp
  tmp="$(mktemp -d -t handofftest.XXXXXX)"
  git -C "$tmp" init -q .
  git -C "$tmp" config user.email "test@example.com"
  git -C "$tmp" config user.name "Test Runner"
  git -C "$tmp" config commit.gpgsign false
  printf 'seed\n' > "$tmp/seed.txt"
  git -C "$tmp" add seed.txt
  git -C "$tmp" commit -q -m "seed"

  # Passthrough `rtk` stub so results don't depend on whether the real RTK
  # proxy is installed on the machine running the suite.
  mkdir -p "$tmp/.stubbin"
  cat > "$tmp/.stubbin/rtk" <<'STUB'
#!/usr/bin/env bash
exec "$@"
STUB
  chmod +x "$tmp/.stubbin/rtk"

  printf '%s\n' "$tmp"
}

# Write a minimal HANDOFF.md. Args: <repo> [<task line>]
write_handoff() {
  local repo="$1"
  local task="${2:-do a thing}"
  cat > "$repo/HANDOFF.md" <<EOF
# Handoff

## Task
$task

## Current State
mid-flight
EOF
}

# Write a record file. Args: <repo> <lessons|decisions> <slug>
write_record() {
  local repo="$1" kind="$2" slug="$3"
  mkdir -p "$repo/docs/$kind"
  cat > "$repo/docs/$kind/$slug.md" <<EOF
---
slug: $slug
date: 2026-07-28
status: held
files: [scripts/thing.sh]
sessions: [test-session]
---

# $slug

## Rule

Do the thing.
EOF
}

# Run the script with <repo> as cwd. Sets globals HANDOFF_OUT and RC.
# Deliberately not echoing to stdout: callers would have to capture it with
# `$(...)`, which runs this in a subshell and strands RC there.
HANDOFF_OUT=""
RC=0
run_handoff() {
  local repo="$1"
  HANDOFF_OUT="$(cd "$repo" && PATH="$repo/.stubbin:$PATH" bash "$HANDOFF_SH" 2>&1)"
  RC=$?
}

# Write a decision record whose `files:` names <path>. Args: <repo> <slug> <path>
write_decision_for() {
  local repo="$1" slug="$2" path="$3"
  mkdir -p "$repo/docs/decisions"
  cat > "$repo/docs/decisions/$slug.md" <<EOF
---
slug: $slug
date: 2026-07-28
status: held
files: [$path]
sessions: [test-session]
---

# $slug

## Rule

Keep doing it this way.
EOF
}

# Run handoff-decision-hits.sh with <repo> as cwd. Sets HITS_OUT and RC.
HITS_OUT=""
run_decision_hits() {
  local repo="$1"
  shift
  HITS_OUT="$(cd "$repo" && bash "$DECISION_HITS_SH" "$@" 2>&1)"
  RC=$?
}

# Space-separated, sorted list of files touched by the most recent commit.
committed_files() {
  git -C "$1" show --name-only --format= HEAD | grep -v '^[[:space:]]*$' | sort | tr '\n' ' '
}

# Subject line of the most recent commit.
commit_subject() {
  git -C "$1" log -1 --format=%s
}

# Number of commits on the current branch.
commit_count() {
  git -C "$1" rev-list --count HEAD
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
  local haystack="$1"
  local needle="$2"
  local msg="${3:-should contain: $needle}"
  TESTS_RUN=$((TESTS_RUN + 1))
  case "$haystack" in
    *"$needle"*) printf '  ok: %s\n' "$msg" ;;
    *)
      TESTS_FAILED=$((TESTS_FAILED + 1))
      printf '  FAIL: %s\n    haystack: %s\n' "$msg" "$haystack"
      ;;
  esac
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="${3:-should not contain: $needle}"
  TESTS_RUN=$((TESTS_RUN + 1))
  case "$haystack" in
    *"$needle"*)
      TESTS_FAILED=$((TESTS_FAILED + 1))
      printf '  FAIL: %s\n    haystack: %s\n' "$msg" "$haystack"
      ;;
    *) printf '  ok: %s\n' "$msg" ;;
  esac
}
