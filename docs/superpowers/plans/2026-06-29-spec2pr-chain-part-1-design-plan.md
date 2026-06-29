# spec2pr chain — part 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `/rulez:spec2pr-chain`, a thin orchestrator that runs several specs in dependency order, squash-merging each PR before the next spec starts, so each spec branches off a `main` that already contains its predecessors.

**Architecture:** A new `scripts/spec2pr-chain.sh` loops over the **unmodified** `scripts/spec2pr.sh`, consuming the contract it already emits (exit codes `0`/`1`/`2`/`3` and the `SPEC2PR DONE pr=<url> worktree=<path>` line). On each `DONE` it merges immediately (`gh pr merge --squash --delete-branch`), records a per-spec `<ID>.merged` marker, and tears the worktree/branch down. Any non-`DONE` spec, or any merge that does not succeed on the first attempt, stops the chain. The orchestrator sources `lib/spec2pr-runtime.sh` only for its `sanitize`/`require_dependency` helpers and config defaults; all user-visible chain lines are stage-free `CHAIN …` lines emitted by small local helpers.

**Tech Stack:** Bash (`set -euo pipefail`), `git`, `gh`, `jq`, sha256 via `shasum`/`sha256sum`. Tests are plain-bash assertions in `tests/spec2pr/`, run by `tests/spec2pr/run-tests.sh` (auto-discovers `test-*.sh`, no registration needed).

## Global Constraints

Copied verbatim from the spec; every task implicitly includes these.

- **`scripts/spec2pr.sh` is never modified.** The orchestrator only invokes it and reads its contract.
- **`CONTRACT_PREFIX=CHAIN` must be set but NOT exported** before sourcing the runtime, so child `spec2pr.sh` processes keep their own `SPEC2PR` prefix.
- **Chain contract lines are stage-free.** Never use runtime `status`/`halt`/`finish`/`acquire_lock` for chain outcomes (they inject `$STAGE:` and runtime lock failures call `halt`). Use the local `chain_status`/`chain_finish`/`chain_acquire_lock` helpers.
- **`chain_finish` must set the runtime `FINISHED=1` before exiting**, or the runtime `on_exit` trap appends a bogus `CHAIN HALT preflight: unexpected exit` after every intentional outcome.
- **Squash merge:** `gh pr merge <url> --squash --delete-branch`.
- **Single repository required**, checked before any spec runs. Mixed repos are a preflight halt.
- **Duplicate derived IDs rejected** before any spec runs.
- **Merge immediately on DONE** — no waiting on GitHub CI (spec2pr already ran verification in the worktree).
- **Any non-clean merge halts** in this part — no partial/auto recovery.
- **`VERSION` bumps to `1.9.0`** (minor). `1.8.0` is already taken by the landed forecast feature (see `UPGRADE.md`), so the coordination note resolves to `1.9.0`.
- Exact contract strings (stdout + chain log):
  - `CHAIN OK started specs=<n>`
  - `CHAIN OK skipped <slug> (already merged)`
  - `CHAIN OK merged <slug> pr=<url>`
  - `CHAIN HALT <slug>: <reason>` (per-spec, terminal, exit 1)
  - `CHAIN HALT: preflight all specs must be in the same git repository` (terminal, exit 1)
  - `CHAIN HALT: preflight duplicate spec id <ID>` (terminal, exit 1)
  - `CHAIN HALT: chain already running for <repo>` (terminal, exit 1)
  - `CHAIN DONE merged=<n>/<total>` (terminal, exit 0)

---

## File Structure

- **Create** `scripts/spec2pr-chain.sh` — the orchestrator. One responsibility: drive `spec2pr.sh` over an ordered spec list, merging between runs.
- **Create** `commands/rulez/spec2pr-chain.md` — the `/rulez:spec2pr-chain <spec…>` launch + `status` command.
- **Create** `tests/spec2pr/test-chain.sh` — end-to-end + preflight tests for the orchestrator.
- **Modify** `tests/spec2pr/stub-gh.sh` — add a `pr merge` case that simulates GitHub's squash merge.
- **Modify** `tests/spec2pr/helpers.sh` — add `add_spec` to scaffold toy specs.
- **Modify** `commands/rulez/spec2pr-split.md` — step 5 gains a one-shot pointer to `/rulez:spec2pr-chain`.
- **Modify** `VERSION`, `UPGRADE.md` — version bump + user-facing note.

**Decision (recorded):** The spec lists a *conditional* edit to `scripts/lib/spec2pr-runtime.sh` ("only if a shared spec→ID helper reads cleaner extracted than inlined"). We **do not** edit the runtime. The ID formula is six lines and the only shared piece, `sanitize`, already lives in the runtime. Inlining the formula in the chain keeps the shared file untouched, which is the safer option the spec explicitly allows.

**Decision (recorded):** The spec lists an edit to `tests/spec2pr/run-tests.sh` ("register"). The runner already globs `test-*.sh` (`run-tests.sh:13`) and sources every match, so `test-chain.sh` is discovered automatically. **No edit to `run-tests.sh` is required.**

---

## Task 1: Orchestrator skeleton — arg parse, preflight, lock, status subcommand

Builds everything up to the per-spec loop: argument parsing, the stage-free `chain_*` helpers, single-repo + duplicate-ID preflight, the repo-scoped lock, and the `status` subcommand. The per-spec loop is a stub here; Task 2 replaces it. This task's independently-testable deliverables are the preflight halts (mixed-repo, duplicate-ID) and the `status` subcommand.

**Files:**
- Create: `scripts/spec2pr-chain.sh`
- Create: `tests/spec2pr/test-chain.sh`
- Modify: `tests/spec2pr/helpers.sh` (add `add_spec`)

