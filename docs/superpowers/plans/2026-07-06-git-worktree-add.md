# git-worktree-add.sh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `git worktree add` wrapper that always places worktrees under project-root `.worktrees/` (kept gitignored), plus a RULEZ.md rule to prefer it.

**Architecture:** One self-contained bash script (`scripts/git-worktree-add.sh`) anchored on `git rev-parse --git-common-dir` so it never nests worktrees; a sandbox test suite under `tests/worktree/` mirroring the `tests/spec2pr/` harness shape; a RULEZ.md `## Worktrees` section; and one `.gitignore` line so this repo dogfoods the rule.

**Tech Stack:** Bash, git worktrees, the repo's existing per-directory `run-tests.sh`/`helpers.sh` test convention.

## Global Constraints

- **Stage by EXACT path only — never `git add .` or `git add -A`.** These untracked paths must NEVER be staged: `references/`, `tmp/`, `docs/research-auto-handoff-at-context-threshold.md`, `docs/superpowers/specs/2026-06-29-spec2pr-chain-design.md`, `docs/superpowers/specs/2026-06-30-spec2pr-implementer-switch-design.md`.
- **Commit trailer is a single line:** `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` — no `Claude-Session:` line.
- **Do NOT touch `VERSION` or `UPGRADE.md`** — the version bump is a separate release step.
- **Placement:** worktrees go under `<main-repo-root>/.worktrees/<branch>`, where main-repo-root is derived from `git rev-parse --git-common-dir` (NOT `--show-toplevel`), so running from inside a worktree never nests.
- **Base ref default is `HEAD`** (native `git worktree add -b` behavior); a base only applies when creating a NEW branch.
- **Output contract:** narration to **stderr**; the worktree's absolute path is the **only** stdout line.
- **No `set-current-command.sh` call** — this is not a slash-command script.
- **RTK proxy shim** header line, verbatim: `if command -v rtk &>/dev/null; then rtk() { command rtk "$@"; }; else rtk() { "$@"; }; fi`
- New scripts are executable (`chmod +x`; tracked as mode `100755`).

---

### Task 1: Wrapper script + sandbox test suite

**Files:**
- Create: `tests/worktree/helpers.sh`
- Create: `tests/worktree/run-tests.sh`
- Create: `tests/worktree/test-worktree-add.sh`
- Create: `scripts/git-worktree-add.sh`

**Interfaces:**
- Produces: `scripts/git-worktree-add.sh <branch> [<base>]` — prints the new worktree's absolute path on stdout (single line); narration on stderr; exit 0 on success, 1 on usage error / not-a-repo / failed `git worktree add`.
- Produces (test harness): `tests/worktree/helpers.sh` exposing `assert_eq`, `assert_contains`, `assert_file_exists`, `install_passthrough_rtk`, and `make_repo` (sets globals `SANDBOX`, `ORIGIN`, `PROJECT`, `PROJECT_REAL`, and the `WORKTREE_ADD` path).

- [ ] **Step 1: Create the test harness — `tests/worktree/helpers.sh`**

```bash
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
```

- [ ] **Step 2: Create the runner — `tests/worktree/run-tests.sh`**

Identical auto-discovery loop to `tests/spec2pr/run-tests.sh`.

```bash
set -uo pipefail

TESTS_RUN=0
TESTS_FAILED=0

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/helpers.sh"

for f in "$DIR"/test-*.sh; do
  [ -f "$f" ] || continue
  source "$f"
done

for fn in $(declare -F | awk '{print $3}' | grep '^test_' || true); do
  printf '%s\n' "$fn"
  "$fn"
done

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
```

- [ ] **Step 3: Create the failing tests — `tests/worktree/test-worktree-add.sh`**

