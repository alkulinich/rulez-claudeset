# spec2pr split tooling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two recovery tools for a spec2pr size-gate halt — a publish script that pushes one spec/plan path to `origin/main`, and a `/rulez:spec2pr-split` command that splits a too-big spec into sequential sub-specs via `superpowers:brainstorming`.

**Architecture:** Two independent tools plus one deterministic helper. Tool 1 (`git-publish-spec.sh`) is the only thing that commits/pushes, modeled on the existing `git-commit-handoff.sh` push-from-inside-the-script pattern. Tool 2 (`spec2pr-split.md`) is pure orchestration: it calls a unit-testable context helper (`spec2pr-split-context.sh`) to parse the pasted halt blob, then primes and delegates to `superpowers:brainstorming`. Nothing in the gate logic or slug derivation changes — those are referenced only.

**Tech Stack:** Bash (`set -euo pipefail`), the repo's `tests/spec2pr/` shell test harness (no framework), `gh` CLI (stubbed in tests), Claude Code command `.md` files.

## Global Constraints

- **Each sub-spec must be < 32 KB** (`SPEC2PR_MAX_SPEC` default = 32768 bytes, `scripts/lib/spec2pr-runtime.sh:10`) so it clears spec2pr's own spec gate on first run.
- **Script paths inside `.md` command files** use the tilde form `~/.claude/skills/rulez-claudeset/scripts/...` (Claude Code expands it in Bash calls).
- **Scripts use `set -euo pipefail`**; any command that may legitimately fail in a pipeline needs `|| true`.
- **RTK proxy pattern** (display-output commands only): `if command -v rtk &>/dev/null; then rtk() { command rtk "$@"; }; else rtk() { "$@"; }; fi`. Keep raw `git` where output is parsed.
- **No `Co-Authored-By` trailer** on publish commits (matches `git-commit-handoff.sh`).
- **Tool 2 never commits, pushes, closes a PR, or deletes anything** — it only writes uncommitted files and prints manual commands.
- **Command prefix from directory nesting**: `commands/rulez/spec2pr-split.md` → `/rulez:spec2pr-split`.
- Test files live in `tests/spec2pr/`; `run-tests.sh` auto-discovers every `test_*` function in every `test-*.sh`. `make_sandbox` builds `$PROJECT` on `main` with a bare `$ORIGIN` remote and the `docs/superpowers/{specs,plans}` dirs.

## File Structure

- **new** `scripts/git-publish-spec.sh` — Tool 1. Scope guard + branch guard + per-path commit + push to `origin/main`.
- **new** `scripts/spec2pr-split-context.sh` — deterministic blob parser; emits `key=value` lines + `changed_file=` lines. Called by Tool 2.
- **new** `commands/rulez/spec2pr-split.md` — Tool 2, `/rulez:spec2pr-split`. Pure orchestration.
- **new** `tests/spec2pr/test-publish-spec.sh` — Tool 1 tests.
- **new** `tests/spec2pr/test-spec2pr-split-context.sh` — context-helper tests.
- **modify** `tests/spec2pr/stub-gh.sh` — add a `pr diff` case so the helper's `gh pr diff <n> --name-only` is exercisable.
- **modify** `VERSION`, `UPGRADE.md` — register the new command (repo convention).

Reference points (unchanged): slug derivation `scripts/spec2pr.sh:57-75`; the three gates `scripts/spec2pr.sh:124-127`, `scripts/spec2pr.sh:411-414`, `scripts/lib/pr-review-engine.sh:84-86`.

---

### Task 1: Tool 1 — `scripts/git-publish-spec.sh`

**Files:**
- Create: `scripts/git-publish-spec.sh`
- Test: `tests/spec2pr/test-publish-spec.sh`

**Interfaces:**
- Consumes: nothing from other tasks. Runs from the repo root (cwd), reads `git rev-parse --show-toplevel`.
- Produces: a CLI `git-publish-spec.sh <path> [<path> …]`. Exit 0 on publish or clean no-op; non-zero on guard failure or push failure. Commit subjects: `docs: spec — <stem>`, `docs: plan — <stem>`, `docs: spec+plan — <stem>`, where `<stem>` is the spec/plan basename with `.md` and a trailing `-design`/`-plan` removed. Tool 2 (Task 3) references this script by name in its printed next-steps.

- [ ] **Step 1: Write the failing test file**

Create `tests/spec2pr/test-publish-spec.sh`:

```bash
#!/usr/bin/env bash
# Tests for scripts/git-publish-spec.sh (Tool 1). Sourced by run-tests.sh.

PUBLISH="$REPO_ROOT/scripts/git-publish-spec.sh"

# Run the publish script from inside $PROJECT, capturing combined output + rc.
run_publish() {
  set +e
  OUT="$(cd "$PROJECT" && bash "$PUBLISH" "$@" 2>&1)"
  RC=$?
}

origin_head_subject() {
  git -C "$ORIGIN" log -1 --format='%s' main 2>/dev/null || true
}
origin_head_sha() {
  git -C "$ORIGIN" rev-parse main 2>/dev/null || true
}

test_publish_spec_only() {
  make_sandbox
  printf '# Feature X\n' > "$PROJECT/docs/superpowers/specs/feature-x-design.md"
  run_publish docs/superpowers/specs/feature-x-design.md
  assert_eq 0 "$RC" "publish spec exits 0"
  assert_eq "docs: spec — feature-x" "$(origin_head_subject)" "subject is docs: spec — <stem>"
  # Only the spec path is in the published commit.
  local files
  files="$(git -C "$PROJECT" show --name-only --format= HEAD | tr -d ' ')"
  assert_contains "$files" "docs/superpowers/specs/feature-x-design.md" "spec file is in commit"
  rm -rf "$SANDBOX"
}

test_publish_spec_and_plan() {
  make_sandbox
  printf '# Feature X\n' > "$PROJECT/docs/superpowers/specs/feature-x-design.md"
  printf '# Feature X plan\n' > "$PROJECT/docs/superpowers/plans/feature-x-plan.md"
  run_publish docs/superpowers/specs/feature-x-design.md docs/superpowers/plans/feature-x-plan.md
  assert_eq 0 "$RC" "publish spec+plan exits 0"
  assert_eq "docs: spec+plan — feature-x" "$(origin_head_subject)" "subject is docs: spec+plan — <stem>"
  local files
  files="$(git -C "$PROJECT" show --name-only --format= HEAD)"
  assert_contains "$files" "feature-x-design.md" "spec staged"
  assert_contains "$files" "feature-x-plan.md" "plan staged"
  rm -rf "$SANDBOX"
}

test_publish_noop_when_unchanged() {
  make_sandbox
  printf '# Feature X\n' > "$PROJECT/docs/superpowers/specs/feature-x-design.md"
  run_publish docs/superpowers/specs/feature-x-design.md
  local first_sha; first_sha="$(origin_head_sha)"
  run_publish docs/superpowers/specs/feature-x-design.md
  assert_eq 0 "$RC" "second run exits 0"
  assert_eq "$first_sha" "$(origin_head_sha)" "no new commit on unchanged re-run"
  rm -rf "$SANDBOX"
}

test_publish_refuses_out_of_scope_path() {
  make_sandbox
  printf '# changed\n' >> "$PROJECT/README.md"
  run_publish README.md
  assert_eq 1 "$RC" "out-of-scope path is rejected"
  assert_contains "$OUT" "README.md" "error names the offending path"
  assert_eq "init" "$(origin_head_subject)" "origin unchanged after rejection"
  rm -rf "$SANDBOX"
}

test_publish_refuses_non_main_branch() {
  make_sandbox
  git -C "$PROJECT" checkout -q -b feature/foo
  printf '# Feature X\n' > "$PROJECT/docs/superpowers/specs/feature-x-design.md"
  run_publish docs/superpowers/specs/feature-x-design.md
  assert_eq 1 "$RC" "non-main branch is rejected"
  assert_contains "$OUT" "feature/foo" "error names the current branch"
  rm -rf "$SANDBOX"
}

test_publish_ignores_stray_dirty_file() {
  make_sandbox
  printf '# Feature X\n' > "$PROJECT/docs/superpowers/specs/feature-x-design.md"
  printf 'stray\n' >> "$PROJECT/README.md"   # dirty, but not handed to the script
  run_publish docs/superpowers/specs/feature-x-design.md
  assert_eq 0 "$RC" "publish exits 0 with an unrelated dirty file present"
  local files
  files="$(git -C "$PROJECT" show --name-only --format= HEAD)"
  assert_not_contains "$files" "README.md" "stray file not swept into the commit"
  rm -rf "$SANDBOX"
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run (the missing script makes every `run_publish` fail):

```bash
bash -c '
set -uo pipefail
cd /home/rulez/.worktrees/rulez-claudeset-2026-06-25-spec2pr-split-design
source tests/spec2pr/helpers.sh
source tests/spec2pr/test-publish-spec.sh
for fn in $(declare -F | awk "{print \$3}" | grep "^test_publish"); do echo "$fn"; "$fn"; done
printf "\n%d run, %d failed\n" "$TESTS_RUN" "$TESTS_FAILED"
'
```

Expected: several FAIL lines; final summary shows `N failed` with N > 0 (script not found / no commit produced).

- [ ] **Step 3: Write `scripts/git-publish-spec.sh`**

```bash
#!/bin/bash
#
# git-publish-spec.sh - Publish a spec and/or plan to origin/main.
#
# Usage: ./scripts/git-publish-spec.sh <path> [<path> ...]
#
# Stages ONLY the named paths (each must live under
# docs/superpowers/{specs,plans}), commits a conventional docs: subject, and
# pushes to origin/main from inside the script. Per-path commit+push is the
# sequencing mechanism: origin/main only ever sees the path you publish.
set -euo pipefail

