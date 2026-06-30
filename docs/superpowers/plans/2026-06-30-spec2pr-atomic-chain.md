# spec2pr Atomic Chains Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `spec2pr-chain.sh --atomic` stage every spec of a split task on a throwaway integration branch and land them on `main` in a single squash — all-or-nothing — so a mid-chain halt leaves `main` untouched.

**Architecture:** Two new independent `spec2pr.sh` primitives — `--base <branch>` (cut the worktree from / target `origin/<branch>`) and `--no-pr` (implement + local review, skip push/PR-create) — composed by a new `--atomic` path in the chain. The chain creates `spec2pr-chain/<chain_id>` on origin, runs each part with `--base <integ> --no-pr`, squash-merges each part into integ with pure git plumbing (no checkout), then opens one squash PR `integ → main` from a temporary integ worktree. Markers under `$SPEC2PR_HOME/chains/<chain_id>/` give resume; the eager (non-`--atomic`) path is untouched.

**Tech Stack:** Bash (must stay **Bash 3.2-compatible** — no `declare -A`), `git` plumbing (`commit-tree`, `worktree`), `gh` CLI, the `tests/spec2pr/` harness (stub `gh`/`codex`/`claude`, no external test framework).

## Global Constraints

- **Do NOT modify `VERSION` or `UPGRADE.md`.** They are updated separately, later.
- **Bash 3.2 compatibility:** no associative arrays (`declare -A`); guard `"${arr[@]}"` expansions under `set -u` when the array may be empty (mirror existing chain patterns).
- **Co-author trailer on every commit:** `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **The eager (non-`--atomic`) chain path and default (no `--base`/`--no-pr`) spec2pr behavior must stay byte-for-byte unchanged.** Existing tests prove this.
- **Stage by exact path** in every commit (never `git add .`).
- **Testing discipline:** do NOT run the full suite mid-implementation. Run only the focused test file for the task you just finished. Run the **full** suite exactly **once**, at the end (Task 7), inside a **subagent** that returns only the summary + any FAIL lines.
- **Test harness facts** (from `tests/spec2pr/helpers.sh`, `test-chain.sh`, `stub-gh.sh`):
  - `make_sandbox` builds a sandbox with a bare `origin`, `PROJECT` on `main`, stub `gh`/`codex`/`claude`, isolated `SPEC2PR_HOME`/`SPEC2PR_WORKTREES`, and exports `SPEC2PR_PUBLISH_ON_HALT=0`.
  - `add_spec <slug>` writes an untracked toy spec and echoes its path; the derived spec2pr SLUG equals `<slug>`; its `ID` is `project-<slug>`; `META_DIR` is `$SPEC2PR_HOME/project-<slug>`.
  - `queue_chain_spec <prefix> <slug> [prerequisite-file]` queues all seven stage fixtures (spec-review, plan, plan-review, forecast, implement, pr-review-a, pr-review-b) for one spec2pr run; the implement fixture writes `marker-<slug>.txt` and, if `prerequisite-file` is given, fails unless that file already exists in the worktree.
  - `queue_chain_spec_dirty <ordinal> <slug>` keeps spec-review blocked so spec2pr exits DIRTY.
  - `run_spec2pr <args...>` / `run_chain <args...>` capture combined output + exit code into `OUT` / `RC`.
  - The stub `gh pr merge` (default) pushes the **cwd** `HEAD` to `origin/main` and echoes `merged`; every `gh` call is logged to `$SPEC2PR_TEST_GH/gh.log` as `cwd=<path> args=<argv>`. `pr-merge-fail-once` makes the next `pr merge` fail once then be removed; `pr-merge-fail` makes it fail persistently.
  - The stub does **not** truly squash; it fast-forward-pushes cwd `HEAD`. So atomic tests assert **content on `main`** + **gh call counts**, not exact commit count (the single-commit collapse is real `gh --squash` server-side behavior, same as the existing eager tests assert content, not topology).
  - `assert_eq` / `assert_contains` / `assert_not_contains` / `assert_file_exists` / `assert_file_absent` are the only assertion helpers.
  - `queue_chain_spec`, `run_chain`, and `CHAIN` are defined in `test-chain.sh`; all `test-*.sh` files are sourced before any test runs, so a new `test-*.sh` may call them from inside its `test_*` functions.

---

### Task 1: `spec2pr.sh --base <branch>`

Add the `--base` primitive: cut the worktree from `origin/<branch>`, target that branch's PR, persist + validate the base on resume. Default `main` keeps today's behavior.

**Files:**
- Modify: `scripts/spec2pr.sh` (arg loop ~7-58; fetch :165; resume metadata :178-216; PR base :764)
- Create test: `tests/spec2pr/test-base.sh`

**Interfaces:**
- Produces: `spec2pr.sh --base <branch>` flag; new metadata file `$META_DIR/base-branch`; PR opened with `--base <branch>`.
- Consumes: nothing new.

- [ ] **Step 1: Write the failing test** — create `tests/spec2pr/test-base.sh`:

```bash
#!/usr/bin/env bash
# Tests for spec2pr.sh --base <branch>. Drives the real spec2pr.sh; only the
# model and gh boundaries are stubbed. Reuses queue_chain_spec from test-chain.sh.

