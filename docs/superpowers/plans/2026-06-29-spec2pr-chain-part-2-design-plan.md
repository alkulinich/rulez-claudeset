# spec2pr chain — part 2: conflict resolution & branch-protection handling — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade `scripts/spec2pr-chain.sh`'s blanket "merge failed" halt into merge-state-aware handling: auto-resolve a genuine conflict with a codex call, bring a `BEHIND` branch up to date, and offer an opt-in `--admin` bypass of branch protection.

**Architecture:** The optimistic `gh pr merge` from part 1 is unchanged; only its *failure* branch changes from an immediate halt to "inspect with `gh pr view --json`, then dispatch." A new set of `chain_*` shell functions handles inspection (validated with `jq`), conflict resolution (codex edits the worktree, hard post-condition gates, audit trail), behind-branch update (plain merge, no model), and a retry wrapper. Tests drive the real `spec2pr.sh` in a git sandbox with stubbed `codex`/`gh`; a new stub-gh mode lands a divergent commit on `origin/main` mid-chain to manufacture a real local conflict.

**Tech Stack:** Bash 3.2+ (`set -euo pipefail`), `git`, `gh` CLI, `jq`, codex CLI (honored via `SPEC2PR_CODEX_BIN`). Tests are the repo's home-grown bash harness (`tests/spec2pr/run-tests.sh`).

## Global Constraints

- **Bash 3.2 compatible** — no `declare -A`, no associative arrays. A test (`test_chain_script_avoids_bash4_associative_arrays`) enforces this.
- **Script runs under `set -euo pipefail`** — every command that may exit non-zero in the normal flow must be wrapped (`set +e`/`set -e`, `|| chain_finish ...`, or guarded by `if`). An unwrapped failure trips the EXIT trap and yields `CHAIN HALT: unexpected exit`, which the design forbids for every enumerated case.
- **All halts use `chain_finish 1 "HALT <slug>: <reason>"`** (defined in `scripts/spec2pr-chain.sh`). Never let an enumerated failure fall through to the generic `chain_on_exit` trap.
- **Never call `chain_finish` inside a `$(...)` command substitution** — `exit` there only kills the subshell. Inspection sets globals and halts in the main shell instead.
- **Merge, never rebase/force-push** the PR branch (it is live under a PR). The conflict and behind paths merge `origin/main` into the branch and push the branch ref forward.
- **`--admin` is off by default** and only affects the `BLOCKED` path. It never widens conflict handling.
- **Honor `SPEC2PR_CODEX_BIN`** for the codex binary; do not hard-code `codex`.
- **`jq` parsing only** for merge-state JSON — no shell string matching. The inspected payload must be exactly one top-level JSON object (reject arrays, scalars, multiple concatenated texts, missing/non-string fields).
- **A spec's meta dir is `$SPEC2PR_HOME/$id`** where `id="<repo-slug>-<spec-slug>"` (identical to `spec2pr.sh`'s `ID`; that script already created the dir).
- **VERSION bump is patch-level** over part 1 (`1.10.0` → `1.10.1`).

---

## File Structure

- **`scripts/spec2pr-chain.sh`** (edit) — the orchestrator. Adds `--admin` parsing, a `jq` dependency check, a chain-scoped tmp dir for the codex schema, and the merge-state handler functions. The optimistic-merge call site changes one line (halt → handler call).
- **`commands/rulez/spec2pr-chain.md`** (edit) — documents and forwards `/rulez:spec2pr-chain --admin [--fast] <spec…>`.
- **`tests/spec2pr/stub-gh.sh`** (edit) — `pr merge` gains a fail-once mode and a "land a divergent commit on `origin/main` then fail" mode. `pr view --json` already returns a fixture from `pr-view-json`; `pr merge --admin` already passes through (the stub matches only `$1 $2`).
- **`tests/spec2pr/test-chain.sh`** (edit) — new end-to-end cases for behind / conflict / blocked / inspection-failure / unsupported-state.
- **`VERSION`** (edit) — `1.10.0` → `1.10.1`.
- **`UPGRADE.md`** (edit) — a new `## To v1.10.1 - from v1.10.0` section.

**Reference reading before you start** (do not edit): `scripts/lib/spec2pr-runtime.sh` (sourced by the chain; defines `sanitize`, `require_codex` pattern, the codex schema style), `tests/spec2pr/helpers.sh` (`make_sandbox`, `add_spec`, `queue_chain_spec`, `enqueue`, `run_chain`, `codex_calls`, asserts), `tests/spec2pr/stub-codex.sh` (consumes fixtures named `[0-9]*.sh` in lexical order, one per codex call).

### How the test harness fits the new code

- `queue_chain_spec <prefix> <slug> [prereq]` enqueues exactly **4 codex** fixtures (spec-review, plan-review, implement, pr-review-b-classify) and **3 claude** fixtures (plan, forecast, pr-review-a) for one spec2pr run. So in any chain test, `codex_calls` is **4** per spec before any conflict-resolve call; the conflict path adds **one** (→ 5).
- `stub-codex.sh` consumes the lexically-smallest remaining `[0-9]*.sh` fixture per call. With a spec queued under prefix `01-<slug>` (fixtures `01-<slug>-01-…` … `01-<slug>-07-…`), enqueue the chain's conflict-resolve fixture as `02-<slug>-resolve` so it is consumed **after** spec2pr's own codex calls.
- The chain runs `gh pr merge` from inside the worktree (`cd "$wt" && gh pr merge …`), so the stub's `git push … HEAD:refs/heads/main` pushes the worktree HEAD. The stub's divergent-commit mode clones `origin` fresh (via `git remote get-url origin`, which worktrees inherit) so it never dirties the worktree.

---

## Task 1: `--admin` flag parsing + command doc

**Files:**
- Modify: `scripts/spec2pr-chain.sh` (the `FAST=0` declaration ~line 119; the arg-parse `while`/`case` ~lines 121-140)
- Modify: `commands/rulez/spec2pr-chain.md` (Usage section; Instructions steps 1 and 3)
- Test: `tests/spec2pr/test-chain.sh`

**Interfaces:**
- Consumes: nothing from later tasks.
- Produces: a global `ADMIN` (`0`/`1`) read by the dispatcher in Tasks 2-4.