# Use rtk proxy if available (reduces LLM token usage on display output).
if command -v rtk &>/dev/null; then
  rtk() { command rtk "$@"; }
else
  rtk() { "$@"; }
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

err() { echo -e "${RED}Error: $1${NC}" >&2; }

if [ "$#" -eq 0 ]; then
  err "usage: git-publish-spec.sh <path> [<path> ...]"
  exit 1
fi

# -- Branch guard: "publish to origin/main" must be unambiguous --------------
BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
if [ "$BRANCH" != "main" ]; then
  err "must be on 'main' to publish (current branch: ${BRANCH:-detached HEAD})"
  exit 1
fi

ROOT="$(git rev-parse --show-toplevel)"

# Strip extension + a trailing -design / -plan suffix for a clean subject stem.
stem_of() {
  local b; b="$(basename "$1")"; b="${b%.md}"; b="${b%-design}"; b="${b%-plan}"
  printf '%s' "$b"
}

# -- Scope guard: every path must be a real file under specs/ or plans/ ------
first_spec=""
first_plan=""
for p in "$@"; do
  if [ ! -f "$p" ]; then
    err "not a file: $p"
    exit 1
  fi
  abs="$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"
  case "$abs/" in
    "$ROOT/docs/superpowers/specs/"*) [ -n "$first_spec" ] || first_spec="$p" ;;
    "$ROOT/docs/superpowers/plans/"*) [ -n "$first_plan" ] || first_plan="$p" ;;
    *)
      err "out-of-scope path (must be under docs/superpowers/{specs,plans}): $p"
      exit 1
      ;;
  esac
done

# -- No-op if nothing among the named paths changed --------------------------
if [ -z "$(git status --porcelain -- "$@")" ]; then
  echo -e "${YELLOW}No changes in the named paths — skipping commit${NC}"
  exit 0
fi

# -- Compose subject from the kind(s) of path + the stem ---------------------
if [ -n "$first_spec" ] && [ -n "$first_plan" ]; then
  KIND="spec+plan"; STEM="$(stem_of "$first_spec")"
elif [ -n "$first_spec" ]; then
  KIND="spec"; STEM="$(stem_of "$first_spec")"
else
  KIND="plan"; STEM="$(stem_of "$first_plan")"
fi
SUBJECT="docs: $KIND — $STEM"

echo -e "${YELLOW}Publishing: $SUBJECT${NC}"
rtk git add -- "$@"
rtk git commit -m "$SUBJECT"

# -- Push to origin/main from inside the script ------------------------------
# The Claude Code harness prompts on visible `git push origin main` calls;
# running it here keeps this pre-authorized doc-only publish friction-free.
echo -e "${YELLOW}Pushing to origin/main...${NC}"
if rtk git push origin main; then
  echo -e "${GREEN}Published.${NC} origin/main now carries: $SUBJECT"
else
  err "push failed — committed locally; push manually with: git push origin main"
  exit 1
