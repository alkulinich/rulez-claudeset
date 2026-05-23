# Codex `rulez-tools` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Codex skill named `rulez-tools` that exposes the Rulez GitHub workflow and handoff scripts through Codex skills.

**Architecture:** Keep the existing Claude layout untouched. Add a Codex adapter under `adapters/codex/skills/rulez-tools/`, plus a `bin/setup-codex` installer that symlinks the skill into `~/.codex/skills/rulez-tools`. Add shell tests for installer idempotence, collision handling, and skill frontmatter.

**Tech Stack:** Bash, POSIX-style shell tests, Codex `SKILL.md` frontmatter, existing Rulez shell scripts.

---

## File Structure

- Create `bin/setup-codex` - Codex-only installer. Resolves repo root, validates the skill source, creates `~/.codex/skills`, and symlinks `rulez-tools`.
- Create `adapters/codex/skills/rulez-tools/SKILL.md` - Codex skill instructions for the first-pass GitHub workflow and handoff commands.
- Create `tests/codex/helpers.sh` - Small shared assertions and temp-home helpers for Codex installer tests.
- Create `tests/codex/test-setup-codex.sh` - Tests for symlink creation, idempotence, refusal to overwrite real files/directories, and frontmatter validation.
- Create `tests/codex/run-tests.sh` - Test runner matching the existing `tests/punts` and `tests/what-have-i-done` pattern.
- Modify `README.md` - Add a concise Codex install section and mention `rulez-tools` in the command/tooling overview.

## Task 1: Add Failing Codex Installer Tests

**Files:**
- Create: `tests/codex/helpers.sh`
- Create: `tests/codex/test-setup-codex.sh`
- Create: `tests/codex/run-tests.sh`

- [ ] **Step 1: Create `tests/codex/helpers.sh`**

Create the file with this content:

```bash
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
```

- [ ] **Step 2: Create `tests/codex/test-setup-codex.sh`**

Create the file with this content:

```bash
#!/usr/bin/env bash

test_setup_codex_creates_rulez_tools_symlink() {
  local temp_home skill_src skill_dst output
  temp_home="$(make_temp_home)"
  skill_src="$REPO_ROOT/adapters/codex/skills/rulez-tools"
  skill_dst="$temp_home/.codex/skills/rulez-tools"

  output="$(HOME="$temp_home" bash "$REPO_ROOT/bin/setup-codex")"

  assert_symlink_target "$skill_dst" "$skill_src" "setup-codex installs rulez-tools symlink"
  assert_contains "Installed Codex skill: rulez-tools" "$output" "setup-codex prints success message"
}

test_setup_codex_is_idempotent_for_existing_symlink() {
  local temp_home skill_src skill_dst
  temp_home="$(make_temp_home)"
  skill_src="$REPO_ROOT/adapters/codex/skills/rulez-tools"
  skill_dst="$temp_home/.codex/skills/rulez-tools"

  HOME="$temp_home" bash "$REPO_ROOT/bin/setup-codex" >/dev/null
  HOME="$temp_home" bash "$REPO_ROOT/bin/setup-codex" >/dev/null

  assert_symlink_target "$skill_dst" "$skill_src" "setup-codex can be re-run"
}

test_setup_codex_replaces_broken_symlink() {
  local temp_home skill_src skill_dst
  temp_home="$(make_temp_home)"
  skill_src="$REPO_ROOT/adapters/codex/skills/rulez-tools"
  skill_dst="$temp_home/.codex/skills/rulez-tools"

  mkdir -p "$temp_home/.codex/skills"
  ln -s "$temp_home/missing-target" "$skill_dst"

  HOME="$temp_home" bash "$REPO_ROOT/bin/setup-codex" >/dev/null

  assert_symlink_target "$skill_dst" "$skill_src" "setup-codex replaces broken symlink"
}

test_setup_codex_refuses_to_overwrite_real_directory() {
  local temp_home skill_dst output status
  temp_home="$(make_temp_home)"
  skill_dst="$temp_home/.codex/skills/rulez-tools"

  mkdir -p "$skill_dst"

  set +e
  output="$(HOME="$temp_home" bash "$REPO_ROOT/bin/setup-codex" 2>&1)"
  status=$?
  set -e

  assert_eq "1" "$status" "setup-codex fails when destination is a real directory"
  assert_contains "Refusing to overwrite non-symlink" "$output" "setup-codex explains real-directory collision"
}

test_setup_codex_refuses_to_overwrite_real_file() {
  local temp_home skill_dst output status
  temp_home="$(make_temp_home)"
  skill_dst="$temp_home/.codex/skills/rulez-tools"

  mkdir -p "$(dirname "$skill_dst")"
  printf 'local file\n' > "$skill_dst"

  set +e
  output="$(HOME="$temp_home" bash "$REPO_ROOT/bin/setup-codex" 2>&1)"
  status=$?
  set -e

  assert_eq "1" "$status" "setup-codex fails when destination is a real file"
  assert_contains "Refusing to overwrite non-symlink" "$output" "setup-codex explains real-file collision"
}

test_rulez_tools_skill_frontmatter_is_valid() {
  local skill_file
  skill_file="$REPO_ROOT/adapters/codex/skills/rulez-tools/SKILL.md"

  assert_eq "---" "$(sed -n '1p' "$skill_file")" "skill frontmatter opens"
  assert_eq "name: rulez-tools" "$(sed -n '2p' "$skill_file")" "skill name is rulez-tools"
  assert_contains "description: Use for Rulez shared tooling in Codex" "$(sed -n '3p' "$skill_file")" "skill has useful description"
  assert_eq "---" "$(sed -n '4p' "$skill_file")" "skill frontmatter closes"
}
```