- [ ] **Step 1: Write the failing tests**

Add to `tests/spec2pr/test-chain.sh`:

```bash
test_chain_admin_flag_accepted_on_happy_path() {
  make_sandbox
  local a; a="$(add_spec chain-okadmin)"
  queue_chain_spec 01-chain-okadmin chain-okadmin

  run_chain --admin "$a"

  assert_eq "0" "$RC" "--admin happy chain exits 0"
  assert_contains "$OUT" "CHAIN DONE merged=1/1" "--admin happy chain reaches done"
  assert_not_contains "$OUT" "HALT: usage" "--admin is a recognized flag"
}

test_chain_admin_and_fast_flags_combine() {
  make_sandbox
  local a; a="$(add_spec chain-okboth)"
  queue_chain_spec 01-chain-okboth chain-okboth

  run_chain --admin --fast "$a"

  assert_eq "0" "$RC" "--admin --fast chain exits 0"
  assert_contains "$OUT" "CHAIN DONE merged=1/1" "--admin --fast reaches done"
}

test_chain_admin_does_not_apply_to_status() {
  make_sandbox

  run_chain --admin status

  assert_eq "1" "$RC" "--admin status exits usage"
  assert_contains "$OUT" "CHAIN HALT: usage:" "--admin is not accepted for status"
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A4 'test_chain_admin'`
Expected: FAIL — the happy-path `--admin` tests currently hit the `--*) usage`
arm, so output contains `CHAIN HALT: usage:` and exits 1; the status test
documents the required invariant that `--admin` does not apply to `status`.

- [ ] **Step 3: Add the `ADMIN` global and the `--admin` parse arm**

In `scripts/spec2pr-chain.sh`, change the flags declaration:

```bash
FAST=0
ADMIN=0
SPECS=()
```

Then add an `--admin` case to the arg-parse `while` loop, **before** the `--*) usage ;;` catch-all:

```bash
    --fast)
      FAST=1
      shift
      ;;
    --admin)
      ADMIN=1
      shift
      ;;
    status)
      [ "$ADMIN" -eq 0 ] || usage
      shift
      [ "$#" -eq 0 ] || usage
      show_status
      ;;
```

- [ ] **Step 4: Update the command doc**

In `commands/rulez/spec2pr-chain.md`, replace the Usage bullets with:

```markdown
- `/rulez:spec2pr-chain <spec…>` — run the ordered list of specs
- `/rulez:spec2pr-chain --fast <spec…>` — forward `--fast` to each spec2pr run
- `/rulez:spec2pr-chain --admin [--fast] <spec…>` — also allow merging past
  branch protection (uses `gh pr merge --admin`) when a PR is `BLOCKED`. Off by
  default; the chain never silently overrides a protection you set.
- `/rulez:spec2pr-chain status` — show the latest state of every chain
```

In the Instructions, replace step 1 with:

```markdown
1. Parse optional leading `--admin` and `--fast` flags (either order); everything
   after them is the ordered spec list. Require at least one spec path.
```

And replace step 3's command line with:

```markdown
   `bash ~/.claude/skills/rulez-claudeset/scripts/spec2pr-chain.sh [--admin] [--fast] <spec…>`
   Pass `--admin` and/or `--fast` only if the user supplied them.
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | tail -3`
Expected: PASS — `0 failed`. The two new `test_chain_admin_*` cases reach `CHAIN DONE merged=1/1`.

- [ ] **Step 6: Commit**

```bash
git add scripts/spec2pr-chain.sh commands/rulez/spec2pr-chain.md tests/spec2pr/test-chain.sh
git commit -m "feat(spec2pr-chain): parse --admin flag and document it"
```

---

## Task 2: Merge-state inspection, dispatcher, BEHIND path, retry helper, stub-gh modes

**Files:**
- Modify: `tests/spec2pr/stub-gh.sh` (the `"pr merge")` arm ~lines 63-70; header comment ~lines 11-12)
- Modify: `scripts/spec2pr-chain.sh` (add `jq` dependency check after the `gh` check ~line 145; add helper functions after `chain_require_dependency` ~line 103; change the merge-failure call site ~lines 262-264)
- Test: `tests/spec2pr/test-chain.sh`

**Interfaces:**
- Consumes: global `ADMIN` (Task 1).
- Produces:
  - `chain_inspect_merge_state <wt> <pr_url> <slug>` — sets globals `MERGEABLE` and `MSS` to the two validated string fields, or `chain_finish 1 "HALT <slug>: merge state inspection failed"`.
  - `chain_retry_merge <wt> <pr_url> <slug> [extra-gh-flags…]` — wrapped `gh pr merge … --squash --delete-branch`; halts `merge retry failed (<stderr>)` on failure, returns 0 on success.
  - `chain_update_behind <wt> <pr_url> <slug>` — fetch + clean merge + push + retry; halts `branch update failed` on fetch/merge/push failure.
  - `chain_handle_failed_merge <wt> <pr_url> <slug> <id> <merge_err>` — the dispatcher; returns 0 once a merge succeeds so the loop proceeds to marker-writing.
  - stub-gh `pr merge` recognizes `$SPEC2PR_TEST_GH/pr-merge-fail-once` and `$SPEC2PR_TEST_GH/pr-merge-diverge`.

- [ ] **Step 1: Extend the gh stub**

In `tests/spec2pr/stub-gh.sh`, replace the `"pr merge")` arm with:

```bash
  "pr merge")
    if [ -f "$dir/pr-merge-diverge" ]; then
      # Simulate an external commit landing on origin/main mid-chain. Line 1 of
      # the file is a repo-relative path; lines 2+ are its new content. We fail
      # like fail-once after pushing, so the chain's retry merge can succeed.
      div_path="$(sed -n '1p' "$dir/pr-merge-diverge")"
      div_body="$(sed -n '2,$p' "$dir/pr-merge-diverge")"
      origin_url="$(git remote get-url origin)"
      tmp_clone="$(mktemp -d)"
      git clone -q "$origin_url" "$tmp_clone"
      git -C "$tmp_clone" checkout -q main
      printf '%s\n' "$div_body" > "$tmp_clone/$div_path"
      git -C "$tmp_clone" add "$div_path"
      git -C "$tmp_clone" -c user.email=div@test -c user.name=divergent \
        commit -qm 'external main commit'
      git -C "$tmp_clone" push -q origin main
      rm -rf "$tmp_clone"
      rm -f "$dir/pr-merge-diverge"
      echo "Pull request is not mergeable" >&2
      exit 9
    fi
    if [ -f "$dir/pr-merge-fail-once" ]; then
      cat "$dir/pr-merge-fail-once" >&2
      rm -f "$dir/pr-merge-fail-once"
      exit 9
    fi
    if [ -f "$dir/pr-merge-fail" ]; then
      cat "$dir/pr-merge-fail" >&2
      exit 9
    fi
    git push -q origin HEAD:refs/heads/main
    echo "merged"
    ;;
```