test_spec2pr_base_targets_nonmain_branch() {
  make_sandbox
  git -C "$PROJECT" branch other origin/main
  git -C "$PROJECT" push -q origin other
  local s; s="$(add_spec base-flag)"
  queue_chain_spec 01-base-flag base-flag

  run_spec2pr --base other "$s"

  assert_eq "0" "$RC" "--base run exits 0"
  assert_contains "$OUT" "SPEC2PR DONE pr=" "--base run reaches DONE with a PR"
  assert_eq "other" "$(cat "$SPEC2PR_HOME/project-base-flag/base-branch" 2>/dev/null || true)" \
    "base-branch metadata records the chosen base"
  assert_eq "1" "$(grep -c 'args=pr create .*--base other' "$SPEC2PR_TEST_GH/gh.log")" \
    "PR is created against the chosen base"
}

test_spec2pr_base_resume_rejects_mismatch() {
  make_sandbox
  git -C "$PROJECT" branch other origin/main
  git -C "$PROJECT" push -q origin other
  local s; s="$(add_spec base-mm)"
  queue_chain_spec 01-base-mm base-mm

  run_spec2pr --base other "$s"
  assert_eq "0" "$RC" "first --base run exits 0"

  run_spec2pr --base main "$s"
  assert_eq "1" "$RC" "mismatched --base on resume halts"
  assert_contains "$OUT" "worktree base is other" "mismatch halt names the recorded base"
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A3 base_`
Expected: FAIL on `--base run exits 0` (actual `1`) — `--base` is rejected by the arg loop (`--*) usage`).

- [ ] **Step 3: Add the base-branch variables** — `scripts/spec2pr.sh`, in the init block (note `IMPLEMENTER_MODEL=""` is already present — it was added by PR #27; keep it):

```bash
IMPLEMENTER_AGENT="codex"
IMPLEMENTER_MODEL=""
IMPLEMENTER_AGENT_GIVEN=0
BASE_BRANCH="main"
BASE_BRANCH_GIVEN=0
while [ "$#" -gt 0 ]; do
```

- [ ] **Step 4: Parse `--base`** — add cases after the `--implementer=*` case (line 48), before `--*)`:

```bash
    --base)
      shift
      [ "$#" -gt 0 ] || usage
      BASE_BRANCH="$1"
      BASE_BRANCH_GIVEN=1
      shift
      ;;
    --base=*)
      BASE_BRANCH="${1#--base=}"
      BASE_BRANCH_GIVEN=1
      shift
      ;;
```

- [ ] **Step 5: Advertise `--base` in usage** — line 8, insert `[--base <branch>]` before `<spec-path>` (the `claude:sonnet` tier in the implementer list is from PR #27 — keep it):

```bash
  halt "usage: spec2pr.sh [--fast] [--implementer codex|claude|claude:sonnet] [--ignore-plan-limit] [--ignore-pr-limit] [--start-from spec-review|plan|plan-review|implementation] [--base <branch>] <spec-path>"
```

- [ ] **Step 6: Fetch the chosen base** — line 165:

```bash
git -C "$GIT_ROOT" fetch -q origin "$BASE_BRANCH" || halt "git fetch origin $BASE_BRANCH failed"
```

- [ ] **Step 7: Validate/adopt the base on resume** — after `BASE_SHA="$(cat "$META_DIR/base-sha")"` (line 185), insert:

```bash
  BASE_SHA="$(cat "$META_DIR/base-sha")"
  if [ -f "$META_DIR/base-branch" ]; then
    RECORDED_BASE_BRANCH="$(cat "$META_DIR/base-branch")"
  else
    RECORDED_BASE_BRANCH="main"
    printf '%s\n' "main" > "$META_DIR/base-branch"
  fi
  if [ "$BASE_BRANCH_GIVEN" -eq 1 ]; then
    [ "$BASE_BRANCH" = "$RECORDED_BASE_BRANCH" ] \
      || halt "worktree base is $RECORDED_BASE_BRANCH; rerun with matching --base or omit the flag"
  else
    BASE_BRANCH="$RECORDED_BASE_BRANCH"
  fi
```

- [ ] **Step 8: Cut the fresh worktree from the chosen base + persist it** — the `else` (fresh-worktree) branch. **Two targeted edits**, so PR #27's `implementer-model` metadata write (which follows `implementer-agent`) is preserved:

  (a) Change the base rev-parse line:

```bash
  BASE_SHA="$(git -C "$GIT_ROOT" rev-parse "origin/$BASE_BRANCH")" || halt "git rev-parse origin/$BASE_BRANCH failed"
```

  (b) Persist the base branch — insert the `base-branch` write immediately after the `base-sha` write (old → new):

```bash
  printf '%s\n' "$BASE_SHA" > "$META_DIR/base-sha"
  printf '%s\n' "$BASE_BRANCH" > "$META_DIR/base-branch"
```

  Leave the `printf … "$META_DIR/implementer-agent"` and `printf … "$META_DIR/implementer-model"` writes that follow exactly as they are.

- [ ] **Step 9: Target the PR at the chosen base** — line 764, in the `gh pr create` call:

```bash
      --base "$BASE_BRANCH" \
```

- [ ] **Step 10: Run the test to verify it passes**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A3 base_`
Expected: PASS on both `test_spec2pr_base_*`.

- [ ] **Step 11: Commit**