**Interfaces:**
- Consumes: `scripts/lib/spec2pr-runtime.sh` functions `sanitize`, `require_dependency`; vars `SPEC2PR_HOME`, `FINISHED`, `CONTRACT_PREFIX`.
- Produces (used by Task 2): shell vars set after preflight —
  - `GIT_ROOT` (abs path), `total` (int)
  - parallel arrays `SPEC_ABS_LIST[]`, `ID_LIST[]`, `SLUG_LIST[]`
  - `CHAIN_STATUS_PATH` (chain log path), `merged_count` (int, starts 0)
  - helpers `chain_status "<line-after-CHAIN>"`, `chain_finish <rc> "<line-after-CHAIN>"`
  - `SCRIPT_DIR` (dir containing this script)

- [ ] **Step 1: Add `add_spec` to `tests/spec2pr/helpers.sh`**

Append this function at the end of `tests/spec2pr/helpers.sh` (after `queue_exceeds_forecast`):

```bash
# Scaffold one UNTRACKED toy spec in $PROJECT under docs/superpowers/specs/.
# Mirrors the make_sandbox toy spec (untracked, so spec2pr's import commit
# fires). Echoes the spec's absolute path. <slug> is used verbatim as the file
# stem, so the derived spec2pr SLUG equals <slug>.
add_spec() { # <slug>
  local slug="$1"
  printf '# %s spec\n\nDo thing %s.\n' "$slug" "$slug" \
    > "$PROJECT/docs/superpowers/specs/$slug.md"
  printf '%s\n' "$PROJECT/docs/superpowers/specs/$slug.md"
}
```

- [ ] **Step 2: Write the failing preflight tests**

Create `tests/spec2pr/test-chain.sh` with this content:

```bash
#!/usr/bin/env bash
# End-to-end + preflight tests for scripts/spec2pr-chain.sh. Drives the real
# spec2pr.sh; only the model (codex/claude) and gh boundaries are stubbed.

CHAIN="$REPO_ROOT/scripts/spec2pr-chain.sh"

# Run the chain, capturing combined output + exit code into OUT / RC.
run_chain() {
  set +e
  OUT="$(bash "$CHAIN" "$@" 2>&1)"
  RC=$?
  set -e 2>/dev/null || true
}

test_chain_mixed_repo_halts() {
  make_sandbox
  local a; a="$(add_spec chain-a)"

  # A second, unrelated git repo with its own spec.
  local repo2="$SANDBOX/project2"
  git init -q -b main "$repo2"
  git -C "$repo2" config user.email "test@test"
  git -C "$repo2" config user.name "spec2pr-test"
  mkdir -p "$repo2/docs/superpowers/specs"
  printf '# z spec\n' > "$repo2/docs/superpowers/specs/chain-z.md"
  git -C "$repo2" add -A
  git -C "$repo2" commit -qm init
  local z="$repo2/docs/superpowers/specs/chain-z.md"

  run_chain "$a" "$z"

  assert_eq "1" "$RC" "mixed-repo invocation exits 1"
  assert_contains "$OUT" "CHAIN HALT: preflight all specs must be in the same git repository" "mixed-repo halt line"
  assert_eq "0" "$(codex_calls)" "no spec2pr run on mixed-repo halt"
  assert_file_absent "$SPEC2PR_HOME/project-chain-a.merged" "no marker written on preflight halt"
}

test_chain_duplicate_id_halts() {
  make_sandbox
  local a; a="$(add_spec chain-a)"
  # Same repo, same basename stem in a subdir -> same derived ID.
  mkdir -p "$PROJECT/docs/superpowers/specs/sub"
  printf '# dup\n' > "$PROJECT/docs/superpowers/specs/sub/chain-a.md"
  local a2="$PROJECT/docs/superpowers/specs/sub/chain-a.md"

  run_chain "$a" "$a2"

  assert_eq "1" "$RC" "duplicate-id invocation exits 1"
  assert_contains "$OUT" "CHAIN HALT: preflight duplicate spec id project-chain-a" "duplicate-id halt line"
  assert_eq "0" "$(codex_calls)" "no spec2pr run on duplicate-id halt"
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A2 'test_chain_mixed_repo_halts\|test_chain_duplicate_id_halts'`
Expected: both tests FAIL (the script `scripts/spec2pr-chain.sh` does not exist yet, so `bash "$CHAIN"` errors and the `assert_contains` lines fail).

- [ ] **Step 4: Write the orchestrator skeleton**

Create `scripts/spec2pr-chain.sh` with this content. The per-spec loop is a stub (`=== per-spec loop (Task 2) ===`) replaced in Task 2.