Update the header comment block to document the two new files (insert after the `pr-merge-fail` line ~12):

```bash
#   pr-merge-fail-once - like pr-merge-fail but only for the FIRST `pr merge`
#                   call; the file is removed so a retry succeeds
#   pr-merge-diverge - line 1 = path, lines 2+ = content; on the first `pr merge`
#                   call, lands that file as a commit on origin/main, then fails
#                   like fail-once (used to manufacture a real mid-chain conflict)
```

- [ ] **Step 2: Write the failing tests**

Add to `tests/spec2pr/test-chain.sh`:

```bash
test_chain_behind_merge_updates_and_retries() {
  make_sandbox
  local a; a="$(add_spec chain-behind)"
  queue_chain_spec 01-chain-behind chain-behind
  # First merge: land an UNRELATED commit on origin/main (clean merge), then fail.
  printf 'behind-extra.txt\nlanded on main while the chain ran\n' \
    > "$SPEC2PR_TEST_GH/pr-merge-diverge"
  printf '{"mergeable":"MERGEABLE","mergeStateStatus":"BEHIND"}' \
    > "$SPEC2PR_TEST_GH/pr-view-json"

  run_chain "$a"

  assert_eq "0" "$RC" "behind chain exits 0"
  assert_contains "$OUT" "CHAIN DONE merged=1/1" "behind chain reaches done"
  assert_eq "4" "$(codex_calls)" "behind path runs no extra codex call"
  assert_eq "2" "$(grep -c 'args=pr merge ' "$SPEC2PR_TEST_GH/gh.log")" \
    "behind path retries the merge once"
  git -C "$PROJECT" fetch -q origin main
  assert_contains "$(git -C "$PROJECT" show origin/main:behind-extra.txt 2>/dev/null || true)" \
    "landed on main" "external behind commit is on main"
  assert_contains "$(git -C "$PROJECT" show origin/main:marker-chain-behind.txt 2>/dev/null || true)" \
    "chain-behind" "merged branch marker reached main"
}

test_chain_inspection_rejects_malformed_shape() {
  local payload
  for payload in \
    '[{"mergeable":"MERGEABLE","mergeStateStatus":"BEHIND"}]' \
    '{"mergeable":"MERGEABLE"}' \
    '{"mergeable":1,"mergeStateStatus":"BEHIND"}' \
    '{"mergeable":"MERGEABLE","mergeStateStatus":"BEHIND"}{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}'
  do
    make_sandbox
    local a; a="$(add_spec chain-bad)"
    queue_chain_spec 01-chain-bad chain-bad
    printf 'optimistic merge failed\n' > "$SPEC2PR_TEST_GH/pr-merge-fail-once"
    printf '%s' "$payload" > "$SPEC2PR_TEST_GH/pr-view-json"

    run_chain "$a"

    assert_eq "1" "$RC" "malformed payload halts: $payload"
    assert_contains "$OUT" "CHAIN HALT chain-bad: merge state inspection failed" \
      "malformed payload halt line: $payload"
    assert_eq "4" "$(codex_calls)" "malformed payload runs no conflict codex call: $payload"
    assert_eq "1" "$(grep -c 'args=pr merge ' "$SPEC2PR_TEST_GH/gh.log")" \
      "malformed payload does not retry the merge: $payload"
  done
}

test_chain_unsupported_merge_state_halts() {
  local payload
  for payload in \
    '{"mergeable":"UNKNOWN","mergeStateStatus":"CLEAN"}' \
    '{"mergeable":"MERGEABLE","mergeStateStatus":"UNKNOWN"}'
  do
    make_sandbox
    local a; a="$(add_spec chain-unsup)"
    queue_chain_spec 01-chain-unsup chain-unsup
    printf 'optimistic merge rejected\n' > "$SPEC2PR_TEST_GH/pr-merge-fail-once"
    printf '%s' "$payload" > "$SPEC2PR_TEST_GH/pr-view-json"

    run_chain "$a"

    assert_eq "1" "$RC" "unsupported state halts: $payload"
    assert_contains "$OUT" "CHAIN HALT chain-unsup: merge state unsupported" \
      "unsupported halt line: $payload"
    assert_contains "$OUT" "optimistic merge rejected" \
      "unsupported halt includes the gh stderr: $payload"
    assert_eq "4" "$(codex_calls)" "unsupported state runs no conflict codex call: $payload"
    assert_eq "1" "$(grep -c 'args=pr merge ' "$SPEC2PR_TEST_GH/gh.log")" \
      "unsupported state does not retry the merge: $payload"
  done
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A4 'test_chain_behind_merge\|test_chain_inspection_rejects\|test_chain_unsupported'`
Expected: FAIL — today any merge failure produces `CHAIN HALT <slug>: merge failed (…)`, not the inspection/behind/unsupported lines, and the behind case never retries (1 merge call, no `CHAIN DONE`).

- [ ] **Step 4: Add the `jq` dependency check**

In `scripts/spec2pr-chain.sh`, after `chain_require_dependency gh`:

```bash
chain_require_dependency git
chain_require_dependency gh
chain_require_dependency jq
```

- [ ] **Step 5: Add the inspection, retry, behind, and dispatcher functions**

In `scripts/spec2pr-chain.sh`, after the `chain_require_dependency()` function definition (~line 103), add:

```bash
# chain_inspect_merge_state <wt> <pr_url> <slug>
# Sets globals MERGEABLE and MSS from `gh pr view --json`. The payload must be
# exactly one top-level JSON object with string mergeable/mergeStateStatus
# fields; anything else (gh failure, invalid JSON, wrong shape, missing/
# non-string field, multiple concatenated texts) halts. Halts run in the main
# shell, never inside a command substitution.
chain_inspect_merge_state() {
  local wt="$1" pr_url="$2" slug="$3" json rc
  set +e
  json="$(cd "$wt" && gh pr view "$pr_url" --json mergeable,mergeStateStatus 2>/dev/null)"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || chain_finish 1 "HALT $slug: merge state inspection failed"
  if ! printf '%s' "$json" | jq -e -s \
      'length == 1 and (.[0] | type == "object")
       and (.[0].mergeable | type == "string")
       and (.[0].mergeStateStatus | type == "string")' >/dev/null 2>&1; then
    chain_finish 1 "HALT $slug: merge state inspection failed"
  fi
  MERGEABLE="$(printf '%s' "$json" | jq -r -s '.[0].mergeable')"
  MSS="$(printf '%s' "$json" | jq -r -s '.[0].mergeStateStatus')"
}

# chain_retry_merge <wt> <pr_url> <slug> [extra gh flags...]
# Wrapped retry of the squash merge. Halts merge-retry-failed on failure;
# returns 0 on success so the caller's loop continues to marker writing.
chain_retry_merge() {
  local wt="$1" pr_url="$2" slug="$3"
  shift 3
  local err rc
  set +e
  err="$(cd "$wt" && gh pr merge "$pr_url" "$@" --squash --delete-branch 2>&1 1>/dev/null)"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || chain_finish 1 "HALT $slug: merge retry failed ($err)"
}

# chain_update_behind <wt> <pr_url> <slug>
# BEHIND path: bring the branch up to date with a clean merge of origin/main,
# push, then retry. No model call. Any fetch/merge/push failure halts
# branch-update-failed (never falls through to the conflict resolver).
chain_update_behind() {
  local wt="$1" pr_url="$2" slug="$3" rc
  if ! git -C "$wt" fetch origin main >/dev/null 2>&1; then
    chain_finish 1 "HALT $slug: branch update failed"
  fi
  set +e
  git -C "$wt" merge --no-edit origin/main >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || chain_finish 1 "HALT $slug: branch update failed"
  if ! git -C "$wt" push origin "spec2pr/$slug" >/dev/null 2>&1; then
    chain_finish 1 "HALT $slug: branch update failed"
  fi
  chain_retry_merge "$wt" "$pr_url" "$slug"
}

# chain_handle_failed_merge <wt> <pr_url> <slug> <id> <merge_err>
# Entry point when the optimistic `gh pr merge` failed. Inspects the PR state
# and dispatches. Returns 0 once a merge has succeeded.
chain_handle_failed_merge() {
  local wt="$1" pr_url="$2" slug="$3" id="$4" merge_err="$5"
  chain_inspect_merge_state "$wt" "$pr_url" "$slug"   # sets MERGEABLE, MSS
  if [ "$MSS" = "BEHIND" ]; then
    chain_update_behind "$wt" "$pr_url" "$slug"
  else
    chain_finish 1 "HALT $slug: merge state unsupported ($merge_err)"
  fi
}
```

> Note: this dispatcher intentionally handles only `BEHIND` plus the unsupported
> catch-all for now. Task 3 adds the `BLOCKED` arm and Task 4 adds the
> `CONFLICTING`/`DIRTY` arm. `CONFLICTING`/`DIRTY`/`BLOCKED` payloads therefore
> halt as "unsupported" until those tasks land — that is expected.

- [ ] **Step 6: Change the optimistic-merge failure call site**

In `scripts/spec2pr-chain.sh`, replace the merge-failure branch (~lines 262-264):

```bash
  if [ "$merge_rc" -ne 0 ]; then
    chain_finish 1 "HALT $slug: merge failed ($merge_err)"
  fi
```

with:

```bash
  if [ "$merge_rc" -ne 0 ]; then
    chain_handle_failed_merge "$wt" "$pr_url" "$slug" "$id" "$merge_err"
  fi
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | tail -3`
Expected: PASS — `0 failed`. Behind reaches `CHAIN DONE` with 2 merge calls and 4 codex calls; malformed/unsupported halt with the right lines and never retry.

- [ ] **Step 8: Commit**

```bash
git add scripts/spec2pr-chain.sh tests/spec2pr/stub-gh.sh tests/spec2pr/test-chain.sh
git commit -m "feat(spec2pr-chain): inspect merge state, handle BEHIND, validate JSON"
```

---

## Task 3: BLOCKED path + `--admin` retry

**Files:**
- Modify: `scripts/spec2pr-chain.sh` (the `chain_handle_failed_merge` dispatcher from Task 2)
- Test: `tests/spec2pr/test-chain.sh`

**Interfaces:**
- Consumes: `ADMIN` (Task 1), `chain_retry_merge` (Task 2).
- Produces: dispatcher now routes `mergeStateStatus == BLOCKED` to a halt (no `--admin`) or an `--admin` retry.

- [ ] **Step 1: Write the failing tests**

Add to `tests/spec2pr/test-chain.sh`:

```bash
test_chain_blocked_merge_halts_without_admin() {
  make_sandbox
  local a; a="$(add_spec chain-blocked)"
  queue_chain_spec 01-chain-blocked chain-blocked
  printf 'Protected branch update failed\n' > "$SPEC2PR_TEST_GH/pr-merge-fail-once"
  printf '{"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED"}' \
    > "$SPEC2PR_TEST_GH/pr-view-json"

  run_chain "$a"

  assert_eq "1" "$RC" "blocked without admin halts"
  assert_contains "$OUT" "CHAIN HALT chain-blocked: merge blocked by branch protection" \
    "blocked halt line"
  assert_eq "1" "$(grep -c 'args=pr merge ' "$SPEC2PR_TEST_GH/gh.log")" \
    "blocked path does not retry without admin"
  assert_eq "4" "$(codex_calls)" "blocked path runs no conflict codex call"
}

test_chain_blocked_merge_with_admin_succeeds() {
  make_sandbox
  local a; a="$(add_spec chain-admin)"
  queue_chain_spec 01-chain-admin chain-admin
  printf 'Protected branch update failed\n' > "$SPEC2PR_TEST_GH/pr-merge-fail-once"
  printf '{"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED"}' \
    > "$SPEC2PR_TEST_GH/pr-view-json"

  run_chain --admin "$a"

  assert_eq "0" "$RC" "blocked with admin succeeds"
  assert_contains "$OUT" "CHAIN DONE merged=1/1" "admin chain reaches done"
  assert_eq "2" "$(grep -c 'args=pr merge ' "$SPEC2PR_TEST_GH/gh.log")" \
    "admin path retries the merge"
  assert_eq "1" "$(grep -c 'args=pr merge .* --admin' "$SPEC2PR_TEST_GH/gh.log")" \
    "admin retry passes --admin"
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A4 'test_chain_blocked'`
Expected: FAIL — both currently halt with `merge state unsupported` (Task 2's catch-all), not the blocked line; the admin case never reaches `CHAIN DONE`.

- [ ] **Step 3: Add the `BLOCKED` arm to the dispatcher**

In `scripts/spec2pr-chain.sh`, change `chain_handle_failed_merge`'s `if`/`else` to:

```bash
  if [ "$MSS" = "BEHIND" ]; then
    chain_update_behind "$wt" "$pr_url" "$slug"
  elif [ "$MSS" = "BLOCKED" ]; then
    if [ "$ADMIN" -eq 1 ]; then
      chain_retry_merge "$wt" "$pr_url" "$slug" --admin
    else
      chain_finish 1 "HALT $slug: merge blocked by branch protection"
    fi
  else
    chain_finish 1 "HALT $slug: merge state unsupported ($merge_err)"
  fi
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | tail -3`
Expected: PASS — `0 failed`. Blocked-no-admin halts with the protection line and 1 merge call; admin run reaches `CHAIN DONE` with a second `pr merge … --admin` call.

- [ ] **Step 5: Commit**

```bash
git add scripts/spec2pr-chain.sh tests/spec2pr/test-chain.sh
git commit -m "feat(spec2pr-chain): handle BLOCKED with opt-in --admin retry"
```

---

## Task 4: CONFLICTING/DIRTY conflict resolution (codex)

**Files:**
- Modify: `scripts/spec2pr-chain.sh` (add `CHAIN_TMP_DIR` global ~line 11; extend `chain_release_lock` ~lines 26-32; create the tmp dir + schema after lock acquisition ~line 193; add `chain_require_codex` and `chain_resolve_conflict` functions; add the `CONFLICTING`/`DIRTY` arm to the dispatcher)
- Test: `tests/spec2pr/test-chain.sh`

**Interfaces:**
- Consumes: `chain_retry_merge` (Task 2), `chain_status`, `chain_finish` (existing), `SPEC2PR_CODEX_BIN` (runtime default).
- Produces:
  - `CHAIN_TMP_DIR` — chain-scoped scratch dir holding `conflict-resolve.json` (the codex output schema) and the codex prompt; removed by `chain_release_lock`.
  - `chain_require_codex <slug>` — halts `missing dependency: <bin>` if the codex binary is absent.
  - `chain_resolve_conflict <wt> <pr_url> <slug> <id>` — full conflict path: fetch, conflicting merge, codex resolve, hard gates, audit artifacts in the meta dir, `CHAIN OK resolved-conflict <slug>`, push, retry.

- [ ] **Step 1: Write the failing tests**

Add to `tests/spec2pr/test-chain.sh`:

```bash
test_chain_conflict_resolved_and_retried() {
  make_sandbox
  local a; a="$(add_spec chain-conflict)"
  queue_chain_spec 01-chain-conflict chain-conflict
  # First merge: land a CONFLICTING edit to the same marker on origin/main.
  printf 'marker-chain-conflict.txt\nDIVERGENT main edit\n' \
    > "$SPEC2PR_TEST_GH/pr-merge-diverge"
  printf '{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}' \
    > "$SPEC2PR_TEST_GH/pr-view-json"
  # codex conflict-resolve fixture (consumed after spec2pr's four codex calls):
  # clear markers with content distinct from both sides, then commit the merge.
  enqueue 02-chain-conflict-resolve <<'EOF'
printf 'resolved chain-conflict (both sides)\n' > marker-chain-conflict.txt
git add marker-chain-conflict.txt
git commit -qm 'resolve conflict'
printf '{"summary":"kept both edits to the marker"}'
EOF

  run_chain "$a"

  assert_eq "0" "$RC" "conflict chain exits 0"
  assert_contains "$OUT" "CHAIN OK resolved-conflict chain-conflict" "conflict path emits audit line"
  assert_contains "$OUT" "CHAIN DONE merged=1/1" "conflict chain reaches done"
  assert_eq "5" "$(codex_calls)" "conflict path runs exactly one extra codex call"
  assert_eq "2" "$(grep -c 'args=pr merge ' "$SPEC2PR_TEST_GH/gh.log")" \
    "conflict path retries the merge once"
  assert_file_exists "$SPEC2PR_HOME/project-chain-conflict/conflict-resolve.patch" \
    "resolution patch written to meta dir"
  assert_file_exists "$SPEC2PR_HOME/project-chain-conflict/conflict-resolve.codex.json" \
    "resolution summary written to meta dir"
  assert_contains "$(cat "$SPEC2PR_HOME/project-chain-conflict/conflict-resolve.patch")" \
    "marker-chain-conflict" "patch references the resolved file"
}

test_chain_conflict_resolver_must_commit() {
  make_sandbox
  local a; a="$(add_spec chain-nocommit)"
  queue_chain_spec 01-chain-nocommit chain-nocommit
  printf 'marker-chain-nocommit.txt\nDIVERGENT main edit\n' \
    > "$SPEC2PR_TEST_GH/pr-merge-diverge"
  printf '{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}' \
    > "$SPEC2PR_TEST_GH/pr-view-json"
  # Resolver clears the conflict but aborts instead of committing: HEAD never
  # advances past the captured pre-merge commit.
  enqueue 02-chain-nocommit-resolve <<'EOF'
git merge --abort
printf '{"summary":"aborted without committing"}'
EOF

  run_chain "$a"

  assert_eq "1" "$RC" "no-commit resolver halts"
  assert_contains "$OUT" "CHAIN HALT chain-nocommit: conflict resolution failed" \
    "no-commit resolver halt line"
  assert_not_contains "$OUT" "CHAIN OK resolved-conflict" \
    "no audit line when the resolver did not commit"
  assert_eq "1" "$(grep -c 'args=pr merge ' "$SPEC2PR_TEST_GH/gh.log")" \
    "no merge retry when the resolver did not commit"
}

test_chain_conflict_requires_local_unmerged_paths() {
  make_sandbox
  local a; a="$(add_spec chain-clean)"
  queue_chain_spec 01-chain-clean chain-clean
  # pr view CLAIMS conflict, but origin/main never moved, so the local merge is
  # "Already up to date" (exit 0, no unmerged paths). Use fail-once (no diverge).
  printf 'optimistic merge failed\n' > "$SPEC2PR_TEST_GH/pr-merge-fail-once"
  printf '{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}' \
    > "$SPEC2PR_TEST_GH/pr-view-json"

  run_chain "$a"

  assert_eq "1" "$RC" "clean-merge conflict claim halts"
  assert_contains "$OUT" "CHAIN HALT chain-clean: conflict resolution failed" \
    "clean-merge halt line"
  assert_eq "4" "$(codex_calls)" "no conflict-resolve codex call when local merge is clean"
  assert_eq "1" "$(grep -c 'args=pr merge ' "$SPEC2PR_TEST_GH/gh.log")" \
    "no merge retry on clean-merge halt"
}

test_chain_conflict_marker_grep_ignores_legit_strings() {
  make_sandbox
  local a; a="$(add_spec chain-markerdoc)"
  queue_chain_spec 01-chain-markerdoc chain-markerdoc
  # Override the implement fixture (05) to also commit a tracked doc that
  # mentions the literal conflict-marker tokens inside prose (never line-shaped).
  enqueue 01-chain-markerdoc-05-implement <<'EOF'
mkdir -p docs
cat > docs/markers-note.md <<'DOC'
Conflict markers look like <<<<<<< then >>>>>>> wrapped around a body.
Authors sometimes write ======= inline to mean a divider, e.g. use =======.
DOC
printf 'chain-markerdoc\n' > marker-chain-markerdoc.txt
git add marker-chain-markerdoc.txt docs/markers-note.md
git commit -qm 'implement marker chain-markerdoc + doc'
printf '{"status":"done","summary":"implemented chain-markerdoc","blocked_reason":""}'
EOF
  printf 'marker-chain-markerdoc.txt\nDIVERGENT main edit\n' \
    > "$SPEC2PR_TEST_GH/pr-merge-diverge"
  printf '{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}' \
    > "$SPEC2PR_TEST_GH/pr-view-json"
  enqueue 02-chain-markerdoc-resolve <<'EOF'
printf 'resolved chain-markerdoc\n' > marker-chain-markerdoc.txt
git add marker-chain-markerdoc.txt
git commit -qm 'resolve conflict'
printf '{"summary":"resolved the marker, left the doc untouched"}'
EOF

  run_chain "$a"

  assert_eq "0" "$RC" "legit-marker-strings chain exits 0"
  assert_contains "$OUT" "CHAIN OK resolved-conflict chain-markerdoc" \
    "marker grep does not false-positive on prose tokens"
  assert_contains "$OUT" "CHAIN DONE merged=1/1" "legit-marker-strings chain reaches done"
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A4 'test_chain_conflict'`
Expected: FAIL — `CONFLICTING`/`DIRTY` currently halts as `merge state unsupported` (Task 2/3 catch-all); no `resolved-conflict` line, no meta-dir artifacts.

- [ ] **Step 3: Add the `CHAIN_TMP_DIR` global**

In `scripts/spec2pr-chain.sh`, add to the globals block (after `CHAIN_LOCK_PATH=""`):

```bash
CHAIN_STATUS_PATH=""
CHAIN_LOCK_DIR=""
CHAIN_LOCK_PATH=""
CHAIN_TMP_DIR=""
```

- [ ] **Step 4: Remove the tmp dir on cleanup**

In `scripts/spec2pr-chain.sh`, extend `chain_release_lock` to also drop the tmp dir:

```bash
chain_release_lock() {
  if [ -n "$CHAIN_LOCK_DIR" ] && [ -n "$CHAIN_LOCK_PATH" ] && [ -f "$CHAIN_LOCK_PATH" ]; then
    if [ "$(cat "$CHAIN_LOCK_PATH" 2>/dev/null || true)" = "$$" ]; then
      rm -rf "$CHAIN_LOCK_DIR"
    fi
  fi
  if [ -n "$CHAIN_TMP_DIR" ] && [ -d "$CHAIN_TMP_DIR" ]; then
    rm -rf "$CHAIN_TMP_DIR"
  fi
}
```

- [ ] **Step 5: Create the tmp dir and the conflict-resolve schema**

In `scripts/spec2pr-chain.sh`, immediately after the lock is acquired (the `chain_acquire_lock` line ~193) and before `chain_status "OK started specs=$total"`:

```bash
if ! chain_acquire_lock "$SPEC2PR_HOME/$repo_id.chain.lock"; then chain_finish 1 "HALT: chain already running for $repo_id"; fi

CHAIN_TMP_DIR="$(mktemp -d -t spec2pr-chain.XXXXXX)"
cat > "$CHAIN_TMP_DIR/conflict-resolve.json" <<'EOF'
{
  "type": "object",
  "properties": { "summary": { "type": "string" } },
  "required": ["summary"],
  "additionalProperties": false
}
EOF

chain_status "OK started specs=$total"
```

- [ ] **Step 6: Add `chain_require_codex` and `chain_resolve_conflict`**

In `scripts/spec2pr-chain.sh`, add after `chain_update_behind` (from Task 2):

```bash
# chain_require_codex <slug>
# Honors SPEC2PR_CODEX_BIN (which may be an absolute path). Halts via the chain
# contract if the binary is missing, before entering the conflict path.
chain_require_codex() {
  local slug="$1"
  case "$SPEC2PR_CODEX_BIN" in
    */*)
      [ -x "$SPEC2PR_CODEX_BIN" ] \
        || chain_finish 1 "HALT $slug: missing dependency: $SPEC2PR_CODEX_BIN"
      ;;
    *)
      command -v "$SPEC2PR_CODEX_BIN" >/dev/null 2>&1 \
        || chain_finish 1 "HALT $slug: missing dependency: $SPEC2PR_CODEX_BIN"
      ;;
  esac
}

# chain_resolve_conflict <wt> <pr_url> <slug> <id>
# CONFLICTING/DIRTY path. Merge origin/main locally (expected to conflict), have
# codex resolve and commit, gate hard on the result, record an audit trail, push,
# and retry the squash merge. Any miss halts conflict-resolution-failed and
# leaves the PR/worktree for manual repair.
chain_resolve_conflict() {
  local wt="$1" pr_url="$2" slug="$3" id="$4"
  local meta_dir="$SPEC2PR_HOME/$id"
  mkdir -p "$meta_dir"
  chain_require_codex "$slug"

  if ! git -C "$wt" fetch origin main >/dev/null 2>&1; then
    chain_finish 1 "HALT $slug: conflict resolution failed"
  fi
  local fetched_main pre_merge_head rc
  fetched_main="$(git -C "$wt" rev-parse origin/main 2>/dev/null)" \
    || chain_finish 1 "HALT $slug: conflict resolution failed"
  pre_merge_head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" \
    || chain_finish 1 "HALT $slug: conflict resolution failed"

  # The expected conflict-producing merge. Under set -e it must be wrapped so the
  # shell does not exit before codex runs.
  set +e
  git -C "$wt" merge --no-edit origin/main >/dev/null 2>&1
  rc=$?
  set -e
  # Only proceed when the merge truly conflicted: non-zero AND unmerged paths.
  if [ "$rc" -eq 0 ] || [ -z "$(git -C "$wt" ls-files -u)" ]; then
    chain_finish 1 "HALT $slug: conflict resolution failed"
  fi

  # codex resolves in the worktree and commits the merge.
  local prompt_file="$CHAIN_TMP_DIR/conflict-resolve.prompt"
  cat > "$prompt_file" <<'EOF'
You are resolving a Git merge conflict in the repository at the current working
directory. `git merge --no-edit origin/main` has left one or more files in a
conflicted state.

Resolve EVERY conflicted file, preserving the intent of BOTH sides. Leave NO
conflict markers (no `<<<<<<<`, `=======`, or `>>>>>>>` marker lines). When the
working tree is clean, `git add` the resolved files and `git commit` to complete
the merge commit.

Return JSON: {"summary":"<one line describing what you resolved>"}.
EOF
  set +e
  "$SPEC2PR_CODEX_BIN" exec --cd "$wt" \
    --output-schema "$CHAIN_TMP_DIR/conflict-resolve.json" \
    --output-last-message "$meta_dir/conflict-resolve.codex.json" \
    < "$prompt_file" > "$meta_dir/conflict-resolve.stdout" 2> "$meta_dir/conflict-resolve.stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || chain_finish 1 "HALT $slug: conflict resolution failed"

  # Validate the model summary JSON.
  if ! jq -e 'type == "object" and (.summary | type == "string") and (.summary | length > 0)' \
      "$meta_dir/conflict-resolve.codex.json" >/dev/null 2>&1; then
    chain_finish 1 "HALT $slug: conflict resolution failed"
  fi

  # Hard gates on the resolved worktree.
  # 1. No line-shaped conflict markers in tracked text files (grep MATCHES => bad).
  if git -C "$wt" grep -I -n -E '^(<<<<<<< .+|=======|>>>>>>> .+)$' -- . >/dev/null 2>&1; then
    chain_finish 1 "HALT $slug: conflict resolution failed"
  fi
  # 2. `git diff --check` clean.
  if ! git -C "$wt" diff --check >/dev/null 2>&1; then
    chain_finish 1 "HALT $slug: conflict resolution failed"
  fi
  # 3. No unmerged paths remain.
  if [ -n "$(git -C "$wt" ls-files -u)" ]; then
    chain_finish 1 "HALT $slug: conflict resolution failed"
  fi
  # 4. Worktree clean (index + working tree).
  if [ -n "$(git -C "$wt" status --porcelain)" ]; then
    chain_finish 1 "HALT $slug: conflict resolution failed"
  fi
  # 5. codex made the resolution commit (HEAD advanced past pre-merge HEAD).
  local post_head
  post_head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" \
    || chain_finish 1 "HALT $slug: conflict resolution failed"
  if [ "$post_head" = "$pre_merge_head" ]; then
    chain_finish 1 "HALT $slug: conflict resolution failed"
  fi
  # 6. The fetched origin/main is reachable from HEAD (resolver did not abort the
  #    merge and substitute an unrelated commit).
  if ! git -C "$wt" merge-base --is-ancestor "$fetched_main" HEAD >/dev/null 2>&1; then
    chain_finish 1 "HALT $slug: conflict resolution failed"
  fi

  # Audit trail: capture the resolution commit patch (the --format=fuller header
  # guarantees a non-empty file even for a merge commit). A post-commit `git diff`
  # would be empty, so we use `git show` on the commit.
  git -C "$wt" show --stat --patch --format=fuller HEAD \
    > "$meta_dir/conflict-resolve.patch" 2>/dev/null || true
  if [ ! -s "$meta_dir/conflict-resolve.patch" ]; then
    chain_finish 1 "HALT $slug: conflict resolution failed"
  fi

  # Publish the resolution to the PR branch, then record the audit line.
  if ! git -C "$wt" push origin "spec2pr/$slug" >/dev/null 2>&1; then
    chain_finish 1 "HALT $slug: conflict resolution failed"
  fi
  chain_status "OK resolved-conflict $slug"
  chain_retry_merge "$wt" "$pr_url" "$slug"
}
```

- [ ] **Step 7: Add the `CONFLICTING`/`DIRTY` arm to the dispatcher**

In `scripts/spec2pr-chain.sh`, change `chain_handle_failed_merge`'s body so the conflict check comes first:

```bash
  chain_inspect_merge_state "$wt" "$pr_url" "$slug"   # sets MERGEABLE, MSS
  if [ "$MERGEABLE" = "CONFLICTING" ] || [ "$MSS" = "DIRTY" ]; then
    chain_resolve_conflict "$wt" "$pr_url" "$slug" "$id"
  elif [ "$MSS" = "BEHIND" ]; then
    chain_update_behind "$wt" "$pr_url" "$slug"
  elif [ "$MSS" = "BLOCKED" ]; then
    if [ "$ADMIN" -eq 1 ]; then
      chain_retry_merge "$wt" "$pr_url" "$slug" --admin
    else
      chain_finish 1 "HALT $slug: merge blocked by branch protection"
    fi
  else
    chain_finish 1 "HALT $slug: merge state unsupported ($merge_err)"
  fi
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | tail -3`
Expected: PASS — `0 failed`. The resolve case emits `CHAIN OK resolved-conflict chain-conflict`, writes `conflict-resolve.patch` and `conflict-resolve.codex.json` to the meta dir, and reaches `CHAIN DONE` with 5 codex + 2 merge calls. The must-commit, clean-merge, and legit-strings cases behave as asserted.

- [ ] **Step 9: Commit**

```bash
git add scripts/spec2pr-chain.sh tests/spec2pr/test-chain.sh
git commit -m "feat(spec2pr-chain): auto-resolve merge conflicts via codex with audit gates"
```

---

## Task 5: VERSION bump + UPGRADE.md

**Files:**
- Modify: `VERSION`
- Modify: `UPGRADE.md` (insert a new section after the header block, before `## To v1.10.0 - from v1.9.0`)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing (release metadata).

- [ ] **Step 1: Bump VERSION**

Replace the contents of `VERSION` with:

```
1.10.1
```

- [ ] **Step 2: Add the UPGRADE.md section**

In `UPGRADE.md`, insert immediately before the `## To v1.10.0 - from v1.9.0` line:

```markdown
## To v1.10.1 - from v1.10.0

**Action:** None.

**Caveat:** a `/rulez:spec2pr-chain` merge that hits a genuine conflict is now
auto-resolved by a model call (surfaced as `CHAIN OK resolved-conflict`, with the
diff kept in the run's meta dir) instead of halting; a `BEHIND` branch is brought
up to date automatically; and the new `--admin` flag opts into merging past branch
protection (off by default).

```

- [ ] **Step 3: Verify the version and the full suite**

Run: `cat VERSION && bash tests/spec2pr/run-tests.sh 2>&1 | tail -3`
Expected: `1.10.1` then `… 0 failed`.

- [ ] **Step 4: Commit**

```bash
git add VERSION UPGRADE.md
git commit -m "chore: release v1.10.1 — spec2pr-chain conflict & branch-protection handling"
```

---

## Self-Review

**1. Spec coverage**

| Spec requirement | Task |
|---|---|
| Optimistic merge unchanged; only failure branch changes | Task 2 (call-site swap) |
| `gh pr view --json mergeable,mergeStateStatus`, parsed with `jq`, require `jq` | Task 2 (`chain_inspect_merge_state`, `chain_require_dependency jq`) |
| Reject non-object / array / scalar / missing / non-string / multiple concatenated JSON → `merge state inspection failed` | Task 2 (`jq -s 'length==1 …'`; `test_chain_inspection_rejects_malformed_shape`) |
| `CONFLICTING`/`DIRTY` → local merge + codex resolve + retry | Task 4 (`chain_resolve_conflict`) |
| Honor `SPEC2PR_CODEX_BIN`, require before conflict path | Task 4 (`chain_require_codex`) |
| Wrap expected-conflict merge under `set -e`; capture `pre_merge_head`; require non-zero merge + unmerged paths | Task 4 |
| Validate codex summary JSON; invalid → `conflict resolution failed` | Task 4 |
| Capture commit patch (`git show … --format=fuller`, not post-commit diff) + summary JSON to meta dir; non-empty | Task 4 |
| `CHAIN OK resolved-conflict <slug>` audit line | Task 4 (`test_chain_conflict_resolved_and_retried`) |
| Marker grep is line-shaped regex, inverted; no broad literal grep | Task 4 (`test_chain_conflict_marker_grep_ignores_legit_strings`) |
| Hard gates: no markers, `diff --check` clean, committed worktree, fetched `origin/main` ancestor of HEAD | Task 4 (six gates) |
| Reject clean merge / no-unmerged-paths as resolution | Task 4 (`test_chain_conflict_requires_local_unmerged_paths`) |
| Reject resolver that does not commit / breaks ancestry | Task 4 (`test_chain_conflict_resolver_must_commit`, gates 5-6) |
| `BEHIND` → fetch + clean merge + push + retry, no model; fetch/merge fail → `branch update failed` | Task 2 (`chain_update_behind`, `test_chain_behind_merge_updates_and_retries`) |
| `BLOCKED` → halt `merge blocked by branch protection` unless `--admin` retries | Task 3 |
| Retry in conflict/behind/admin path wrapped; failure → `merge retry failed (<stderr>)` | Task 2 (`chain_retry_merge`) |
| Unmatched validated state → `merge state unsupported` with gh stderr | Task 2/4 (`else` arm, `test_chain_unsupported_merge_state_halts`) |
| `--admin` arg parse, off by default, `status` unaffected | Task 1 |
| Command doc forwards `--admin [--fast]` | Task 1 |
| stub-gh: fixture-driven `pr view`, `pr merge --admin` accepted | Task 2 (stub already cats `pr-view-json`, matches only `$1 $2`) |
| Recoverability via part-1 markers unchanged | Untouched — marker write path after the handler returns is unchanged |
| VERSION patch bump + UPGRADE.md | Task 5 |

No gaps found.

**2. Placeholder scan** — every code step shows complete shell; no "TBD"/"add error handling"/"similar to". The codex prompt, schema, and all gate commands are spelled out.

**3. Type/name consistency** — function names are stable across tasks: `chain_inspect_merge_state` (sets `MERGEABLE`/`MSS`), `chain_retry_merge`, `chain_update_behind`, `chain_handle_failed_merge`, `chain_require_codex`, `chain_resolve_conflict`. Globals `ADMIN` (Task 1) and `CHAIN_TMP_DIR` (Task 4) are declared before first use. The dispatcher is edited additively (Task 2 → 3 → 4); its final form matches Task 4 Step 7. Meta-dir artifact names (`conflict-resolve.codex.json`, `conflict-resolve.patch`) match between the implementation (Task 4 Step 6) and the assertions (Task 4 Step 1).