```bash
#!/usr/bin/env bash

# Run the wrapper inside <dir> with the given args. Captures:
#   WT_PATH = stdout (the worktree path, single line)
#   WT_ERR  = stderr (narration)
#   WT_RC   = exit code
run_wta() {
  local dir="$1"; shift
  local errfile; errfile="$(mktemp)"
  WT_PATH="$(cd "$dir" && bash "$WORKTREE_ADD" "$@" 2>"$errfile")"
  WT_RC=$?
  WT_ERR="$(cat "$errfile")"
  rm -f "$errfile"
}

test_worktree_add_new_branch() {
  make_repo
  run_wta "$PROJECT" feature/foo
  assert_eq "0" "$WT_RC" "new branch: exits 0"
  assert_eq "$PROJECT_REAL/.worktrees/feature/foo" "$WT_PATH" \
    "new branch: path is project-root .worktrees/<branch>"
  assert_file_exists "$WT_PATH" "new branch: worktree dir exists"
  assert_eq "feature/foo" "$(git -C "$WT_PATH" branch --show-current)" \
    "new branch: worktree is on feature/foo"
}

test_worktree_add_existing_local_branch() {
  make_repo
  git -C "$PROJECT" branch existing-local
  run_wta "$PROJECT" existing-local
  assert_eq "0" "$WT_RC" "existing local: exits 0"
  assert_eq "existing-local" "$(git -C "$WT_PATH" branch --show-current)" \
    "existing local: worktree is on that branch"
}

test_worktree_add_remote_only_branch() {
  make_repo
  git -C "$PROJECT" branch remote-feature
  git -C "$PROJECT" push -q origin remote-feature
  git -C "$PROJECT" branch -D remote-feature
  git -C "$PROJECT" fetch -q origin
  run_wta "$PROJECT" remote-feature
  assert_eq "0" "$WT_RC" "remote-only: exits 0"
  assert_eq "remote-feature" "$(git -C "$WT_PATH" branch --show-current)" \
    "remote-only: worktree tracks the origin branch"
}

test_worktree_add_gitignores_without_commit() {
  make_repo
  rm -f "$PROJECT/.gitignore"
  run_wta "$PROJECT" feature/ig
  assert_eq "0" "$WT_RC" "gitignore: exits 0"
  assert_file_exists "$PROJECT/.gitignore" "gitignore: .gitignore created"
  assert_contains "$(cat "$PROJECT/.gitignore")" ".worktrees/" \
    "gitignore: contains .worktrees/"
  assert_contains "$(git -C "$PROJECT" status --porcelain -- .gitignore)" ".gitignore" \
    "gitignore: left uncommitted (shows in git status)"
}

test_worktree_add_anchors_at_main_root_from_inside_worktree() {
  make_repo
  run_wta "$PROJECT" feature/first
  assert_eq "0" "$WT_RC" "anchor: first worktree created"
  local first="$WT_PATH"
  run_wta "$first" feature/second
  assert_eq "0" "$WT_RC" "anchor: second worktree created from inside first"
  assert_eq "$PROJECT_REAL/.worktrees/feature/second" "$WT_PATH" \
    "anchor: lands at main root, not nested inside the first worktree"
}

test_worktree_add_respects_base_ref() {
  make_repo
  local base_sha; base_sha="$(git -C "$PROJECT" rev-parse HEAD)"
  printf 'second\n' >> "$PROJECT/README.md"
  git -C "$PROJECT" commit -qam second
  run_wta "$PROJECT" feature/frombase "$base_sha"
  assert_eq "0" "$WT_RC" "base: exits 0"
  assert_eq "$base_sha" "$(git -C "$WT_PATH" rev-parse HEAD)" \
    "base: new branch forks from the given base ref"
}
```

- [ ] **Step 4: Run the tests to verify they FAIL**

Run: `bash tests/worktree/run-tests.sh`
Expected: FAIL — `scripts/git-worktree-add.sh` does not exist yet, so `bash "$WORKTREE_ADD"` errors (exit 127, empty `WT_PATH`); assertions report failures and the final line shows a non-zero failed count. Confirms the tests exercise real behavior.

- [ ] **Step 5: Implement the wrapper — `scripts/git-worktree-add.sh`**

```bash
#!/usr/bin/env bash
# git-worktree-add.sh — create a git worktree under the project-root .worktrees/
# directory (kept gitignored), instead of an arbitrary path.
#
# Usage: git-worktree-add.sh <branch> [<base>]
#   <branch>  branch to check out in the new worktree. Created if it does not
#             exist (as a local or origin/ branch); checked out if it does.
#   <base>    optional base ref for a NEW branch (default: HEAD). Ignored when
#             <branch> already exists.
#
# Narration goes to stderr; the worktree's absolute path is the only stdout
# line, so this works:  cd "$(git-worktree-add.sh feature/foo)"
set -euo pipefail

if command -v rtk &>/dev/null; then rtk() { command rtk "$@"; }; else rtk() { "$@"; }; fi

BRANCH="${1:-}"
BASE="${2:-}"

if [ -z "$BRANCH" ]; then
  echo "usage: git-worktree-add.sh <branch> [<base>]" >&2
  exit 1
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "error: not inside a git repository" >&2
  exit 1
fi

# Anchor at the MAIN repo root (not the current worktree) so that running this
# from inside a worktree still lands the new one at the top level, never nested.
COMMON="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
MAIN_ROOT="$(dirname "$COMMON")"
WORKTREES_DIR="$MAIN_ROOT/.worktrees"
TARGET="$WORKTREES_DIR/$BRANCH"

# Ensure .worktrees/ is gitignored. The ignore takes effect immediately, so we
# do NOT commit (honors "commit only when asked").
if ! git -C "$MAIN_ROOT" check-ignore -q .worktrees; then
  printf '.worktrees/\n' >> "$MAIN_ROOT/.gitignore"
  echo "note: added .worktrees/ to $MAIN_ROOT/.gitignore (uncommitted)" >&2
fi

# Resolve the branch (existing local, existing remote, or new), mirroring
# git-start-issue.sh's order. Build the argument list for git worktree add.
add_args=()
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  if [ -n "$BASE" ]; then
    echo "warning: branch '$BRANCH' already exists; ignoring base '$BASE'" >&2
  fi
  add_args=("$TARGET" "$BRANCH")
elif git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  if [ -n "$BASE" ]; then
    echo "warning: branch 'origin/$BRANCH' already exists; ignoring base '$BASE'" >&2
  fi
  add_args=(--track -b "$BRANCH" "$TARGET" "origin/$BRANCH")
else
  if [ -n "$BASE" ]; then
    add_args=(-b "$BRANCH" "$TARGET" "$BASE")
  else
    add_args=(-b "$BRANCH" "$TARGET")
  fi
fi

# Run once; send git's own progress to stderr so stdout carries only the path.
if ! rtk git worktree add "${add_args[@]}" >&2; then
  echo "error: 'git worktree add' failed — target may exist or the branch is checked out in another worktree" >&2
  exit 1
fi

echo "worktree ready: branch '$BRANCH' at $TARGET" >&2
printf '%s\n' "$TARGET"
```