fi
```

- [ ] **Step 4: Make it executable and run the tests to verify they pass**

```bash
chmod +x /home/rulez/.worktrees/rulez-claudeset-2026-06-25-spec2pr-split-design/scripts/git-publish-spec.sh
bash -c '
set -uo pipefail
cd /home/rulez/.worktrees/rulez-claudeset-2026-06-25-spec2pr-split-design
source tests/spec2pr/helpers.sh
source tests/spec2pr/test-publish-spec.sh
for fn in $(declare -F | awk "{print \$3}" | grep "^test_publish"); do echo "$fn"; "$fn"; done
printf "\n%d run, %d failed\n" "$TESTS_RUN" "$TESTS_FAILED"
'
```

Expected: all `ok:` lines; final summary `0 failed`.

- [ ] **Step 5: Commit**

```bash
cd /home/rulez/.worktrees/rulez-claudeset-2026-06-25-spec2pr-split-design
git add scripts/git-publish-spec.sh tests/spec2pr/test-publish-spec.sh
git commit -m "feat: add git-publish-spec.sh (spec2pr split Tool 1)"
```

---

### Task 2: Helper — `scripts/spec2pr-split-context.sh`

**Files:**
- Create: `scripts/spec2pr-split-context.sh`
- Modify: `tests/spec2pr/stub-gh.sh` (add a `pr diff` case)
- Test: `tests/spec2pr/test-spec2pr-split-context.sh`

**Interfaces:**
- Consumes: a blob file path (the pasted halt output). Uses `gh pr diff <n> --name-only` when a PR number is present.
- Produces: `spec2pr-split-context.sh <blob-file>` → stdout `key=value` lines in this exact order — `spec_path=…`, `plan_path=…` (may be empty), `gate=…` (`spec`|`plan`|`diff`), `pr_number=…` (may be empty) — followed by zero or more `changed_file=<path>` lines. Warnings go to stderr. Exit non-zero only when the spec path is missing or does not exist. Task 3 reads these keys.

- [ ] **Step 1: Add a `pr diff` case to the gh stub**

In `tests/spec2pr/stub-gh.sh`, add a new branch to the `case` statement (after the `"pr ready")` block, before the closing `esac`):

```bash
  "pr diff")
    if [ -f "$dir/pr-diff-fail" ]; then
      cat "$dir/pr-diff-fail" >&2
      exit 9
    fi
    if [ -f "$dir/pr-diff-files" ]; then cat "$dir/pr-diff-files"; fi
    ;;
```

Also extend the stub's header comment block so the new fixtures are documented — add these two lines under the existing fixture list:

```bash
#   pr-diff-files - if present, its content is the `pr diff --name-only` output
#   pr-diff-fail  - if present, `pr diff` prints it to stderr and exits 9
```

- [ ] **Step 2: Write the failing test file**

Create `tests/spec2pr/test-spec2pr-split-context.sh`:

```bash
#!/usr/bin/env bash
# Tests for scripts/spec2pr-split-context.sh. Sourced by run-tests.sh.

CONTEXT="$REPO_ROOT/scripts/spec2pr-split-context.sh"

# Run the helper from inside $PROJECT (so docs/... paths resolve), capturing
# stdout+stderr combined into OUT and the exit code into RC.
run_context() {
  set +e
  OUT="$(cd "$PROJECT" && bash "$CONTEXT" "$1" 2>&1)"
  RC=$?
}

# Write a blob file in $PROJECT and return its path via BLOB.
write_blob() {
  BLOB="$PROJECT/blob.txt"
  printf '%s' "$1" > "$BLOB"
}

mk_spec() {
  printf '# spec\n' > "$PROJECT/docs/superpowers/specs/dc-import-2026-design.md"
}

test_context_gate_diff() {
  make_sandbox; mk_spec
  write_blob $'reviewed docs/superpowers/specs/dc-import-2026-design.md\nSPEC2PR SPLIT diff size=166010 limit=131072\n'
  run_context "$BLOB"
  assert_eq 0 "$RC" "diff blob parses"
  assert_contains "$OUT" "gate=diff" "gate extracted as diff"
  rm -rf "$SANDBOX"
}

test_context_gate_spec_and_plan_tokens() {
  make_sandbox; mk_spec
  write_blob $'docs/superpowers/specs/dc-import-2026-design.md\nSPLIT spec size=40000 limit=32768\n'
  run_context "$BLOB"
  assert_contains "$OUT" "gate=spec" "gate extracted as spec"
  rm -rf "$SANDBOX"

  make_sandbox; mk_spec
  write_blob $'docs/superpowers/specs/dc-import-2026-design.md\nSPLIT plan size=70000 limit=65536\n'
  run_context "$BLOB"
  assert_contains "$OUT" "gate=plan" "gate extracted as plan"
  rm -rf "$SANDBOX"
}

test_context_pr_number_from_url() {
  make_sandbox; mk_spec
  write_blob $'PR https://github.com/alkulinich/dc-import-2026/pull/98\ndocs/superpowers/specs/dc-import-2026-design.md\nSPLIT diff size=166010 limit=131072\n'
  printf 'a.sh\nb.sh\n' > "$SPEC2PR_TEST_GH/pr-diff-files"
  run_context "$BLOB"
  assert_contains "$OUT" "pr_number=98" "PR number pulled from URL"
  rm -rf "$SANDBOX"
}

test_context_pr_number_from_hash() {
  make_sandbox; mk_spec
  write_blob $'see PR #98 for the dead run\ndocs/superpowers/specs/dc-import-2026-design.md\nSPLIT diff size=1 limit=1\n'
  printf 'a.sh\n' > "$SPEC2PR_TEST_GH/pr-diff-files"
  run_context "$BLOB"
  assert_contains "$OUT" "pr_number=98" "PR number pulled from #N"
  rm -rf "$SANDBOX"
}