```bash
git add scripts/spec2pr.sh tests/spec2pr/test-base.sh
git commit -m "feat(spec2pr): add --base <branch> to cut/target a non-main base

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `spec2pr.sh --no-pr` (+ engine PR-less DONE)

Add the `--no-pr` primitive: run implement and the local pr-review loop, but skip the push + `gh pr create`, and make the engine emit a PR-less DONE.

**Files:**
- Modify: `scripts/spec2pr.sh` (arg loop; restart guard :243; implement-stage PR lookup :586; pr-create block :757-772)
- Modify: `scripts/lib/pr-review-engine.sh` (final push :322; comment :329; DONE :347)
- Create test: `tests/spec2pr/test-no-pr.sh`

**Interfaces:**
- Consumes: `BASE_BRANCH` (Task 1, used by the wrapped pr-create block).
- Produces: `spec2pr.sh --no-pr` flag; terminal line `SPEC2PR DONE worktree=<path>` (no `pr=`); the branch stays local (unpushed).

- [ ] **Step 1: Write the failing test** — create `tests/spec2pr/test-no-pr.sh`:

```bash
#!/usr/bin/env bash
# Tests for spec2pr.sh --no-pr: review still runs, but no push and no PR.

test_spec2pr_no_pr_skips_pr_but_reviews() {
  make_sandbox
  local s; s="$(add_spec nopr-flag)"
  queue_chain_spec 01-nopr-flag nopr-flag

  run_spec2pr --no-pr "$s"

  assert_eq "0" "$RC" "--no-pr run exits 0"
  assert_contains "$OUT" "SPEC2PR DONE worktree=" "--no-pr DONE line carries the worktree"
  assert_not_contains "$OUT" "SPEC2PR DONE pr=" "--no-pr DONE line omits pr="
  assert_contains "$OUT" "pr-review r1" "--no-pr still runs the pr-review loop"
  assert_eq "0" "$(grep -c 'args=pr create' "$SPEC2PR_TEST_GH/gh.log")" "--no-pr never creates a PR"
  assert_eq "" "$(git -C "$PROJECT" ls-remote origin refs/heads/spec2pr/nopr-flag 2>/dev/null || true)" \
    "--no-pr never pushes the branch"
  assert_contains "$(git -C "$PROJECT" show-ref refs/heads/spec2pr/nopr-flag || true)" "spec2pr/nopr-flag" \
    "--no-pr leaves the branch in the local ref store"
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A3 no_pr`
Expected: FAIL on `--no-pr run exits 0` (actual `1`) — `--no-pr` is rejected by the arg loop.

- [ ] **Step 3: Add the `NO_PR` variable** — `scripts/spec2pr.sh`, beside the Task 1 init:

```bash
BASE_BRANCH="main"
BASE_BRANCH_GIVEN=0
NO_PR=0
while [ "$#" -gt 0 ]; do
```

- [ ] **Step 4: Parse `--no-pr`** — add a case before `--*)`:

```bash
    --no-pr)
      NO_PR=1
      shift
      ;;
```

- [ ] **Step 5: Advertise `--no-pr` in usage** — line 8, add `[--no-pr]` after `[--base <branch>]` (final line, building on Task 1 Step 5):

```bash
  halt "usage: spec2pr.sh [--fast] [--implementer codex|claude|claude:sonnet] [--ignore-plan-limit] [--ignore-pr-limit] [--start-from spec-review|plan|plan-review|implementation] [--base <branch>] [--no-pr] <spec-path>"
```

- [ ] **Step 6: Skip the restart-guard PR lookup under `--no-pr`** — lines 243-244:

```bash
  if [ "$NO_PR" -eq 1 ]; then
    open_pr=""
  else
    open_pr="$(cd "$WORKTREE" && gh pr list --head "$BRANCH" --state open --json url --jq '.[0].url // empty')" \
      || halt "gh pr list failed"
  fi
```

- [ ] **Step 7: Skip the implement-stage PR lookup under `--no-pr`** — lines 586-588:

```bash
if [ "$NO_PR" -eq 1 ]; then
  PR_URL=""
elif ! PR_URL="$(cd "$WORKTREE" && gh pr list --head "$BRANCH" --state open --json url --jq '.[0].url // empty')"; then
  halt "gh pr list failed"
fi
```

- [ ] **Step 8: Skip pr-create under `--no-pr`** — wrap the block at lines 757-772 (which already reads `--base "$BASE_BRANCH"` from Task 1):

```bash
  if [ "$NO_PR" -ne 1 ]; then
    STAGE="pr-create"
    git -C "$WORKTREE" push -q -u origin "$BRANCH" || halt "git push failed"
    pr_head_sha="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
    pr_body="$(build_pr_body "$pr_head_sha")"
    if ! pr_create_out="$(cd "$WORKTREE" && gh pr create \
        --title "spec2pr: $SLUG" \
        --body "$pr_body" \
        --base "$BASE_BRANCH" \
        --head "$BRANCH")"; then
      halt "gh pr create failed"
    fi
    PR_URL="$(printf '%s\n' "$pr_create_out" | grep -Eo 'https://[^[:space:]]+' | tail -n1 || true)"
    [ -n "$PR_URL" ] || halt "gh pr create did not return URL"
    status "OK" "pr ok $PR_URL"
  fi
fi
```

- [ ] **Step 9: Skip the final push when there is no PR** — `scripts/lib/pr-review-engine.sh` line 322:

```bash
  if [ -n "$PR_URL" ]; then
    git -C "$WORKTREE" push -q origin "$push_refspec" || halt "final git push failed"
  fi
```

- [ ] **Step 10: Skip the PR comment when there is no PR** — lines 329-331:

```bash
  if [ -n "$PR_URL" ]; then
    if ! (cd "$WORKTREE" && gh pr comment "$PR_URL" --body-file "$comment_body") >/dev/null 2>"$META_DIR/pr-comment.stderr"; then
      status "OK" "pr comment failed $META_DIR/pr-comment.stderr"
    fi
  fi