```bash
#!/usr/bin/env bash
set -euo pipefail

# spec2pr-chain.sh — run several specs in dependency order, squash-merging each
# PR before the next starts. Thin orchestrator over the UNMODIFIED spec2pr.sh.
#
# Reuses lib/spec2pr-runtime.sh ONLY for sanitize/require_dependency and config
# defaults. Every user-visible chain line is a stage-free `CHAIN ...` line from
# the local chain_* helpers, never runtime status/halt/finish (which inject
# $STAGE:). CONTRACT_PREFIX is set but NOT exported, so child spec2pr.sh runs
# keep their own SPEC2PR prefix.
CONTRACT_PREFIX=CHAIN
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=lib/spec2pr-runtime.sh
source "$SCRIPT_DIR/lib/spec2pr-runtime.sh"

CHAIN_STATUS_PATH=""
CHAIN_LOCK_DIR=""
CHAIN_LOCK_PATH=""

chain_log() { # <line-after-CHAIN>
  local line="CHAIN $1"
  printf '%s\n' "$line"
  if [ -n "$CHAIN_STATUS_PATH" ]; then
    mkdir -p "$(dirname "$CHAIN_STATUS_PATH")"
    printf '%s\n' "$line" >> "$CHAIN_STATUS_PATH"
  fi
}

chain_status() { chain_log "$1"; }

chain_release_lock() {
  if [ -n "$CHAIN_LOCK_DIR" ] && [ -f "$CHAIN_LOCK_PATH" ]; then
    if [ "$(cat "$CHAIN_LOCK_PATH" 2>/dev/null || true)" = "$$" ]; then
      rm -rf "$CHAIN_LOCK_DIR"
    fi
  fi
}

# chain_finish <exit-code> <line-after-CHAIN>
# Sets FINISHED=1 so the runtime EXIT trap does not append a bogus
# "CHAIN HALT preflight: unexpected exit" after our intentional outcome.
chain_finish() { # <rc> <line>
  local rc="$1"
  shift
  FINISHED=1
  chain_log "$1"
  chain_release_lock
  exit "$rc"
}

# chain_acquire_lock <lock-dir>
# mkdir/pid/stale-lock mirror of runtime acquire_lock, but RETURNS non-zero on
# contention (or an initializing lock) instead of halting, so the caller emits
# the CHAIN line. Sets CHAIN_LOCK_DIR/CHAIN_LOCK_PATH on success.
chain_acquire_lock() { # <lock-dir>
  local lock_target="$1" lock_pid stale_dir
  mkdir -p "$(dirname "$lock_target")"
  if ! mkdir "$lock_target" 2>/dev/null; then
    lock_pid="$(cat "$lock_target/pid" 2>/dev/null || true)"
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      return 1
    fi
    if [ -z "$lock_pid" ]; then
      return 1   # owner is mid-acquire; do not steal an initializing lock
    fi
    stale_dir="$lock_target.stale.$$"
    if mv "$lock_target" "$stale_dir" 2>/dev/null; then
      rm -rf "$stale_dir"
    fi
    if ! mkdir "$lock_target" 2>/dev/null; then
      return 1
    fi
  fi
  CHAIN_LOCK_DIR="$lock_target"
  CHAIN_LOCK_PATH="$lock_target/pid"
  printf '%s\n' "$$" > "$CHAIN_LOCK_PATH"
  return 0
}

short_hash() { # <string> <n-chars> -> first <n> hex chars of sha256
  local s="$1" n="$2"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$s" | shasum -a 256 | awk -v n="$n" '{print substr($1,1,n)}'
  else
    printf '%s' "$s" | sha256sum | awk -v n="$n" '{print substr($1,1,n)}'
  fi
}

usage() {
  chain_finish 1 "HALT: usage: spec2pr-chain.sh [--fast] (status | <spec>...)"
}

# -- arg parse: --fast, a `status` subcommand, the ordered spec list ----------
FAST=0
SUBCOMMAND=""
SPECS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --fast) FAST=1; shift ;;
    status) SUBCOMMAND=status; shift ;;
    --*) usage ;;
    *) SPECS+=("$1"); shift ;;
  esac
done

mkdir -p "$SPEC2PR_HOME"

# -- status subcommand: tail every chain log ----------------------------------
if [ "$SUBCOMMAND" = status ]; then
  for f in "$SPEC2PR_HOME"/chains/*.status; do
    [ -f "$f" ] || continue
    printf '%s -> %s\n' "$(basename "$f" .status)" "$(tail -1 "$f")"
  done
  FINISHED=1
  exit 0
fi

[ "${#SPECS[@]}" -ge 1 ] || usage

require_dependency git
require_dependency gh

# -- preflight: resolve paths, single repo, derive IDs, reject duplicates -----
# Runs BEFORE the lock so a bad invocation never blocks a real chain. Halts
# here carry no chain-log path yet (CHAIN_STATUS_PATH still empty); they go to
# stdout only, which is the surface the command reads.
GIT_ROOT=""
SPEC_ABS_LIST=()
ID_LIST=()
SLUG_LIST=()
declare -A SEEN_IDS=()
for spec in "${SPECS[@]}"; do
  if [ ! -f "$spec" ]; then
    chain_finish 1 "HALT: preflight spec not found: $spec"
  fi
  spec_dir="$(cd "$(dirname "$spec")" && pwd -P)"
  spec_base="$(basename "$spec")"
  spec_abs="$spec_dir/$spec_base"
  if ! root="$(git -C "$spec_dir" rev-parse --show-toplevel 2>/dev/null)"; then
    chain_finish 1 "HALT: preflight spec is not inside a git repository: $spec"
  fi
  if [ -z "$GIT_ROOT" ]; then
    GIT_ROOT="$root"
  elif [ "$root" != "$GIT_ROOT" ]; then
    chain_finish 1 "HALT: preflight all specs must be in the same git repository"
  fi
  repo_slug="$(sanitize "$(basename "$root")")"
  spec_stem="${spec_base%.*}"
  spec_slug="$(sanitize "$spec_stem")"
  [ -n "$spec_slug" ] || chain_finish 1 "HALT: preflight empty slug: $spec"
  [ -n "$repo_slug" ] || chain_finish 1 "HALT: preflight empty repository slug"
  id="$repo_slug-$spec_slug"
  if [ -n "${SEEN_IDS[$id]:-}" ]; then
    chain_finish 1 "HALT: preflight duplicate spec id $id"
  fi
  SEEN_IDS[$id]=1
  SPEC_ABS_LIST+=("$spec_abs")
  ID_LIST+=("$id")
  SLUG_LIST+=("$spec_slug")
done

total="${#SPEC_ABS_LIST[@]}"

# -- chain log name + repo-scoped lock ----------------------------------------
# chain-id only names the log; repo-id (basename + short path hash) keys the
# lock so two chains over one repo cannot interleave merges into one main,
# while unrelated checkouts that share a basename do not block each other.
specs_joined="$(printf '%s\n' "${SPEC_ABS_LIST[@]}")"
chain_id="$(short_hash "$specs_joined" 12)"
CHAIN_STATUS_PATH="$SPEC2PR_HOME/chains/$chain_id.status"

repo_id="$(sanitize "$(basename "$GIT_ROOT")")-$(short_hash "$GIT_ROOT" 8)"
if ! chain_acquire_lock "$SPEC2PR_HOME/$repo_id.chain.lock"; then
  chain_finish 1 "HALT: chain already running for $repo_id"
fi

chain_status "OK started specs=$total"

merged_count=0

# === per-spec loop (Task 2 replaces this stub) ===
chain_finish 0 "DONE merged=$merged_count/$total"
```

- [ ] **Step 5: Make the script executable**