test_context_plan_absent_vs_present() {
  make_sandbox; mk_spec
  write_blob $'docs/superpowers/specs/dc-import-2026-design.md\nSPLIT spec size=40000 limit=32768\n'
  run_context "$BLOB"
  assert_contains "$OUT" "plan_path=" "plan_path key present"
  assert_not_contains "$OUT" "plan_path=docs" "plan_path empty when no plan in blob"
  rm -rf "$SANDBOX"

  make_sandbox; mk_spec
  printf '# plan\n' > "$PROJECT/docs/superpowers/plans/dc-import-2026-plan.md"
  write_blob $'spec docs/superpowers/specs/dc-import-2026-design.md\nplan docs/superpowers/plans/dc-import-2026-plan.md\nSPLIT plan size=70000 limit=65536\n'
  run_context "$BLOB"
  assert_contains "$OUT" "plan_path=docs/superpowers/plans/dc-import-2026-plan.md" "plan_path filled when present"
  rm -rf "$SANDBOX"
}

test_context_changed_files_via_gh() {
  make_sandbox; mk_spec
  write_blob $'https://github.com/alkulinich/dc-import-2026/pull/98\ndocs/superpowers/specs/dc-import-2026-design.md\nSPLIT diff size=166010 limit=131072\n'
  printf 'src/import.sh\ntests/test-import.sh\n' > "$SPEC2PR_TEST_GH/pr-diff-files"
  run_context "$BLOB"
  assert_contains "$OUT" "changed_file=src/import.sh" "changed file 1 emitted"
  assert_contains "$OUT" "changed_file=tests/test-import.sh" "changed file 2 emitted"
  rm -rf "$SANDBOX"
}

test_context_missing_spec_path() {
  make_sandbox
  write_blob $'no spec path here\nSPLIT diff size=1 limit=1\n'
  run_context "$BLOB"
  assert_eq 1 "$RC" "missing spec path exits non-zero"
  rm -rf "$SANDBOX"
}

test_context_nonexistent_spec_path() {
  make_sandbox
  write_blob $'docs/superpowers/specs/does-not-exist-design.md\nSPLIT spec size=1 limit=1\n'
  run_context "$BLOB"
  assert_eq 1 "$RC" "nonexistent spec path exits non-zero"
  rm -rf "$SANDBOX"
}

test_context_gh_diff_failure_degrades() {
  make_sandbox; mk_spec
  write_blob $'https://github.com/alkulinich/dc-import-2026/pull/98\ndocs/superpowers/specs/dc-import-2026-design.md\nSPLIT diff size=166010 limit=131072\n'
  printf 'boom\n' > "$SPEC2PR_TEST_GH/pr-diff-fail"
  run_context "$BLOB"
  assert_eq 0 "$RC" "gh failure does not fail the helper"
  assert_contains "$OUT" "pr_number=98" "other fields still emitted"
  assert_not_contains "$OUT" "changed_file=" "changed-files omitted on gh failure"
  assert_contains "$OUT" "warning" "warns about degraded seam"
  rm -rf "$SANDBOX"
}

test_context_no_gate_defaults_to_spec() {
  make_sandbox; mk_spec
  write_blob $'just the path docs/superpowers/specs/dc-import-2026-design.md and nothing else\n'
  run_context "$BLOB"
  assert_contains "$OUT" "gate=spec" "gate defaults to spec"
  assert_contains "$OUT" "warning" "warns when gate token absent"
  rm -rf "$SANDBOX"
}
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
bash -c '
set -uo pipefail
cd /home/rulez/.worktrees/rulez-claudeset-2026-06-25-spec2pr-split-design
source tests/spec2pr/helpers.sh
source tests/spec2pr/test-spec2pr-split-context.sh
for fn in $(declare -F | awk "{print \$3}" | grep "^test_context"); do echo "$fn"; "$fn"; done
printf "\n%d run, %d failed\n" "$TESTS_RUN" "$TESTS_FAILED"
'
```

Expected: FAIL lines (script missing); summary `N failed` with N > 0.

- [ ] **Step 4: Write `scripts/spec2pr-split-context.sh`**

```bash
#!/usr/bin/env bash
#
# spec2pr-split-context.sh - Deterministic front-half of /rulez:spec2pr-split.
#
# Usage: spec2pr-split-context.sh <blob-file>
#
# Parses the pasted spec2pr halt blob and emits a key/value block on stdout:
#   spec_path=<docs/superpowers/specs/...-design.md>   (required)
#   plan_path=<docs/superpowers/plans/...-plan.md>      (may be empty)
#   gate=<spec|plan|diff>                               (defaults to spec)
#   pr_number=<N>                                       (may be empty)
#   changed_file=<path>   (zero or more; only when a PR number was found)
# Warnings go to stderr. Exits non-zero only when the spec path is missing or
# does not exist.
set -euo pipefail