```

- [ ] **Step 11: Emit a PR-less DONE when there is no PR** — line 347:

```bash
  if [ -n "$PR_URL" ]; then
    finish 0 "DONE pr=$PR_URL worktree=$WORKTREE"
  else
    finish 0 "DONE worktree=$WORKTREE"
  fi
```

- [ ] **Step 12: Run the test to verify it passes**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A3 no_pr`
Expected: PASS on `test_spec2pr_no_pr_skips_pr_but_reviews`.

- [ ] **Step 13: Commit**

```bash
git add scripts/spec2pr.sh scripts/lib/pr-review-engine.sh tests/spec2pr/test-no-pr.sh
git commit -m "feat(spec2pr): add --no-pr (review locally, skip push + PR)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `spec2pr-chain.sh --atomic` — happy path

Add the `--atomic` flag and the full atomic flow: create the integration branch, run each part with `--base <integ> --no-pr`, squash each part into integ via plumbing, roll up once to `main`, clean up. (Resume-skip, the halt note, and the admin retry are added in Tasks 4-6.)

**Files:**
- Modify: `scripts/spec2pr-chain.sh` (define `chain_run_atomic` after `chain_handle_failed_merge` ~303; arg loop :321-348; `status` guard :335; call site after :413; usage :97)
- Create test: `tests/spec2pr/test-atomic-chain.sh`

**Interfaces:**
- Consumes: `spec2pr.sh --base`/`--no-pr` (Tasks 1-2); the `SPEC2PR DONE worktree=` line.
- Produces: `--atomic` flag; integ branch `spec2pr-chain/<chain_id>`; chain-scoped markers `$SPEC2PR_HOME/chains/<chain_id>/<id>.merged` (keys `integ`, `merge`, `staged_at`); terminal line `CHAIN DONE merged=1/1 (atomic: N parts -> main via <url>)`.

- [ ] **Step 1: Write the failing test** — create `tests/spec2pr/test-atomic-chain.sh`:

```bash
#!/usr/bin/env bash
# End-to-end tests for spec2pr-chain.sh --atomic. Reuses queue_chain_spec /
# run_chain from test-chain.sh (all test-*.sh are sourced before any test runs).