Run: `chmod +x scripts/spec2pr-chain.sh`
Expected: no output.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | tail -1`
Expected: `N tests run, 0 failed` (the two new `test_chain_*` preflight tests pass; all pre-existing tests still pass).

- [ ] **Step 7: Commit**

```bash
git add scripts/spec2pr-chain.sh tests/spec2pr/test-chain.sh tests/spec2pr/helpers.sh
git commit -m "feat(spec2pr-chain): orchestrator skeleton with preflight + repo lock"
```

---

## Task 2: The per-spec loop — run, merge, marker, teardown (happy chain)

Replaces the stub loop with the real loop: skip already-merged specs, run `spec2pr.sh`, halt on any non-`DONE` exit, squash-merge on `DONE`, write the `<ID>.merged` marker, and tear the worktree/branch down. Adds the `gh pr merge` stub case and the end-to-end happy-chain test.

**Files:**
- Modify: `scripts/spec2pr-chain.sh` (replace the stub loop)
- Modify: `tests/spec2pr/stub-gh.sh` (add `pr merge` case)
- Modify: `tests/spec2pr/test-chain.sh` (add `queue_chain_spec` helper + happy-chain test)

**Interfaces:**
- Consumes (from Task 1): `GIT_ROOT`, `total`, `SPEC_ABS_LIST[]`, `ID_LIST[]`, `SLUG_LIST[]`, `SCRIPT_DIR`, `FAST`, `merged_count`, `chain_status`, `chain_finish`, `SPEC2PR_HOME`.
- Consumes (from `spec2pr.sh`): exit `0` + a `SPEC2PR DONE pr=<url> worktree=<path>` line on stdout; exit `1`/`2`/`3` with a terminal `SPEC2PR …` line on stdout.
- Produces: `<ID>.merged` marker files with `pr=`, `merge=`, `merged_at=` lines (consumed by Task 1's skip check on resume).

- [ ] **Step 1: Add the `pr merge` case to `tests/spec2pr/stub-gh.sh`**

Add this case to the `case "${1:-} ${2:-}" in` block in `tests/spec2pr/stub-gh.sh`, after the `"pr ready")` case and before the closing `esac`:

```bash
  "pr merge")
    if [ -f "$dir/pr-merge-fail" ]; then
      cat "$dir/pr-merge-fail" >&2
      exit 9
    fi
    # Simulate GitHub's squash merge: advance the bare origin's main from the
    # current PR worktree (gh is invoked with cwd = the worktree) so the next
    # real spec2pr.sh fetch observes the predecessor's commits on main.
    git push -q origin HEAD:refs/heads/main
    echo "merged"
    ;;
```

Also update the stub's header comment block (the lines documenting the fixture files) to mention the new fixture. Change this comment line:

```bash
#   pr-review-fail / pr-ready-fail - if present, `pr review` / `pr ready`
#                   print it to stderr and exit 9 (else echo ok)
```

to:

```bash
#   pr-review-fail / pr-ready-fail - if present, `pr review` / `pr ready`
#                   print it to stderr and exit 9 (else echo ok)
#   pr-merge-fail - if present, `pr merge` prints it to stderr and exits 9;
#                   else it pushes the worktree HEAD to origin/main and echoes ok
```

- [ ] **Step 2: Add the `queue_chain_spec` helper + happy-chain test to `tests/spec2pr/test-chain.sh`**

Add the helper near the top of `tests/spec2pr/test-chain.sh` (after the `run_chain` function), then add the test function below it:

```bash
# Queue every fixture one toy spec needs to reach DONE, ordered so the stub
# queues hand them out in call order. <ordinal> orders specs (1<2<3); the
# per-step letter orders calls within a spec (codex: a spec-review, b plan-
# review, c implement; claude: a plan, b forecast, c pr-review, d classify).
# The implement fixture writes a unique marker-<slug>.txt and, when <prereq> is
# given, first asserts the predecessor's file is present in this worktree's
# base (proving the spec branched off a freshly merged main).
queue_chain_spec() { # <ordinal> <slug> [<prereq-file>]
  local n="$1" slug="$2" prereq="${3:-}"

  enqueue "${n}a-$slug-spec-review" <<'EOF'
printf '{"blockers_found":0,"majors_found":0,"findings":[],"notes":"clean"}'
EOF
  enqueue "${n}b-$slug-plan-review" <<'EOF'
printf '{"blockers_found":0,"majors_found":0,"findings":[],"notes":"clean"}'
EOF
  enqueue "${n}c-$slug-implement" <<EOF
if [ -n "$prereq" ]; then
  test -f "$prereq" || { echo "missing prereq $prereq" >&2; exit 1; }
fi
printf 'x\n' > "marker-$slug.txt"
git add "marker-$slug.txt"
git commit -qm "implement $slug"
printf '{"status":"done","summary":"implemented $slug","blocked_reason":""}'
EOF

  enqueue_claude "${n}a-$slug-plan" <<EOF
mkdir -p docs/superpowers/plans
printf '# Plan for $slug\n' > docs/superpowers/plans/$slug-plan.md
printf '{"result":"wrote plan"}'
EOF
  enqueue_claude "${n}b-$slug-forecast" <<EOF
plan_sha="\$(sha256sum docs/superpowers/plans/$slug-plan.md | awk '{print \$1}')"
spec_sha="\$(sha256sum docs/superpowers/specs/$slug.md | awk '{print \$1}')"
base_sha="\$(git merge-base origin/main HEAD)"
cur_bytes="\$(git diff "\$base_sha...HEAD" | wc -c | tr -d ' ')"
est=\$((cur_bytes + 40))
printf '{"result":{"plan_sha256":"%s","spec_sha256":"%s","current_diff_bytes":%s,"files":[{"path":"marker-$slug.txt","loc":1}],"total_loc":1,"implementation_est_bytes":40,"est_bytes":%s,"verdict":"fits"}}' \
  "\$plan_sha" "\$spec_sha" "\$cur_bytes" "\$est"
EOF
  enqueue_claude "${n}c-$slug-prr-review" <<'EOF'
printf '{"result":"No blocker or major findings."}'
EOF
  enqueue_claude "${n}d-$slug-prr-classify" <<'EOF'
printf '{"result":{"blockers_found":0,"majors_found":0}}'
EOF
}