warn() { echo "warning: $1" >&2; }

BLOB="${1:-}"
if [ -z "$BLOB" ] || [ ! -f "$BLOB" ]; then
  echo "Error: usage: spec2pr-split-context.sh <blob-file>" >&2
  exit 1
fi
content="$(cat "$BLOB")"

# -- spec path (required, must exist) ----------------------------------------
spec_path="$(grep -oE 'docs/superpowers/specs/[^[:space:]]+\.md' <<<"$content" | head -n1 || true)"
if [ -z "$spec_path" ]; then
  echo "Error: no spec path (docs/superpowers/specs/...-design.md) found in blob" >&2
  exit 1
fi
if [ ! -f "$spec_path" ]; then
  echo "Error: spec path not found: $spec_path" >&2
  exit 1
fi

# -- plan path (optional) ----------------------------------------------------
plan_path="$(grep -oE 'docs/superpowers/plans/[^[:space:]]+\.md' <<<"$content" | head -n1 || true)"

# -- gate token (default spec) -----------------------------------------------
gate="$(grep -oE 'SPLIT[[:space:]]+(spec|plan|diff)' <<<"$content" | head -n1 | awk '{print $2}' || true)"
if [ -z "$gate" ]; then
  gate="spec"
  warn "no SPLIT gate token found; defaulting gate=spec (evidence-poorest case)"
fi

# -- PR number (from a /pull/N URL or a #N reference) ------------------------
pr_number="$(grep -oE 'pull/[0-9]+|#[0-9]+' <<<"$content" | head -n1 | grep -oE '[0-9]+' || true)"

# -- emit the fixed key block ------------------------------------------------
printf 'spec_path=%s\n' "$spec_path"
printf 'plan_path=%s\n' "$plan_path"
printf 'gate=%s\n' "$gate"
printf 'pr_number=%s\n' "$pr_number"

# -- changed files (richest seam evidence; degrade gracefully) ---------------
if [ -n "$pr_number" ]; then
  if files="$(gh pr diff "$pr_number" --name-only 2>/dev/null)"; then
    while IFS= read -r f; do
      [ -n "$f" ] && printf 'changed_file=%s\n' "$f"
    done <<<"$files"
  else
    warn "gh pr diff $pr_number failed; changed-files omitted (degraded seam)"
  fi
fi
```

- [ ] **Step 5: Make it executable and run the tests to verify they pass**

```bash
chmod +x /home/rulez/.worktrees/rulez-claudeset-2026-06-25-spec2pr-split-design/scripts/spec2pr-split-context.sh
bash -c '
set -uo pipefail
cd /home/rulez/.worktrees/rulez-claudeset-2026-06-25-spec2pr-split-design
source tests/spec2pr/helpers.sh
source tests/spec2pr/test-spec2pr-split-context.sh
for fn in $(declare -F | awk "{print \$3}" | grep "^test_context"); do echo "$fn"; "$fn"; done
printf "\n%d run, %d failed\n" "$TESTS_RUN" "$TESTS_FAILED"
'
```

Expected: all `ok:` lines; summary `0 failed`.

- [ ] **Step 6: Run the full spec2pr suite to confirm the stub-gh.sh change broke nothing**

```bash
bash /home/rulez/.worktrees/rulez-claudeset-2026-06-25-spec2pr-split-design/tests/spec2pr/run-tests.sh 2>&1 | tail -5
```

Expected: final line `N tests run, 0 failed`.

- [ ] **Step 7: Commit**

```bash
cd /home/rulez/.worktrees/rulez-claudeset-2026-06-25-spec2pr-split-design
git add scripts/spec2pr-split-context.sh tests/spec2pr/test-spec2pr-split-context.sh tests/spec2pr/stub-gh.sh
git commit -m "feat: add spec2pr-split-context.sh (split blob parser)"
```

---

### Task 3: Tool 2 — `commands/rulez/spec2pr-split.md`

**Files:**
- Create: `commands/rulez/spec2pr-split.md`

**Interfaces:**
- Consumes: `scripts/spec2pr-split-context.sh` (Task 2) for the `key=value` block; `scripts/git-publish-spec.sh` (Task 1) named in printed next-steps. Delegates to `superpowers:brainstorming` via the Skill tool.
- Produces: a `/rulez:spec2pr-split <blob>` command. Writes two uncommitted sub-spec files; commits/pushes nothing. Verified by manual dry-run, not unit tests (the body is interactive orchestration).

- [ ] **Step 1: Write the command file**

Create `commands/rulez/spec2pr-split.md`:

````markdown
# Spec2PR Split

Recover from a spec2pr size-gate halt: split one too-big spec into sequential,
independently-implementable sub-specs. Pure orchestration — this command writes
two uncommitted spec files and prints manual next steps. It never commits,
pushes, closes a PR, or deletes anything.

## Usage

- `/rulez:spec2pr-split <blob>` — paste roughly what spec2pr printed: the
  reviewed spec path, the plan path (if any), and the `SPLIT …`/halt line. A PR
  URL or `#N` (for a `diff` gate) sharpens the seam.