Then make it executable:

```bash
chmod +x scripts/git-worktree-add.sh
```

- [ ] **Step 6: Run the tests to verify they PASS**

Run: `bash tests/worktree/run-tests.sh`
Expected: PASS — final line `N tests run, 0 failed` (N is the total assertion count across the 6 `test_*` functions), and the runner exits 0.

- [ ] **Step 7: Commit**

Stage only these exact paths (never `git add .`):

```bash
git add scripts/git-worktree-add.sh tests/worktree/helpers.sh tests/worktree/run-tests.sh tests/worktree/test-worktree-add.sh
git commit -m "feat: git-worktree-add.sh — project-root .worktrees/ wrapper + tests

Wrap git worktree add so worktrees land under <main-root>/.worktrees/
(kept gitignored), anchored on git-common-dir so runs from inside a
worktree never nest. Branch-first interface mirrors git-start-issue.sh.
Sandbox tests under tests/worktree/.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: RULEZ.md rule + repo .gitignore

**Files:**
- Modify: `RULEZ.md` (append a `## Worktrees` section after `## Tone`)
- Modify: `.gitignore` (append `.worktrees/`)

**Interfaces:**
- Consumes: the wrapper path `~/.claude/skills/rulez-claudeset/scripts/git-worktree-add.sh` produced by Task 1.
- Produces: nothing other tasks depend on.

- [ ] **Step 1: Append the `## Worktrees` section to `RULEZ.md`**

Add exactly this block at the end of `RULEZ.md`, after the `## Tone` section:

```markdown

## Worktrees

Need a git worktree? Run

    ~/.claude/skills/rulez-claudeset/scripts/git-worktree-add.sh <branch> [<base>]

instead of `git worktree add`. It anchors the worktree under `.worktrees/` at
the project root (creating and gitignoring that directory if needed) and prints
the new worktree path on stdout. A native worktree tool (e.g. EnterWorktree)
still wins when one is available.
```

- [ ] **Step 2: Verify the RULEZ.md edit**

Run: `grep -n "git-worktree-add.sh" RULEZ.md`
Expected: one match, inside the `## Worktrees` section.

- [ ] **Step 3: Add `.worktrees/` to this repo's `.gitignore`**

Append a single line `.worktrees/` to the existing root `.gitignore` (which currently ends with `legacy/`). Final file:

```
.claude/
.last-update
.update-lock
.updated-marker
legacy/
.worktrees/
```

- [ ] **Step 4: Verify the ignore is effective**

Run: `git check-ignore .worktrees`
Expected: prints `.worktrees` (exit 0 — the path is ignored).

- [ ] **Step 5: Commit**

Stage only these exact paths:

```bash
git add RULEZ.md .gitignore
git commit -m "docs: RULEZ.md worktree rule + gitignore .worktrees/

Tell agents to prefer git-worktree-add.sh over raw \`git worktree add\`,
and dogfood the convention by ignoring .worktrees/ in this repo.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage:**
- Wrapper behavior (args, repo guard, main-root anchor, gitignore-no-commit, branch resolution, base default, error surfacing, stdout/stderr contract) → Task 1, Step 5. ✅
- `RULEZ.md` `## Worktrees` section → Task 2, Step 1. ✅
- `tests/worktree/` harness + all six test bullets (new / existing-local / remote-only / gitignore-not-committed / anchoring / base ref) → Task 1, Steps 1–3. ✅
- Repo `.gitignore` dogfood line → Task 2, Step 3. ✅
- VERSION/UPGRADE.md untouched → not in any task; Global Constraints forbids it. ✅
- Out-of-scope items (spec2pr unification, remove wrapper, extra flags) → correctly absent. ✅

**2. Placeholder scan:** No TBD/TODO; every code step carries complete content. ✅

**3. Type/name consistency:** `WORKTREE_ADD`, `PROJECT_REAL`, `make_repo`, `run_wta`, and the `.worktrees/feature/<n>` paths are used identically in the harness (Step 1), tests (Step 3), and assertions. The wrapper's stdout-only-path contract matches how `run_wta` captures `WT_PATH`. ✅