test_chain_happy_path() {
  make_sandbox
  local a b c
  a="$(add_spec chain-a)"
  b="$(add_spec chain-b)"
  c="$(add_spec chain-c)"
  queue_chain_spec 1 chain-a
  queue_chain_spec 2 chain-b marker-chain-a.txt
  queue_chain_spec 3 chain-c marker-chain-b.txt

  run_chain "$a" "$b" "$c"

  assert_eq "0" "$RC" "happy chain exits 0"
  assert_contains "$OUT" "CHAIN OK started specs=3" "started line"
  assert_contains "$OUT" "CHAIN OK merged chain-a pr=https://example.com/pr/1" "merged a line"
  assert_contains "$OUT" "CHAIN DONE merged=3/3" "chain done 3/3"

  assert_file_exists "$SPEC2PR_HOME/project-chain-a.merged" "marker a written"
  assert_file_exists "$SPEC2PR_HOME/project-chain-b.merged" "marker b written"
  assert_file_exists "$SPEC2PR_HOME/project-chain-c.merged" "marker c written"

  assert_eq "3" "$(grep -c 'args=pr merge' "$SPEC2PR_TEST_GH/gh.log")" "three pr merge calls"

  assert_file_absent "$SPEC2PR_WORKTREES/project-chain-a" "worktree a torn down"
  assert_file_absent "$SPEC2PR_WORKTREES/project-chain-b" "worktree b torn down"
  assert_file_absent "$SPEC2PR_WORKTREES/project-chain-c" "worktree c torn down"

  # Each later spec branched from a freshly merged main: the implement fixtures
  # asserted the predecessor's marker at run time (a missing prereq exits 1 ->
  # chain HALT, not DONE), and the final origin/main carries all three.
  git -C "$PROJECT" fetch -q origin main
  local tree; tree="$(git -C "$PROJECT" ls-tree -r --name-only origin/main)"
  assert_contains "$tree" "marker-chain-a.txt" "origin main has marker a"
  assert_contains "$tree" "marker-chain-b.txt" "origin main has marker b"
  assert_contains "$tree" "marker-chain-c.txt" "origin main has marker c"
}
```

- [ ] **Step 3: Run the happy-chain test to verify it fails**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A1 test_chain_happy_path`
Expected: FAIL — the stub loop emits `CHAIN DONE merged=0/3` and writes no markers / runs no spec2pr, so the `merged=3/3`, marker, and `pr merge` assertions fail.

- [ ] **Step 4: Replace the stub loop in `scripts/spec2pr-chain.sh`**

Replace this stub block (the last two lines of the script):

```bash
# === per-spec loop (Task 2 replaces this stub) ===
chain_finish 0 "DONE merged=$merged_count/$total"
```

with the real loop:

```bash
# -- per-spec loop ------------------------------------------------------------
i=0
while [ "$i" -lt "$total" ]; do
  spec_abs="${SPEC_ABS_LIST[$i]}"
  id="${ID_LIST[$i]}"
  slug="${SLUG_LIST[$i]}"
  marker="$SPEC2PR_HOME/$id.merged"
  i=$((i + 1))

  # 1. Skip a spec only while its marker's merge commit is still reachable from
  #    the current origin/main. A missing/unparseable/unreachable commit is a
  #    stale marker -> halt (do not trust it, do not silently re-run).
  if [ -f "$marker" ]; then
    merge_commit="$(sed -n 's/^merge=//p' "$marker" | head -n1)"
    git -C "$GIT_ROOT" fetch -q origin main \
      || chain_finish 1 "HALT $slug: git fetch origin main failed"
    remote_main="$(git -C "$GIT_ROOT" rev-parse origin/main 2>/dev/null || true)"
    if [ -n "$merge_commit" ] \
        && ! git -C "$GIT_ROOT" cat-file -e "$merge_commit^{commit}" 2>/dev/null; then
      git -C "$GIT_ROOT" fetch -q origin "$merge_commit" 2>/dev/null || true
    fi
    if [ -n "$merge_commit" ] && [ -n "$remote_main" ] \
        && git -C "$GIT_ROOT" cat-file -e "$merge_commit^{commit}" 2>/dev/null \
        && git -C "$GIT_ROOT" merge-base --is-ancestor "$merge_commit" "$remote_main"; then
      chain_status "OK skipped $slug (already merged)"
      merged_count=$((merged_count + 1))
      continue
    fi
    chain_finish 1 "HALT $slug: stale merged marker"
  fi

  # 2. Run the UNMODIFIED single-spec tool, resolved relative to THIS script
  #    (never relative to the spec path). Capture stdout for the contract line.
  set +e
  if [ "$FAST" -eq 1 ]; then
    spec_out="$(bash "$SCRIPT_DIR/spec2pr.sh" --fast "$spec_abs")"
  else
    spec_out="$(bash "$SCRIPT_DIR/spec2pr.sh" "$spec_abs")"
  fi
  spec_rc=$?
  set -e

  # 3. Branch on exit code: non-zero (HALT/SPLIT/DIRTY) stops the chain and
  #    carries spec2pr's own terminal line; already-merged specs stay merged.
  if [ "$spec_rc" -ne 0 ]; then
    terminal="$(printf '%s\n' "$spec_out" | grep -E '^SPEC2PR ' | tail -n1 || true)"
    chain_finish 1 "HALT $slug: $terminal"
  fi
  done_line="$(printf '%s\n' "$spec_out" | grep -E '^SPEC2PR DONE ' | tail -n1 || true)"
  [ -n "$done_line" ] || chain_finish 1 "HALT $slug: spec2pr exited 0 without DONE line"
  pr_url="${done_line##*pr=}"; pr_url="${pr_url%% *}"
  wt="${done_line##*worktree=}"
  { [ -n "$pr_url" ] && [ -n "$wt" ]; } \
    || chain_finish 1 "HALT $slug: could not parse spec2pr DONE line"

  # 4. Merge (happy path only). Any non-zero result stops the chain; part 2
  #    replaces this blanket halt with merge-state inspection and resolution.
  set +e
  merge_err="$(cd "$wt" && gh pr merge "$pr_url" --squash --delete-branch 2>&1 1>/dev/null)"
  merge_rc=$?
  set -e
  if [ "$merge_rc" -ne 0 ]; then
    chain_finish 1 "HALT $slug: merge failed ($merge_err)"
  fi
  merge_commit="$(git -C "$GIT_ROOT" ls-remote origin refs/heads/main | awk 'NR==1{print $1}')"
  [ -n "$merge_commit" ] || chain_finish 1 "HALT $slug: merge commit lookup failed"

  {
    printf 'pr=%s\n' "$pr_url"
    printf 'merge=%s\n' "$merge_commit"
    printf 'merged_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$marker"
  chain_status "OK merged $slug pr=$pr_url"
  merged_count=$((merged_count + 1))

  # 5. Tear down the artifacts the single-spec tool leaves behind. With
  #    --delete-branch this makes resurrection of a merged spec impossible.
  #    The "$SPEC2PR_HOME/$id/" meta dir is kept for audit.
  git -C "$GIT_ROOT" worktree remove --force "$wt" 2>/dev/null || true
  git -C "$GIT_ROOT" branch -D "spec2pr/$slug" 2>/dev/null || true
done

chain_finish 0 "DONE merged=$merged_count/$total"
```