- [ ] **Step 3: Create `tests/codex/run-tests.sh`**

Create the file with this content:

```bash
#!/usr/bin/env bash
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

- [ ] **Step 4: Make the runner executable**

Run:

```bash
chmod +x tests/codex/run-tests.sh
```

Expected: no output.

- [ ] **Step 5: Run the new tests and verify they fail**

Run:

```bash
tests/codex/run-tests.sh
```

Expected: FAIL output because `bin/setup-codex` and `adapters/codex/skills/rulez-tools/SKILL.md` do not exist yet. The command should exit non-zero.

- [ ] **Step 6: Commit the failing tests**

Run:

```bash
git add tests/codex
git commit -m "test: add Codex setup coverage"
```

## Task 2: Implement `bin/setup-codex`

**Files:**
- Create: `bin/setup-codex`

- [ ] **Step 1: Create `bin/setup-codex`**

Create the file with this content:

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CODEX_DIR="${CODEX_DIR:-$HOME/.codex}"
SKILLS_DIR="$CODEX_DIR/skills"
SKILL_NAME="rulez-tools"
SKILL_SRC="$REPO_ROOT/adapters/codex/skills/$SKILL_NAME"
SKILL_DST="$SKILLS_DIR/$SKILL_NAME"

if [ ! -d "$SKILL_SRC" ]; then
  printf 'Error: missing Codex skill source: %s\n' "$SKILL_SRC" >&2
  exit 1
fi

mkdir -p "$SKILLS_DIR"

if [ -L "$SKILL_DST" ]; then
  rm "$SKILL_DST"
elif [ -e "$SKILL_DST" ]; then
  printf 'Error: Refusing to overwrite non-symlink: %s\n' "$SKILL_DST" >&2
  exit 1
fi

ln -sfn "$SKILL_SRC" "$SKILL_DST"

printf 'Installed Codex skill: %s\n' "$SKILL_NAME"
printf '  %s -> %s\n' "$SKILL_DST" "$SKILL_SRC"
```

- [ ] **Step 2: Make the installer executable**

Run:

```bash
chmod +x bin/setup-codex
```

Expected: no output.

- [ ] **Step 3: Run syntax check**

Run:

```bash
bash -n bin/setup-codex
```

Expected: no output and exit 0.

- [ ] **Step 4: Run Codex tests and verify remaining failure is only missing skill**

Run:

```bash
tests/codex/run-tests.sh
```

Expected: tests still fail because `adapters/codex/skills/rulez-tools/SKILL.md` has not been created. Installer collision behavior should be ready once the source directory exists.

- [ ] **Step 5: Commit the installer**

Run:

```bash
git add bin/setup-codex
git commit -m "feat: add Codex setup installer"
```

## Task 3: Add The `rulez-tools` Codex Skill

**Files:**
- Create: `adapters/codex/skills/rulez-tools/SKILL.md`

- [ ] **Step 1: Create the skill directory**

Run:

```bash
mkdir -p adapters/codex/skills/rulez-tools
```

Expected: no output.

- [ ] **Step 2: Create `adapters/codex/skills/rulez-tools/SKILL.md`**

Create the file with this content:

````markdown
---
name: rulez-tools
description: Use for Rulez shared tooling in Codex: GitHub workflow commands, handoffs, and future rulez workflows backed by this repository's scripts.
---

# Rulez Tools

Use this skill when the user asks Codex to use `rulez-tools`, or asks for Rulez-style GitHub workflow tasks such as starting an issue, creating a PR, testing a PR, pushing fixes, merging a PR, or writing a handoff.

## Repository Layout

This skill is installed as a symlink from:

```text
~/.codex/skills/rulez-tools
```

to:

```text
<rulez-claudeset-repo>/adapters/codex/skills/rulez-tools
```

Resolve the shared repository root from this skill file before running scripts:

```bash
RULEZ_HOME="$(cd "<directory-containing-this-SKILL.md>/../../../.." && pwd)"
```

When working inside this repository, `RULEZ_HOME` is the repo root. In normal Codex use, infer the same root from the installed skill location.

## Shared Scripts

Prefer the shared scripts over reimplementing workflow logic:

- Start issue: `scripts/git-start-issue.sh <issue-number> [branch-name]`
- Create PR: `scripts/git-create-pr.sh`
- Test PR: `scripts/git-test-pr.sh <pr-number>`
- Push fixes: `scripts/git-push-fixes.sh`
- Merge PR: `scripts/git-merge-pr.sh <pr-number>`
- Handoff: `scripts/git-commit-handoff.sh`

Run these scripts by absolute path from the target project workspace. The Git workflow scripts operate on the current working directory.

## Codex Workflow Rules

- Inspect `git status --short` before workflows that create commits, push branches, open PRs, or merge PRs.
- Inspect the relevant diff before creating a PR, pushing fixes, or writing a handoff.
- Follow Codex sandbox and approval behavior. Do not assume Claude permissions from `settings.json`.
- Do not rely on Claude-only tool names such as `AskUserQuestion`, `Agent`, `Write`, `TodoWrite`, or `EnterPlanMode`.
- Edit files using Codex-native rules. For manual repo edits, prefer `apply_patch`.
- Use Codex subagents only when the user explicitly asks for subagents, delegation, or parallel agent work.
- Treat `RULEZ.md` as shared behavioral guidance.
- Treat `CLAUDE.md` as Claude-specific unless a rule is clearly tool-agnostic.

## Command Mapping

When the user says `use rulez-tools to start issue 123`:

1. Check the current repo status.
2. From the target project workspace, run `"$RULEZ_HOME/scripts/git-start-issue.sh" 123`.
3. Summarize the issue title, branch, and any warnings or failures.

When the user says `use rulez-tools to create PR`:

1. Check status and diff.
2. Ensure the branch and changes are appropriate for a PR.
3. From the target project workspace, run `"$RULEZ_HOME/scripts/git-create-pr.sh"`.
4. Report the PR URL or the blocking error.

When the user says `use rulez-tools to test PR 5`:

1. From the target project workspace, run `"$RULEZ_HOME/scripts/git-test-pr.sh" 5`.
2. Follow the script output and run any project-specific verification it requests.
3. Report failures first, then passing checks.

When the user says `use rulez-tools to push fixes`:

1. Check status and diff.
2. Confirm the changes belong to the current PR or branch.
3. From the target project workspace, run `"$RULEZ_HOME/scripts/git-push-fixes.sh"`.
4. Report the pushed branch or any blocker.

When the user says `use rulez-tools to merge PR 5`:

1. Check whether the working tree has unrelated local changes.
2. From the target project workspace, run `"$RULEZ_HOME/scripts/git-merge-pr.sh" 5`.
3. Report the merge result and cleanup status.

When the user says `use rulez-tools to write handoff`:

1. Inspect status, recent commits, and relevant context.
2. From the target project workspace, run `"$RULEZ_HOME/scripts/git-commit-handoff.sh"`.
3. Report the committed handoff or any missing information needed to write it.

## First-Pass Scope

This skill currently covers GitHub workflow and handoff commands only. It does not install or manage Codex hooks, statusline behavior, punts, `what-have-i-done`, or Claude transcript/session storage.
````