test_chain_atomic_lands_split_task_on_main() {
  make_sandbox
  local a b
  a="$(add_spec atom-a)"
  b="$(add_spec atom-b)"
  queue_chain_spec 01-atom-a atom-a
  queue_chain_spec 02-atom-b atom-b marker-atom-a.txt   # part-2 needs part-1 staged on integ

  run_chain --atomic "$a" "$b"

  assert_eq "0" "$RC" "atomic chain exits 0"
  assert_contains "$OUT" "CHAIN OK started specs=2" "atomic started line"
  assert_contains "$OUT" "CHAIN OK staged atom-a on spec2pr-chain/" "part-1 staged on integ"
  assert_contains "$OUT" "CHAIN OK staged atom-b on spec2pr-chain/" "part-2 staged on integ"
  assert_contains "$OUT" "CHAIN DONE merged=1/1 (atomic: 2 parts" "atomic done line"
  assert_eq "1" "$(grep -c 'args=pr create' "$SPEC2PR_TEST_GH/gh.log")" "exactly one PR created (rollup)"
  assert_eq "1" "$(grep -c 'args=pr merge ' "$SPEC2PR_TEST_GH/gh.log")" "exactly one PR merge (rollup)"
  git -C "$PROJECT" fetch -q origin main
  assert_contains "$(git -C "$PROJECT" show origin/main:marker-atom-a.txt 2>/dev/null || true)" "atom-a" \
    "part-1 landed on main"
  assert_contains "$(git -C "$PROJECT" show origin/main:marker-atom-b.txt 2>/dev/null || true)" "atom-b" \
    "part-2 landed on main"
  assert_eq "" "$(git -C "$PROJECT" ls-remote origin 'refs/heads/spec2pr-chain/*' 2>/dev/null || true)" \
    "integ branch deleted on success"
  assert_eq "0" "$(find "$SPEC2PR_HOME/chains" -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')" \
    "chain marker dir removed on success"
  assert_file_absent "$SPEC2PR_WORKTREES/project-atom-a" "part-1 worktree removed"
  assert_file_absent "$SPEC2PR_WORKTREES/project-atom-b" "part-2 worktree removed"
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A3 atomic_lands`
Expected: FAIL on `atomic chain exits 0` (actual `1`) — `--atomic` is rejected by the arg loop (`--*) usage`).

- [ ] **Step 3: Define `chain_run_atomic`** — `scripts/spec2pr-chain.sh`, immediately after `chain_handle_failed_merge` closes (around line 303):

```bash
chain_run_atomic() {
  local integ="spec2pr-chain/$chain_id"
  local marker_dir="$SPEC2PR_HOME/chains/$chain_id"
  mkdir -p "$marker_dir"

  if ! git -C "$GIT_ROOT" fetch -q origin main; then
    chain_finish 1 "HALT: git fetch origin main failed"
  fi
  if ! git -C "$GIT_ROOT" ls-remote --exit-code origin "refs/heads/$integ" >/dev/null 2>&1; then
    local base_sha
    base_sha="$(git -C "$GIT_ROOT" rev-parse origin/main)" \
      || chain_finish 1 "HALT: git rev-parse origin/main failed"
    git -C "$GIT_ROOT" push -q origin "$base_sha:refs/heads/$integ" \
      || chain_finish 1 "HALT: could not create integration branch $integ"
  fi

  local i spec_abs id slug marker branch wt spec_log spec_rc spec_out done_line tree parent sq terminal
  for i in "${!SPEC_ABS_LIST[@]}"; do
    spec_abs="${SPEC_ABS_LIST[$i]}"
    id="${ID_LIST[$i]}"
    slug="${SLUG_LIST[$i]}"
    marker="$marker_dir/$id.merged"
    branch="spec2pr/$slug"

    spec_log="$(mktemp "${TMPDIR:-/tmp}/spec2pr-chain-run.XXXXXX")"
    set +e
    if [ "$FAST" -eq 1 ]; then
      SPEC2PR_PUBLISH_ON_HALT=0 bash "$SCRIPT_DIR/spec2pr.sh" --fast --base "$integ" --no-pr "$spec_abs" 2>&1 | tee "$spec_log"
    else
      SPEC2PR_PUBLISH_ON_HALT=0 bash "$SCRIPT_DIR/spec2pr.sh" --base "$integ" --no-pr "$spec_abs" 2>&1 | tee "$spec_log"
    fi
    spec_rc=${PIPESTATUS[0]}
    set -e
    spec_out="$(cat "$spec_log")"
    rm -f "$spec_log"
    if [ "$spec_rc" -ne 0 ]; then
      terminal="$(printf '%s\n' "$spec_out" | awk '/^SPEC2PR / { line = $0 } END { print line }')"
      [ -n "$terminal" ] || terminal="SPEC2PR failed"
      chain_finish 1 "HALT $slug: $terminal"
    fi

    done_line="$(printf '%s\n' "$spec_out" | awk '/^SPEC2PR DONE / { line = $0 } END { print line }')"
    case "$done_line" in
      "SPEC2PR DONE worktree="*) wt="${done_line#SPEC2PR DONE worktree=}" ;;
      *) chain_finish 1 "HALT $slug: missing SPEC2PR DONE worktree" ;;
    esac
    [ -n "$wt" ] || chain_finish 1 "HALT $slug: empty worktree in SPEC2PR DONE"

    git -C "$GIT_ROOT" fetch -q origin "$integ" || chain_finish 1 "HALT $slug: integ fetch failed"
    tree="$(git -C "$GIT_ROOT" rev-parse "$branch^{tree}")" || chain_finish 1 "HALT $slug: cannot read part tree"
    parent="$(git -C "$GIT_ROOT" rev-parse "origin/$integ")" || chain_finish 1 "HALT $slug: cannot read integ tip"
    sq="$(git -C "$GIT_ROOT" commit-tree "$tree" -p "$parent" -m "spec2pr-chain: $slug")" \
      || chain_finish 1 "HALT $slug: commit-tree failed"
    git -C "$GIT_ROOT" push -q origin "$sq:refs/heads/$integ" \
      || chain_finish 1 "HALT $slug: integ push failed"

    {
      printf 'integ=%s\n' "$integ"
      printf 'merge=%s\n' "$sq"
      printf 'staged_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$marker"
    chain_status "OK staged $slug on $integ"

    git -C "$GIT_ROOT" worktree remove --force "$wt" >/dev/null 2>&1 || true
    git -C "$GIT_ROOT" branch -D "$branch" >/dev/null 2>&1 || true
  done

  # Rollup: one squash PR integ -> main, from a temporary worktree checked out
  # on integ so the local HEAD is integ for the merge (no --delete-branch, so gh
  # runs no local checkout; the temp branch is integ, never main).
  git -C "$GIT_ROOT" fetch -q origin main "$integ" || chain_finish 1 "HALT rollup: fetch failed"
  local rwt body pr_url merge_err merge_rc
  rwt="$SPEC2PR_WORKTREES/rollup-$chain_id"
  rm -rf "$rwt"
  mkdir -p "$SPEC2PR_WORKTREES"
  git -C "$GIT_ROOT" worktree add -q -B "$integ" "$rwt" "origin/$integ" \
    || chain_finish 1 "HALT rollup: could not create integ worktree"
  body="Atomic spec2pr-chain rollup of $total part(s)."
  pr_url="$(cd "$rwt" && gh pr create --base main --head "$integ" \
    --title "spec2pr-chain: $chain_id ($total parts)" --body "$body" 2>/dev/null)"
  pr_url="$(printf '%s\n' "$pr_url" | grep -Eo 'https://[^[:space:]]+' | tail -n1 || true)"
  if [ -z "$pr_url" ]; then
    git -C "$GIT_ROOT" worktree remove --force "$rwt" >/dev/null 2>&1 || true
    git -C "$GIT_ROOT" branch -D "$integ" >/dev/null 2>&1 || true
    chain_finish 1 "HALT rollup: gh pr create failed"
  fi

  set +e
  merge_err="$(cd "$rwt" && gh pr merge "$pr_url" --squash 2>&1 1>/dev/null)"
  merge_rc=$?
  set -e
  git -C "$GIT_ROOT" worktree remove --force "$rwt" >/dev/null 2>&1 || true
  git -C "$GIT_ROOT" branch -D "$integ" >/dev/null 2>&1 || true
  if [ "$merge_rc" -ne 0 ]; then
    chain_finish 1 "HALT rollup: $merge_err (integ $integ holds the full task; merge it to main manually or re-run)"
  fi

  git -C "$GIT_ROOT" push -q origin --delete "$integ" >/dev/null 2>&1 || true
  rm -rf "$marker_dir"
  chain_finish 0 "DONE merged=1/1 (atomic: $total parts -> main via $pr_url)"
}
```

- [ ] **Step 4: Add the `ATOMIC` variable** — line 322 area:

```bash
FAST=0
ADMIN=0
ATOMIC=0
SPECS=()
```

- [ ] **Step 5: Parse `--atomic` and guard `status`** — add the case after `--admin` (line 333), and extend the `status` guard (line 335):

```bash
    --admin)
      ADMIN=1
      shift
      ;;
    --atomic)
      ATOMIC=1
      shift
      ;;
    status)
      [ "$ADMIN" -eq 0 ] || usage
      [ "$ATOMIC" -eq 0 ] || usage
      shift
      [ "$#" -eq 0 ] || usage
      show_status
      ;;