## Instructions

If no blob argument was given, ask the user to paste the spec2pr halt output
(spec path, optional plan path, the `SPLIT …` line, and any PR URL). Stop until
they do.

1. **Gather context.** Write the pasted blob to a temp file and run the helper:

   ```bash
   BLOB="$(mktemp)"; cat > "$BLOB" <<'BLOB_EOF'
   <paste the blob here verbatim>
   BLOB_EOF
   bash ~/.claude/skills/rulez-claudeset/scripts/spec2pr-split-context.sh "$BLOB"; rm -f "$BLOB"
   ```

   If it exits non-zero, show its error and stop. Otherwise read the
   `key=value` block: `spec_path`, `plan_path` (may be empty), `gate`
   (`spec`|`plan`|`diff`), `pr_number` (may be empty), and any `changed_file=`
   lines.

2. **Compute the part paths and refuse on collision.** From `spec_path`
   (`docs/superpowers/specs/<slug>-design.md`), insert `-part-N` before
   `-design`:
   - `docs/superpowers/specs/<slug>-part-1-design.md`
   - `docs/superpowers/specs/<slug>-part-2-design.md`

   If **either** path already exists, stop. Name the colliding path and tell
   the operator to rename, remove, or archive the stale draft first. Do not
   overwrite anything and do not invoke brainstorming.

3. **Invoke `superpowers:brainstorming`** via the Skill tool, primed with the
   evidence and these override directives:
   - **Framing:** "spec2pr's `<gate>` gate rejected this spec (size N > limit
     M). Decompose it into N (default 2) sequential, independently-implementable
     sub-specs that minimize shared files."
   - **Write both files in one pass** to the two part paths from step 2. This
     "write both, not one" is the only deviation from default brainstorming.
   - **Each sub-spec** follows house style (Context / Settled decisions /
     Affected code / The change / Edge cases & invariants / Testing / Out of
     scope) and stays **under 32 KB** so it clears spec2pr's own spec gate on
     the first run.
   - **Coverage map:** every requirement in the original maps to exactly one
     part — no gaps. Minimize shared files; when overlap is necessary (shared
     tests, docs, integration glue), the map must list the overlapping paths and
     justify each. Cross-check against the `changed_file=` list when present.
   - **Sequential constraint in part-2's prose:** "part-1 is already merged into
     `main`; build on it, do not re-specify its changes."
   - Leave both sub-specs **uncommitted**; do **not** push.
   - **Terminal state = the brainstorming review gate.** Stop after writing the
     files; do **not** chain to `writing-plans`.

4. **On return**, surface the two part paths + the coverage map, then print the
   manual next steps keyed to `gate` (execute nothing destructive):

   - If `gate` is `diff` and a `pr_number` is present:
     `dead PR #<pr_number>: gh pr close <pr_number> --delete-branch`, then
     remove the stale worktree/meta for the old slug.
   - If `gate` is `spec` or `plan`: no PR; remove the local worktree/meta for
     the old slug only if a run started.

   Then the sequencing recipe (one path at a time):

   ```
   git-publish-spec.sh docs/superpowers/specs/<slug>-part-1-design.md
   # run spec2pr on part-1 → review → merge its PR
   git pull --ff-only origin main
   git-publish-spec.sh docs/superpowers/specs/<slug>-part-2-design.md
   # run spec2pr on part-2 → review → merge
   ```
````

- [ ] **Step 2: Verify the command is discoverable**

```bash
ls -la /home/rulez/.worktrees/rulez-claudeset-2026-06-25-spec2pr-split-design/commands/rulez/spec2pr-split.md
```

Expected: the file exists. (`commands/rulez/` is symlinked into `~/.claude/commands/rulez/` by `bin/setup`, so the command resolves to `/rulez:spec2pr-split` after the next install/update.)

- [ ] **Step 3: Manual dry-run (the brainstorming hand-off is not unit-tested)**

Walk the command by hand against a synthetic blob to confirm two behaviors the spec calls out:
- **Happy path:** a `diff`-gate blob with a PR URL yields the two `-part-N-design.md` paths, the priming prompt, and the `diff`-keyed cleanup line.
- **Collision guard:** pre-create one target part file; confirm the command stops with a non-zero/refusal before invoking brainstorming, names the colliding path, and leaves the file untouched.