- [ ] **Step 3: Run syntax and tests**

Run:

```bash
bash -n bin/setup-codex
tests/codex/run-tests.sh
```

Expected: `bash -n` exits 0. Codex tests pass with `6 tests run, 0 failed`.

- [ ] **Step 4: Commit the skill**

Run:

```bash
git add adapters/codex/skills/rulez-tools/SKILL.md
git commit -m "feat: add rulez-tools Codex skill"
```

## Task 4: Document Codex Installation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a Codex install section after the global Claude install section**

In `README.md`, after the "Install (global)" section and before "Install (per-project)", add:

````markdown
## Install (Codex)

Install the same repository as a Codex skill source and run the Codex adapter
installer:

```bash
git clone https://github.com/alkulinich/rulez-claudeset ~/.codex/skills/rulez-claudeset
cd ~/.codex/skills/rulez-claudeset && ./bin/setup-codex
```

This symlinks the Codex skill:

```text
~/.codex/skills/rulez-tools -> ~/.codex/skills/rulez-claudeset/adapters/codex/skills/rulez-tools
```

Then ask Codex with phrases like:

```text
use rulez-tools to start issue 123
use rulez-tools to create PR
use rulez-tools to test PR 5
```

The first Codex adapter covers GitHub workflow and handoff commands only. The
Claude slash commands, settings, hooks, and statusline remain Claude-specific.
````

- [ ] **Step 2: Add `rulez-tools` to the command overview**

In the `## Commands` section, after the table, add:

```markdown
For Codex, use the `rulez-tools` skill instead of Claude slash commands. The
first supported Codex workflows are start issue, create PR, test PR, push
fixes, merge PR, and handoff.
```

- [ ] **Step 3: Run documentation and installer tests**

Run:

```bash
bash -n bin/setup-codex
tests/codex/run-tests.sh
```

Expected: `bash -n` exits 0 and Codex tests pass with `6 tests run, 0 failed`.

- [ ] **Step 4: Commit documentation**

Run:

```bash
git add README.md
git commit -m "docs: add Codex rulez-tools install instructions"
```

## Task 5: Final Verification

**Files:**
- Verify: `bin/setup-codex`
- Verify: `adapters/codex/skills/rulez-tools/SKILL.md`
- Verify: `tests/codex/run-tests.sh`
- Verify: `README.md`

- [ ] **Step 1: Run all focused Codex checks**

Run:

```bash
bash -n bin/setup-codex
tests/codex/run-tests.sh
```

Expected: no syntax errors and `6 tests run, 0 failed`.

- [ ] **Step 2: Run the existing shell test suites**

Run:

```bash
tests/punts/run-tests.sh
tests/what-have-i-done/run-tests.sh
```

Expected: both suites end with `0 failed`.

- [ ] **Step 3: Perform a real local Codex install check**

Run:

```bash
./bin/setup-codex
test -L "$HOME/.codex/skills/rulez-tools"
readlink "$HOME/.codex/skills/rulez-tools"
```

Expected: `readlink` prints:

```text
/Users/rulez/Projects/26.03-shared-tools/adapters/codex/skills/rulez-tools
```

If the checkout path differs, the expected target is the current repository's absolute `adapters/codex/skills/rulez-tools` path.

- [ ] **Step 4: Check final git state**

Run:

```bash
git status --short
```

Expected: no uncommitted files from this implementation except pre-existing unrelated files such as `tmp/`.

- [ ] **Step 5: Commit any final verification-only fixes**

If verification reveals a small issue, fix it and commit only the relevant files:

```bash
git add bin/setup-codex adapters/codex/skills/rulez-tools/SKILL.md tests/codex README.md
git commit -m "fix: stabilize Codex rulez-tools setup"
```

Skip this commit if no fixes were needed.

## Self-Review

- Spec coverage: The plan creates `bin/setup-codex`, creates `adapters/codex/skills/rulez-tools/SKILL.md`, symlinks to `~/.codex/skills/rulez-tools`, keeps Claude files unchanged, tests frontmatter, tests installer behavior, and documents Codex install usage.
- Scope check: The plan excludes punts, `what-have-i-done`, hooks, statusline, and slash-command emulation.
- Placeholder scan: No task uses placeholder instructions. Each code-producing step includes exact file content or exact README snippets.
- Type/name consistency: The skill name and install target are consistently `rulez-tools`.