- [ ] **Step 5: Run the happy-chain test to verify it passes**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | tail -1`
Expected: `N tests run, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add scripts/spec2pr-chain.sh tests/spec2pr/stub-gh.sh tests/spec2pr/test-chain.sh
git commit -m "feat(spec2pr-chain): run/merge/marker/teardown loop (happy chain)"
```

---

## Task 3: Mid-chain stop test

Verifies that a non-`DONE` spec stops the chain with spec2pr's terminal line, earlier specs stay merged, and later specs never run. The loop already implements this (Task 2, step 3); this task adds the helper and test that prove it.

**Files:**
- Modify: `tests/spec2pr/test-chain.sh` (add `queue_chain_spec_dirty` + test)

**Interfaces:**
- Consumes: the loop's exit-code branch from Task 2; the `enqueue` helper from `helpers.sh`.

- [ ] **Step 1: Add the `queue_chain_spec_dirty` helper + test**

Add to `tests/spec2pr/test-chain.sh` (after `queue_chain_spec`):

```bash
# Queue a spec that DIRTYs at spec-review: three rounds, each reporting one
# blocker and changing nothing, so spec2pr exhausts MAX_FIX_ROUNDS and exits 3
# (SPEC2PR DIRTY spec-review ...). No plan/forecast/implement fixtures are
# consumed, so the chain halts before reaching them.
queue_chain_spec_dirty() { # <ordinal> <slug>
  local n="$1" slug="$2" r
  for r in 1 2 3; do
    enqueue "${n}a-$slug-spec-review-r$r" <<'EOF'
printf '{"blockers_found":1,"majors_found":0,"findings":[{"severity":"blocker","artifact":"spec","summary":"needs work","evidence":"unfixable"}],"notes":""}'
EOF
  done
}

test_chain_mid_chain_stop() {
  make_sandbox
  local a b c
  a="$(add_spec chain-a)"
  b="$(add_spec chain-b)"
  c="$(add_spec chain-c)"
  queue_chain_spec 1 chain-a
  queue_chain_spec_dirty 2 chain-b
  queue_chain_spec 3 chain-c marker-chain-b.txt

  run_chain "$a" "$b" "$c"

  assert_eq "1" "$RC" "mid-chain halt exits 1"
  assert_contains "$OUT" "CHAIN HALT chain-b: SPEC2PR DIRTY spec-review" "halt carries spec2pr terminal line"
  assert_file_exists "$SPEC2PR_HOME/project-chain-a.merged" "spec 1 stays merged"
  assert_file_absent "$SPEC2PR_HOME/project-chain-b.merged" "spec 2 not merged"
  assert_file_absent "$SPEC2PR_HOME/project-chain-c.merged" "spec 3 not merged"
  assert_eq "1" "$(grep -c 'args=pr merge' "$SPEC2PR_TEST_GH/gh.log")" "only spec 1 merged"
  assert_file_exists "$SPEC2PR_TEST_FIXTURES/3a-chain-c-spec-review.sh" "spec 3 fixtures unconsumed"
}
```

- [ ] **Step 2: Run the test to verify it passes**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A1 test_chain_mid_chain_stop; bash tests/spec2pr/run-tests.sh 2>&1 | tail -1`
Expected: the `test_chain_mid_chain_stop` block shows only `ok:` lines, and the final line is `N tests run, 0 failed`.

- [ ] **Step 3: Commit**

```bash
git add tests/spec2pr/test-chain.sh
git commit -m "test(spec2pr-chain): mid-chain stop leaves earlier specs merged"
```

---

## Task 4: Resume test (skip already-merged specs)

Verifies the resume path: a spec whose marker's merge commit is reachable from the current `origin/main` is skipped (no second merge) and the chain runs the remaining specs to `CHAIN DONE`. This is deterministic — it seeds a merged predecessor on `origin/main` and its marker, rather than depending on a prior run's fixture residue, but exercises the same skip invariant from Task 2 step 1.

**Files:**
- Modify: `tests/spec2pr/test-chain.sh` (add test)

**Interfaces:**
- Consumes: the loop's marker-skip branch from Task 2 step 1; `queue_chain_spec` from Task 2.

- [ ] **Step 1: Add the resume test**

Add to `tests/spec2pr/test-chain.sh`:

```bash
test_chain_resume_skips_merged() {
  make_sandbox
  local a b c
  a="$(add_spec chain-a)"
  b="$(add_spec chain-b)"
  c="$(add_spec chain-c)"

  # Simulate chain-a already merged: put its marker file on origin/main and
  # write a marker whose merge= commit is the current origin/main tip.
  printf 'x\n' > "$PROJECT/marker-chain-a.txt"
  git -C "$PROJECT" add marker-chain-a.txt
  git -C "$PROJECT" commit -qm "merged chain-a"
  git -C "$PROJECT" push -q origin main
  local a_sha; a_sha="$(git -C "$PROJECT" rev-parse origin/main)"
  printf 'pr=https://example.com/pr/1\nmerge=%s\nmerged_at=2026-06-29T00:00:00Z\n' "$a_sha" \
    > "$SPEC2PR_HOME/project-chain-a.merged"

  # Only the unmerged specs have fixtures queued.
  queue_chain_spec 2 chain-b marker-chain-a.txt
  queue_chain_spec 3 chain-c marker-chain-b.txt

  run_chain "$a" "$b" "$c"

  assert_eq "0" "$RC" "resume exits 0"
  assert_contains "$OUT" "CHAIN OK skipped chain-a (already merged)" "spec 1 skipped via marker"
  assert_contains "$OUT" "CHAIN DONE merged=3/3" "resume completes 3/3"
  # chain-a is never re-run (no fixtures queued for it) and never re-merged.
  assert_eq "2" "$(grep -c 'args=pr merge' "$SPEC2PR_TEST_GH/gh.log")" "only b and c merged"
  assert_file_absent "$SPEC2PR_WORKTREES/project-chain-a" "skipped spec gets no worktree"
}
```

- [ ] **Step 2: Run the test to verify it passes**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A1 test_chain_resume_skips_merged; bash tests/spec2pr/run-tests.sh 2>&1 | tail -1`
Expected: the `test_chain_resume_skips_merged` block shows only `ok:` lines, and the final line is `N tests run, 0 failed`.

- [ ] **Step 3: Commit**

```bash
git add tests/spec2pr/test-chain.sh
git commit -m "test(spec2pr-chain): resume skips specs already merged into main"
```

---

## Task 5: Stale-marker rejection test

Verifies that a marker whose recorded `merge=` commit is absent from the current `origin/main` halts the chain instead of silently skipping the spec. The loop already implements this (Task 2 step 1); this task proves it.

**Files:**
- Modify: `tests/spec2pr/test-chain.sh` (add test)

**Interfaces:**
- Consumes: the loop's stale-marker branch from Task 2 step 1.

- [ ] **Step 1: Add the stale-marker test**

Add to `tests/spec2pr/test-chain.sh`:

```bash
test_chain_stale_marker_halts() {
  make_sandbox
  local a; a="$(add_spec chain-a)"

  # Marker recording a merge commit that does not exist on origin/main.
  printf 'pr=https://example.com/pr/1\nmerge=%s\nmerged_at=2026-06-29T00:00:00Z\n' \
    "0000000000000000000000000000000000000000" \
    > "$SPEC2PR_HOME/project-chain-a.merged"

  run_chain "$a"

  assert_eq "1" "$RC" "stale marker exits 1"
  assert_contains "$OUT" "CHAIN HALT chain-a: stale merged marker" "stale marker halt line"
  assert_eq "0" "$(codex_calls)" "stale marker halts before any spec2pr run"
}
```

- [ ] **Step 2: Run the test to verify it passes**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A1 test_chain_stale_marker_halts; bash tests/spec2pr/run-tests.sh 2>&1 | tail -1`
Expected: the `test_chain_stale_marker_halts` block shows only `ok:` lines, and the final line is `N tests run, 0 failed`.

- [ ] **Step 3: Commit**

```bash
git add tests/spec2pr/test-chain.sh
git commit -m "test(spec2pr-chain): stale merged marker halts instead of skipping"
```

---

## Task 6: Command, split pointer, and version bump

Adds the `/rulez:spec2pr-chain` command, the one-shot pointer in `spec2pr-split.md`, and the version/upgrade notes. These are documentation/command artifacts verified by read-through (matching how `spec2pr.md` and `spec2pr-split.md` are verified), not unit tests.

**Files:**
- Create: `commands/rulez/spec2pr-chain.md`
- Modify: `commands/rulez/spec2pr-split.md` (step 5 pointer)
- Modify: `VERSION`
- Modify: `UPGRADE.md`

**Interfaces:**
- Consumes: the orchestrator's `status` subcommand and `CHAIN …` terminal lines from Task 1/Task 2.

- [ ] **Step 1: Create `commands/rulez/spec2pr-chain.md`**

```markdown
# Spec2PR Chain

Run several brainstormed specs in dependency order, squash-merging each PR
before the next spec starts, so each spec branches off a `main` that already
contains its predecessors. A spec that does not reach DONE, or a PR that does
not merge cleanly, stops the chain.

## Usage

- `/rulez:spec2pr-chain <spec…>` — run the ordered list of specs
- `/rulez:spec2pr-chain --fast <spec…>` — forward `--fast` to each spec2pr run
- `/rulez:spec2pr-chain status` — show the latest state of every chain

## Instructions

If the argument is `status`:

1. Run:
   `bash ~/.claude/skills/rulez-claudeset/scripts/spec2pr-chain.sh status`
2. Present the result as-is. Stop.

Otherwise:

1. Parse an optional leading `--fast` flag; everything after it is the ordered
   spec list. Require at least one spec path.
2. If any spec file does not exist, tell the user and stop.
3. Launch the orchestrator as one **background** Bash task (single call,
   `run_in_background: true`), the same pattern `/rulez:spec2pr` uses:
   `bash ~/.claude/skills/rulez-claudeset/scripts/spec2pr-chain.sh [--fast] <spec…>`
   If `--fast` was not supplied, omit it.
4. Tell the user the chain has started, that a completion notification will
   arrive in this session, and that `/rulez:spec2pr-chain status` shows
   progress meanwhile. Do not poll.

When the background task completes, read the last `CHAIN` line of its output
and react:

- `CHAIN DONE merged=<n>/<total>` — every spec merged; report the count.
- `CHAIN HALT <slug>: <reason>` — the chain stopped at `<slug>`. Earlier specs
  stayed merged; show the reason. If `<reason>` is a forwarded `SPEC2PR …`
  line (DIRTY/HALT/SPLIT), treat it like the matching `/rulez:spec2pr`
  outcome for that one spec, then re-run `/rulez:spec2pr-chain <spec…>` to
  resume past the specs already merged.
- `CHAIN HALT: <reason>` (no slug — preflight or lock) — fix the invocation
  (same repo, no duplicate IDs, no other chain running) and re-run.
```