Record the dry-run outcome in the commit message. No code to run here — this is a read-through of the command logic with the operator.

- [ ] **Step 4: Commit**

```bash
cd /home/rulez/.worktrees/rulez-claudeset-2026-06-25-spec2pr-split-design
git add commands/rulez/spec2pr-split.md
git commit -m "feat: add /rulez:spec2pr-split command (spec2pr split Tool 2)"
```

---

### Task 4: Register the new command (repo convention)

**Files:**
- Modify: `VERSION`
- Modify: `UPGRADE.md`

**Interfaces:**
- Consumes: nothing. Produces: a version bump + a user-facing upgrade note so the auto-update/`/rulez:update-claudeset` flow surfaces the new command. Per CLAUDE.md "Version Bumping".

- [ ] **Step 1: Read the current version**

```bash
cat /home/rulez/.worktrees/rulez-claudeset-2026-06-25-spec2pr-split-design/VERSION
```

Note the value (call it `X.Y.Z`); the new version is the next minor bump (`X.(Y+1).0`) since this adds a command and a script.

- [ ] **Step 2: Bump `VERSION`**

Write the bumped semver into `VERSION` (single line, no trailing prose). Example if current is `0.4.0`:

```
0.5.0
```

- [ ] **Step 3: Add a user-facing `UPGRADE.md` section**

Prepend a section in the format `## To vX.Y.Z — from <source>` (matching the existing sections). Keep it tight — **Action:** plus optional **Caveat:** only:

```markdown
## To v0.5.0 — from main

**Action:** None. Two new spec2pr split-recovery tools ship automatically: the
`/rulez:spec2pr-split` command and the `git-publish-spec.sh` helper.
```

(Use the actual bumped version from Step 2 in the heading.)

- [ ] **Step 4: Commit**

```bash
cd /home/rulez/.worktrees/rulez-claudeset-2026-06-25-spec2pr-split-design
git add VERSION UPGRADE.md
git commit -m "chore: bump version for spec2pr split tooling"
```

---

## Self-Review

**Spec coverage** (every spec section maps to a task):
- Tool 1 `git-publish-spec.sh` — scope guard, branch guard, no-op-if-clean, stage-only-named, conventional subject, push-from-inside, no `Co-Authored-By` → **Task 1** (script Step 3) + tests (Step 1).
- Tool 2 `spec2pr-split.md` — context gather, brainstorming prime/delegate, collision guard, coverage map, sequential part-2 prose, terminal=review gate, gate-keyed cleanup, sequencing recipe → **Task 3**.
- Helper `spec2pr-split-context.sh` — spec/plan/gate/pr/changed-files parse, default-to-spec warn, gh-fail degrade, missing-spec non-zero → **Task 2**.
- Publishing & sequencing model (per-path commit is the sequencing mechanism) → enforced by Task 1's stage-only-named behavior; documented in Task 3's printed recipe.
- Edge cases & invariants — per-path commit+push, scope+branch guards, no-op-when-unchanged, unparseable gate→spec, gh-fail degrade, <32 KB, slug distinctness via `-part-N`, output collision guard, coverage map, watcher caveat → covered across Tasks 1–3 (collision guard Task 3 Step 2; slug distinctness Task 3 Step 2; <32 KB priming Task 3 Step 3).
- Testing — `test-publish-spec.sh` six cases → Task 1; `test-spec2pr-split-context.sh` six+ cases → Task 2; brainstorming hand-off + collision guard via manual dry-run → Task 3 Step 3.
- Out of scope (recursion, auto-cleanup, auto-publish, N>2 as built feature, splitting the plan, a `/rulez:` wrapper for Tool 1) — intentionally not implemented; no task. Confirmed nothing in the plan adds them.

**Placeholder scan:** no `TBD`/`TODO`/"handle edge cases"/"similar to Task N" — every script and test step shows full content. The manual dry-run (Task 3 Step 3) is a deliberate, spec-mandated verification, not a placeholder.

**Type/name consistency:** the helper's output keys (`spec_path`, `plan_path`, `gate`, `pr_number`, `changed_file=`) are produced in Task 2 Step 4 and consumed verbatim in Task 3 Step 1. Commit-subject stems (`docs: spec — <stem>` etc.) are asserted in Task 1 Step 1 with the exact `stem_of` stripping (`-design`/`-plan` removed) implemented in Task 1 Step 3. The stub fixture names (`pr-diff-files`, `pr-diff-fail`) match between the stub edit (Task 2 Step 1) and the tests (Task 2 Step 2).