```

- [ ] **Step 6: Advertise `--atomic` in usage** — line 97:

```bash
  chain_finish 1 "HALT: usage: spec2pr-chain.sh status | [--fast] [--admin] [--atomic] <spec-path> [<spec-path>...] (--admin/--atomic specs only)"
```

- [ ] **Step 7: Dispatch to the atomic flow** — after `chain_status "OK started specs=$total"` (line 413):

```bash
chain_status "OK started specs=$total"

if [ "$ATOMIC" -eq 1 ]; then
  chain_run_atomic
fi

merged_count=0
```

(`chain_run_atomic` always ends in `chain_finish`, so the eager loop below runs only in non-atomic mode.)

- [ ] **Step 8: Run the test to verify it passes**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A3 atomic_lands`
Expected: PASS on `test_chain_atomic_lands_split_task_on_main`.

- [ ] **Step 9: Commit**

```bash
git add scripts/spec2pr-chain.sh tests/spec2pr/test-atomic-chain.sh
git commit -m "feat(spec2pr-chain): add --atomic (stage on integ, one squash to main)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `--atomic` resume (skip already-staged parts)

Re-running the identical `--atomic` command must skip parts already squashed onto integ, validating against `origin/<integ>`.

**Files:**
- Modify: `scripts/spec2pr-chain.sh` (`chain_run_atomic` per-part loop)
- Modify: `tests/spec2pr/test-atomic-chain.sh` (add resume test)

**Interfaces:**
- Consumes: chain-scoped markers written in Task 3.

- [ ] **Step 1: Write the failing test** — append to `tests/spec2pr/test-atomic-chain.sh`:

```bash
# Compute the chain_id the chain derives from the canonical absolute spec paths:
# newline-joined "$(cd dir && pwd -P)/basename", hashed (sha256, first 12 chars).
# The trailing-newline strip matches the chain's command-substitution stripping.
atomic_chain_id() { # <abs-spec>...
  local input="" p dir
  for p in "$@"; do
    dir="$(cd "$(dirname "$p")" && pwd -P)"
    input="${input}${dir}/$(basename "$p")"$'\n'
  done
  input="${input%$'\n'}"
  printf 'chain-%s\n' "$(printf '%s' "$input" | sha256sum | awk '{print substr($1,1,12)}')"
}