- [ ] **Step 2: Add the one-shot pointer to `commands/rulez/spec2pr-split.md`**

In step 5, replace this block (the `git pull` / part-2 tail of the sequencing recipe):

```markdown
     - `git pull --ff-only origin main`
     - `bash ~/.claude/skills/rulez-claudeset/scripts/git-publish-spec.sh <part-2-path>`
     - `/rulez:spec2pr <part-2-path>`, then
       review and merge that PR
```

with:

```markdown
     - `git pull --ff-only origin main`
     - `bash ~/.claude/skills/rulez-claudeset/scripts/git-publish-spec.sh <part-2-path>`
     - `/rulez:spec2pr <part-2-path>`, then
       review and merge that PR
   - One-shot alternative to the manual sequence above: after publishing the
     part specs, run
     `/rulez:spec2pr-chain <part-1-path> <part-2-path>`
     to process both parts in order, auto-merging each PR before the next.
```

- [ ] **Step 3: Bump `VERSION`**

Replace the contents of `VERSION` (`1.8.0`) with:

```
1.9.0
```

- [ ] **Step 4: Add the `UPGRADE.md` section**

Insert this section in `UPGRADE.md` immediately after the header block (before `## To v1.8.0 - from v1.7.2`):

```markdown
## To v1.9.0 - from v1.8.0

**Action:** None.

**Caveat:** new `/rulez:spec2pr-chain <spec…>` processes specs in order,
auto-merging each PR (squash, delete branch) before the next so each builds on
its predecessors; it stops at the first spec that does not reach DONE or whose
PR does not merge cleanly, and re-running resumes past the specs already
merged.
```

- [ ] **Step 5: Verify the command and split files read correctly**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | tail -1`
Expected: `N tests run, 0 failed` (no regressions; docs changes do not affect tests).

Then read `commands/rulez/spec2pr-chain.md` and the edited step 5 of `commands/rulez/spec2pr-split.md` end-to-end and confirm: the `status` branch calls the script, the launch is a single background Bash task, and the part paths in the split pointer match the computed `<part-1-path>`/`<part-2-path>` placeholders.

- [ ] **Step 6: Commit**

```bash
git add commands/rulez/spec2pr-chain.md commands/rulez/spec2pr-split.md VERSION UPGRADE.md
git commit -m "feat(spec2pr-chain): add command, split pointer, version 1.9.0"
```

---

## Self-Review

**Spec coverage** — every spec section maps to a task:

- Orchestrator (`spec2pr-chain.sh`): Tasks 1 (skeleton/preflight/lock/status) + 2 (loop/merge/marker/teardown).
- Stage-free `CHAIN` lines, `chain_status`/`chain_finish`, `FINISHED=1`, non-exported `CONTRACT_PREFIX`: Task 1 (helpers + sourcing) — listed in Global Constraints.
- Preflight (single repo, duplicate IDs, path resolution): Task 1.
- Repo-scoped lock (`chain_acquire_lock`, repo-id basename+hash, release-on-own-pid): Task 1.
- Per-spec loop (ID formula, marker skip, run via `SCRIPT_DIR`, exit-code branch): Task 2.
- Merge happy path (`gh pr merge --squash --delete-branch`, merge-commit lookup, marker write): Task 2.
- Merged markers / resume / teardown: Tasks 2 (write/teardown) + 4 (resume skip).
- Status surface (chain log under `chains/<chain-id>.status`): Task 1 (path + `chain_status`) and the `status` subcommand (Task 1).
- Command `spec2pr-chain.md`: Task 6.
- `spec2pr-split.md` pointer: Task 6.
- Edge cases & invariants: spec2pr untouched (Global Constraints), idempotent resume (Task 4), any non-clean merge halts (Task 2 + 3), repo lock (Task 1), single-repo (Task 1 + mixed-repo test), duplicate IDs (Task 1 test), stdout capture (Task 2).
- Testing — all six spec tests present: happy chain (Task 2), mid-chain stop (Task 3), resume (Task 4), mixed-repo (Task 1), duplicate-ID (Task 1), stale marker (Task 5). Supporting `stub-gh.sh pr merge` (Task 2), `helpers.sh add_spec` (Task 1).
- Versioning (`VERSION` → 1.9.0, `UPGRADE.md`): Task 6. Coordination note resolved: forecast already took 1.8.0, so chain takes 1.9.0.
- Out of scope (merge-state inspection, conflict resolution, BEHIND, `--admin`): deliberately absent — Task 2's merge halts blanketly on any failure, as the spec requires for part 1.

**Two conditional spec items** were resolved with recorded decisions (File Structure): no `lib/spec2pr-runtime.sh` edit (inline the ID formula), and no `run-tests.sh` edit (the glob auto-discovers `test-chain.sh`). Both are within the spec's stated latitude.

**Placeholder scan:** no `TBD`/`TODO`/"add error handling"/"write tests for the above" — every code and test block is complete.

**Type/name consistency:** contract strings, helper names (`chain_status`, `chain_finish`, `chain_acquire_lock`, `chain_release_lock`, `short_hash`, `add_spec`, `queue_chain_spec`, `queue_chain_spec_dirty`, `run_chain`), array names (`SPEC_ABS_LIST`/`ID_LIST`/`SLUG_LIST`), marker fields (`pr=`/`merge=`/`merged_at=`), and IDs (`project-chain-a`, branch `spec2pr/<slug>`) are used identically across the orchestrator and the tests.