test_chain_atomic_resume_skips_staged_part() {
  make_sandbox
  local a b cid integ sq
  a="$(add_spec atom-a)"
  b="$(add_spec atom-b)"
  cid="$(atomic_chain_id "$a" "$b")"
  integ="spec2pr-chain/$cid"

  # Pre-stage part-1 onto integ on origin (as a completed first run would have).
  git -C "$PROJECT" checkout -q -b "$integ" main
  printf 'atom-a\n' > "$PROJECT/marker-atom-a.txt"
  git -C "$PROJECT" add marker-atom-a.txt
  git -C "$PROJECT" commit -qm "spec2pr-chain: atom-a"
  sq="$(git -C "$PROJECT" rev-parse "$integ")"
  git -C "$PROJECT" push -q origin "$integ"
  git -C "$PROJECT" checkout -q main
  git -C "$PROJECT" branch -D "$integ"
  mkdir -p "$SPEC2PR_HOME/chains/$cid"
  { printf 'integ=%s\n' "$integ"; printf 'merge=%s\n' "$sq"; } \
    > "$SPEC2PR_HOME/chains/$cid/project-atom-a.merged"

  queue_chain_spec 02-atom-b atom-b marker-atom-a.txt   # only part-2 is queued

  run_chain --atomic "$a" "$b"

  assert_eq "0" "$RC" "resumed atomic run exits 0"
  assert_contains "$OUT" "CHAIN OK skipped atom-a (already on integ)" "resume skips staged part-1"
  assert_contains "$OUT" "CHAIN DONE merged=1/1" "resume reaches done"
  git -C "$PROJECT" fetch -q origin main
  assert_contains "$(git -C "$PROJECT" show origin/main:marker-atom-a.txt 2>/dev/null || true)" "atom-a" \
    "part-1 lands on main after resume"
  assert_contains "$(git -C "$PROJECT" show origin/main:marker-atom-b.txt 2>/dev/null || true)" "atom-b" \
    "part-2 lands on main after resume"
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A3 atomic_resume`
Expected: FAIL — without the skip block the chain re-runs part-1, but only part-2's fixtures are queued, so part-1's spec2pr halts → `CHAIN HALT atom-a` and `RC=1`.

- [ ] **Step 3: Add the marker-skip block** — in `chain_run_atomic`, extend the loop's `local` list and insert the skip block right after `branch="spec2pr/$slug"`:

```bash
  local i spec_abs id slug marker branch wt spec_log spec_rc spec_out done_line tree parent sq terminal merge_sq integ_rec
  for i in "${!SPEC_ABS_LIST[@]}"; do
    spec_abs="${SPEC_ABS_LIST[$i]}"
    id="${ID_LIST[$i]}"
    slug="${SLUG_LIST[$i]}"
    marker="$marker_dir/$id.merged"
    branch="spec2pr/$slug"

    if [ -f "$marker" ]; then
      merge_sq="$(awk -F= '$1=="merge"{print $2; exit}' "$marker")"
      integ_rec="$(awk -F= '$1=="integ"{print $2; exit}' "$marker")"
      git -C "$GIT_ROOT" fetch -q origin "$integ" 2>/dev/null || true
      if [ -n "$merge_sq" ] && [ "$integ_rec" = "$integ" ] \
          && git -C "$GIT_ROOT" cat-file -e "$merge_sq^{commit}" 2>/dev/null \
          && git -C "$GIT_ROOT" merge-base --is-ancestor "$merge_sq" "origin/$integ"; then
        chain_status "OK skipped $slug (already on integ)"
        continue
      fi
      chain_finish 1 "HALT $slug: stale merged marker"
    fi

    spec_log="$(mktemp "${TMPDIR:-/tmp}/spec2pr-chain-run.XXXXXX")"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A3 atomic_resume`
Expected: PASS on `test_chain_atomic_resume_skips_staged_part`.

- [ ] **Step 5: Commit**

```bash
git add scripts/spec2pr-chain.sh tests/spec2pr/test-atomic-chain.sh
git commit -m "feat(spec2pr-chain): resume an atomic chain by skipping staged parts

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: `--atomic` halt keeps `main` pristine

A mid-chain halt must leave `main` with no chain commits, preserve integ, keep the part's marker, and name the recovery path in the halt line.

**Files:**
- Modify: `scripts/spec2pr-chain.sh` (`chain_run_atomic` per-part halt message)
- Modify: `tests/spec2pr/test-atomic-chain.sh` (add halt test)

- [ ] **Step 1: Write the failing test** — append to `tests/spec2pr/test-atomic-chain.sh`:

```bash
test_chain_atomic_halt_keeps_main_pristine() {
  make_sandbox
  local a b
  a="$(add_spec atom-a)"
  b="$(add_spec atom-b)"
  queue_chain_spec 01-atom-a atom-a
  queue_chain_spec_dirty 2 atom-b           # part-2 spec-review stays blocked -> DIRTY

  export MAX_FIX_ROUNDS=3
  run_chain --atomic "$a" "$b"
  unset MAX_FIX_ROUNDS

  assert_eq "1" "$RC" "atomic halt exits 1"
  assert_contains "$OUT" "CHAIN HALT atom-b" "atomic halts on part-2"
  assert_contains "$OUT" "integ spec2pr-chain/" "halt note names the integ branch"
  assert_contains "$OUT" "re-run to resume" "halt note points at the resume path"
  assert_eq "0" "$(grep -c 'args=pr merge ' "$SPEC2PR_TEST_GH/gh.log")" "no rollup merge on halt"
  assert_eq "0" "$(grep -c 'args=pr create' "$SPEC2PR_TEST_GH/gh.log")" "no PR created on halt"
  git -C "$PROJECT" fetch -q origin main
  assert_eq "" "$(git -C "$PROJECT" show origin/main:marker-atom-a.txt 2>/dev/null || true)" \
    "main has no part-1 marker after halt"
  assert_eq "1" "$(git -C "$PROJECT" ls-remote origin 'refs/heads/spec2pr-chain/*' | wc -l | tr -d ' ')" \
    "integ branch preserved on halt"
  assert_eq "1" "$(find "$SPEC2PR_HOME/chains" -name 'project-atom-a.merged' 2>/dev/null | wc -l | tr -d ' ')" \
    "part-1 marker persists for resume"
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A3 atomic_halt`
Expected: FAIL on `halt note names the integ branch` — Task 3's per-part halt message is the plain `HALT $slug: $terminal`, with no integ/resume note. (The pristine-main and integ-preserved assertions already pass.)

- [ ] **Step 3: Enrich the per-part halt message** — in `chain_run_atomic`, the `spec_rc != 0` branch:

```bash
    if [ "$spec_rc" -ne 0 ]; then
      terminal="$(printf '%s\n' "$spec_out" | awk '/^SPEC2PR / { line = $0 } END { print line }')"
      [ -n "$terminal" ] || terminal="SPEC2PR failed"
      chain_finish 1 "HALT $slug: $terminal (atomic: nothing merged to main; integ $integ holds completed parts; re-run to resume)"
    fi
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A3 atomic_halt`
Expected: PASS on `test_chain_atomic_halt_keeps_main_pristine`.

- [ ] **Step 5: Commit**

```bash
git add scripts/spec2pr-chain.sh tests/spec2pr/test-atomic-chain.sh
git commit -m "feat(spec2pr-chain): name integ + resume path in atomic halt line

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: `--atomic` rollup `--admin` retry

When the rollup `integ → main` merge is blocked by branch protection, retry with `--admin` if the chain was invoked with `--admin`; otherwise halt with integ preserved.

**Files:**
- Modify: `scripts/spec2pr-chain.sh` (`chain_run_atomic` rollup merge)
- Modify: `tests/spec2pr/test-atomic-chain.sh` (add admin + blocked-without-admin tests)

- [ ] **Step 1: Write the failing tests** — append to `tests/spec2pr/test-atomic-chain.sh`:

```bash
test_chain_atomic_rollup_admin_retry() {
  make_sandbox
  local a b
  a="$(add_spec atom-a)"
  b="$(add_spec atom-b)"
  queue_chain_spec 01-atom-a atom-a
  queue_chain_spec 02-atom-b atom-b marker-atom-a.txt
  printf 'Protected branch update failed\n' > "$SPEC2PR_TEST_GH/pr-merge-fail-once"

  run_chain --atomic --admin "$a" "$b"

  assert_eq "0" "$RC" "atomic --admin rollup exits 0"
  assert_contains "$OUT" "CHAIN DONE merged=1/1" "admin rollup reaches done"
  assert_eq "2" "$(grep -c 'args=pr merge ' "$SPEC2PR_TEST_GH/gh.log")" "rollup retries the merge under --admin"
  assert_eq "1" "$(grep -c 'args=pr merge .*--admin' "$SPEC2PR_TEST_GH/gh.log")" "rollup retry passes --admin"
}

test_chain_atomic_rollup_blocked_without_admin_halts() {
  make_sandbox
  local a b
  a="$(add_spec atom-a)"
  b="$(add_spec atom-b)"
  queue_chain_spec 01-atom-a atom-a
  queue_chain_spec 02-atom-b atom-b marker-atom-a.txt
  printf 'Protected branch update failed\n' > "$SPEC2PR_TEST_GH/pr-merge-fail"

  run_chain --atomic "$a" "$b"

  assert_eq "1" "$RC" "atomic rollup blocked without admin halts"
  assert_contains "$OUT" "CHAIN HALT rollup:" "rollup halt line"
  assert_eq "1" "$(git -C "$PROJECT" ls-remote origin 'refs/heads/spec2pr-chain/*' | wc -l | tr -d ' ')" \
    "integ preserved when rollup halts"
  git -C "$PROJECT" fetch -q origin main
  assert_eq "" "$(git -C "$PROJECT" show origin/main:marker-atom-a.txt 2>/dev/null || true)" \
    "main untouched when rollup blocked"
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A3 atomic_rollup`
Expected: `admin_retry` FAILs `atomic --admin rollup exits 0` (Task 3's rollup has no retry, so the single blocked attempt halts). `blocked_without_admin_halts` already passes.

- [ ] **Step 3: Add the admin retry** — in `chain_run_atomic`, replace the single rollup merge attempt with a retry:

```bash
  set +e
  merge_err="$(cd "$rwt" && gh pr merge "$pr_url" --squash 2>&1 1>/dev/null)"
  merge_rc=$?
  if [ "$merge_rc" -ne 0 ] && [ "$ADMIN" -eq 1 ]; then
    merge_err="$(cd "$rwt" && gh pr merge "$pr_url" --squash --admin 2>&1 1>/dev/null)"
    merge_rc=$?
  fi
  set -e
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A3 atomic_rollup`
Expected: PASS on both `test_chain_atomic_rollup_*`.

- [ ] **Step 5: Commit**

```bash
git add scripts/spec2pr-chain.sh tests/spec2pr/test-atomic-chain.sh
git commit -m "feat(spec2pr-chain): retry atomic rollup with --admin when blocked

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Full-suite verification (in a subagent)

Run the entire `tests/spec2pr/` suite once, confirming the new behavior and that the eager path and spec2pr defaults are unregressed. The suite is multi-minute and noisy, so run it in a subagent.

**Files:** none (verification only).

- [ ] **Step 1: Dispatch a subagent to run the full suite**

Dispatch one subagent (Agent tool, `general-purpose`) with this prompt:

```
Run: bash tests/spec2pr/run-tests.sh
from the repo root /Users/rulez/Dropbox/Projects/26.03-shared-tools.
This takes several minutes. Do not summarize the per-test "ok:" lines.
Return ONLY: (a) the final "N tests run, M failed" line, and (b) for every
FAIL, its full block (the FAIL line plus the expected/actual lines).
```

- [ ] **Step 2: Confirm green**

Expected: the subagent reports `… tests run, 0 failed`. If any test failed, fix the cause (return to the relevant task; do not edit `VERSION`/`UPGRADE.md`), re-run the focused file, then re-dispatch this full-suite subagent.

- [ ] **Step 3: No commit** (verification only; all code was committed per task).

---

## Notes for the implementer

- **`--base` resume fetch ordering:** `spec2pr.sh:165` fetches `origin/$BASE_BRANCH` using the value parsed from the CLI before the resume-metadata read. The chain always passes `--base <integ>` on every part run (including resumes), so the fetch target is always correct in the atomic flow. A *manual* resume that omits `--base` will fetch `origin/main` at :165 and then adopt the recorded base from metadata; harmless, because a resumed run reads `BASE_SHA` from metadata and does not re-cut the worktree.
- **Why plumbing for part→integ but a worktree for the rollup:** part→integ is conflict-free (each part is cut from the current integ tip under the per-repo lock), so `commit-tree` + push needs no checkout. The rollup is a real PR; the test stub's `gh pr merge` lands the **cwd** `HEAD` on `main`, and real `gh pr merge --squash` is a server-side squash — running it from a temporary worktree checked out on integ satisfies both, and (no `--delete-branch`, temp branch is integ not main) it cannot hit the `main is already used by worktree` failure class.
- **Single-commit-on-main** is real `gh --squash` behavior; the stub fast-forward-pushes, so the atomic tests assert content + one `pr merge` call, consistent with how the existing eager tests assert content rather than commit topology.
