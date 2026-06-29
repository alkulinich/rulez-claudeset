# spec2pr Budget Forecast + Size-Limit Override Flags Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Forecast the final PR diff size after `plan-review` (before the expensive `implement` call) so over-limit runs stop early with a split recommendation, and add operator override flags to force a run past a size limit.

**Architecture:** Three changes to the existing Bash pipeline. (1) A new fail-soft `forecast` step runs a separate `claude` call right before a fresh `implement`, estimates the eventual diff, and either continues, splits early, or warns-and-continues on error. (2) New `--ignore-plan-limit` / `--ignore-pr-limit` flags guard the existing hard size gates. (3) The manual split-tooling learns the new `SPLIT forecast` token. The planner prompt is untouched (separate forecast call, not a budget baked into the plan).

**Tech Stack:** Bash (`set -euo pipefail`), `jq`, `git`, `gh`. Tests are integration-style under `tests/spec2pr/` using stub `claude`/`codex`/`gh` CLIs that consume queued fixtures.

## Global Constraints

These apply to every task. Copy values verbatim.

- **Version bump:** `VERSION` `1.7.1` → `1.8.0`. Do this only in Task 6.
- **Bytes-per-line constant:** `~40`, named and tunable in one place (`SPEC2PR_FORECAST_BYTES_PER_LINE`, default `40`).
- **Diff limit:** `SPEC2PR_MAX_DIFF` default `131072`. Plan limit: `SPEC2PR_MAX_PLAN` default `65536`.
- **Kill-switch:** `SPEC2PR_FORECAST=0` skips the forecast step entirely (default `1`).
- **Fail-soft is mandatory for forecast only:** any forecast error → `WARN` status + continue to implement. The hard `SPEC2PR_MAX_DIFF` gate in `pr-review-engine.sh` remains the backstop. Every other stage keeps its fail-loud `halt` behavior.
- **Override flag semantics:** `--ignore-plan-limit` sets `IGNORE_PLAN_LIMIT=1` (spec2pr only). `--ignore-pr-limit` sets `IGNORE_PR_LIMIT=1` (spec2pr **and** review-pr); it suppresses **both** the forecast early-stop and the hard diff gate.
- **Exact contract lines** (printed via `status`/`finish`; `status` formats as `<PREFIX> <LEVEL> <STAGE>: <msg>`, default `PREFIX=SPEC2PR`):
  - `SPEC2PR OK forecast: fits est=<n> limit=131072`
  - `SPEC2PR OK forecast: est=<n> exceeds limit; overridden`
  - `SPEC2PR OK plan: size=<n> exceeds limit; overridden`
  - `SPEC2PR OK pr-review: diff size=<n> exceeds limit; overridden` (PREFIX `PRREVIEW` from review-pr)
  - `SPEC2PR WARN forecast: <reason>; proceeding to implement`
  - `SPEC2PR SPLIT forecast est=<n> limit=131072` (terminal, exit 2; recommended split summary is printed to stdout immediately before this line)
- **Forecast is not a `--start-from` target.** The `--start-from` surface stays `spec-review|plan|plan-review|implementation`.
- **Forecast runs on `claude`, never `codex`** (separate quota), and only on the way to a *new* implement call (never when a valid local implementation, remote branch, or open PR is reused).

---

## File Structure

| File | Responsibility | Tasks |
| --- | --- | --- |
| `scripts/lib/spec2pr-runtime.sh` | forecast env defaults, `split_forecast`, `forecast_claude_attempt`, `forecast_payload_valid` | 2 |
| `scripts/spec2pr.sh` | override-flag parsing, plan-gate guard, the forecast step, start-from cleanup | 1, 3, 4 |
| `scripts/review-pr.sh` | `--ignore-pr-limit` parsing | 1 |
| `scripts/lib/pr-review-engine.sh` | `IGNORE_PR_LIMIT` guard on the diff gate | 1 |
| `scripts/spec2pr-split-context.sh` | recognize `SPLIT forecast`, emit `gate=forecast` | 5 |
| `commands/rulez/spec2pr-split.md` | document forecast splits | 5 |
| `commands/rulez/spec2pr.md` | document new flags + forecast behavior | 6 |
| `tests/spec2pr/helpers.sh` | `queue_clean_forecast` shared fixture helper | 3 |
| `tests/spec2pr/test-forecast.sh` (new) | forecast unit + integration cases | 2, 3, 4 |
| `tests/spec2pr/test-spec2pr-split-context.sh` | `SPLIT forecast` fixture | 5 |
| existing `tests/spec2pr/test-*.sh` | enqueue forecast fixture on full runs, bump claude counts | 3 |
| `VERSION`, `UPGRADE.md` | minor bump + note | 6 |

Run the whole suite with `bash tests/spec2pr/run-tests.sh` after every task; it must end `N tests run, 0 failed`.

---

## Task 1: Size-limit override flags + hard-gate guards

Independent of the forecast. Adds the two flags and wires them into the two *measured* hard gates (plan-file gate, diff gate). The forecast early-stop override is added in Task 3.

**Files:**
- Modify: `scripts/spec2pr.sh` (arg loop near `:13`; plan gate near `:412`)
- Modify: `scripts/review-pr.sh` (arg loop near `:31`)
- Modify: `scripts/lib/pr-review-engine.sh` (diff gate near `:85`)
- Test: `tests/spec2pr/test-stages.sh` (plan override), `tests/spec2pr/test-review-pr.sh` (diff override)

**Interfaces:**
- Produces: shell vars `IGNORE_PLAN_LIMIT` (set to `1` by `--ignore-plan-limit`), `IGNORE_PR_LIMIT` (set to `1` by `--ignore-pr-limit`). Both read elsewhere as `${IGNORE_PLAN_LIMIT:-}` / `${IGNORE_PR_LIMIT:-}` (safe under `set -u`). No init needed.

- [ ] **Step 1: Write the failing test — plan-limit override (append to `tests/spec2pr/test-stages.sh`)**

```bash
test_ignore_plan_limit_proceeds_past_plan_gate() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  enqueue_claude 02-plan <<'EOF'
mkdir -p docs/superpowers/plans
perl -e 'print "x" x 70000' > docs/superpowers/plans/toy-spec-plan.md
printf '{"result":"large"}'
EOF
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  queue_spec2pr_subject_implementation_commit 05-implement
  queue_clean_pr_review 06-pr-review
  run_spec2pr --ignore-plan-limit "$SPEC"

  assert_eq "0" "$RC" "ignore-plan-limit run reaches done"
  assert_contains "$OUT" "SPEC2PR OK plan: size=70000 exceeds limit; overridden" \
    "plan override status line printed"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1" "override run reaches done"
}
```

Note: `queue_clean_forecast` is defined in Task 3. This test will be runnable end-to-end only after Task 3 wires the forecast in; until then it fails at the forecast call (acceptable for the override-line assertion below, which is verified by the diff-override test in this task and re-confirmed when the suite is green at the end of Task 3). For Task 1's own green bar, verify the override line via the review-pr diff test (Step 4) which has no forecast dependency.

- [ ] **Step 2: Add flag parsing to `scripts/spec2pr.sh`**

In the `while [ "$#" -gt 0 ]` arg loop (currently `:14`), add two cases before the `--*)` catch-all:

```bash
    --ignore-plan-limit)
      IGNORE_PLAN_LIMIT=1
      shift
      ;;
    --ignore-pr-limit)
      IGNORE_PR_LIMIT=1
      shift
      ;;
```

- [ ] **Step 3: Guard the plan-file gate in `scripts/spec2pr.sh`**

Replace the plan-size gate (currently `:411-414`):

```bash
    plan_size="$(wc -c < "$WORKTREE/$WT_PLAN_REL" | tr -d ' ')"
    if [ "$plan_size" -gt "$SPEC2PR_MAX_PLAN" ]; then
      split plan "$plan_size" "$SPEC2PR_MAX_PLAN"
    fi
```

with:

```bash
    plan_size="$(wc -c < "$WORKTREE/$WT_PLAN_REL" | tr -d ' ')"
    if [ "$plan_size" -gt "$SPEC2PR_MAX_PLAN" ]; then
      if [ -n "${IGNORE_PLAN_LIMIT:-}" ]; then
        status "OK" "size=$plan_size exceeds limit; overridden"
      else
        split plan "$plan_size" "$SPEC2PR_MAX_PLAN"
      fi
    fi
```

(`STAGE` is `plan` here, so `status "OK" "size=..."` renders `SPEC2PR OK plan: size=<n> exceeds limit; overridden`.)

- [ ] **Step 4: Write the failing test — diff-limit override (append to `tests/spec2pr/test-review-pr.sh`)**

Locate an existing clean review-pr test in this file to copy its sandbox/fixture setup (e.g. the test asserting "clean path: review + classify"). Add a test that forces an over-limit diff and passes `--ignore-pr-limit`. Use the same helpers that test file already uses to stand up a PR worktree; the key new assertions are:

```bash
test_review_pr_ignore_pr_limit_proceeds_past_diff_gate() {
  make_sandbox
  setup_review_pr_worktree   # reuse this file's existing PR-worktree setup helper
  # Make the PR diff exceed SPEC2PR_MAX_DIFF (131072 bytes).
  perl -e 'print "x\n" x 70000' > "$WORKTREE_UNDER_TEST/big.txt"
  git -C "$WORKTREE_UNDER_TEST" add big.txt
  git -C "$WORKTREE_UNDER_TEST" commit -qm "oversized change"
  # Push so review-pr fetches an over-limit head (match this file's push convention).
  queue_clean_pr_review_for_reviewpr 01-pr-review   # reuse existing review-pr clean fixtures
  run_review_pr --ignore-pr-limit "$PR_REF"

  assert_contains "$OUT" "PRREVIEW OK pr-review: diff size=" "diff override status printed"
  assert_contains "$OUT" "exceeds limit; overridden" "diff override suffix printed"
}
```

If `tests/spec2pr/test-review-pr.sh` has no reusable worktree/run helpers with these exact names, model this test on the closest existing oversized-diff or clean test in that file: the only behavior under test is "diff over 128 KB + `--ignore-pr-limit` ⇒ no SPLIT, override status printed, review proceeds". Keep the two `assert_contains` lines above verbatim.

- [ ] **Step 5: Run the diff-override test to verify it fails**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A3 ignore_pr_limit`
Expected: FAIL — `--ignore-pr-limit` is not yet parsed by `review-pr.sh`, so it hits the `usage` halt or the diff gate still splits.

- [ ] **Step 6: Add flag parsing to `scripts/review-pr.sh`**

In the `while [ "$#" -gt 0 ]` arg loop (currently `:31`), add before the `--*)` catch-all:

```bash
    --ignore-pr-limit)
      IGNORE_PR_LIMIT=1
      shift
      ;;
```

- [ ] **Step 7: Guard the diff gate in `scripts/lib/pr-review-engine.sh`**

Replace the diff-size gate (currently `:85-87`):

```bash
  if [ "$diff_size" -gt "$SPEC2PR_MAX_DIFF" ]; then
    split diff "$diff_size" "$SPEC2PR_MAX_DIFF"
  fi
```

with:

```bash
  if [ "$diff_size" -gt "$SPEC2PR_MAX_DIFF" ]; then
    if [ "${IGNORE_PR_LIMIT:-}" != 1 ]; then
      split diff "$diff_size" "$SPEC2PR_MAX_DIFF"
    else
      status "OK" "diff size=$diff_size exceeds limit; overridden"
    fi
  fi
```

(`STAGE` is `pr-review` here; `CONTRACT_PREFIX` is `SPEC2PR` from spec2pr and `PRREVIEW` from review-pr, so the same line serves both contracts.)

- [ ] **Step 8: Run the diff-override test to verify it passes**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A3 ignore_pr_limit`
Expected: PASS for `test_review_pr_ignore_pr_limit_proceeds_past_diff_gate`.

- [ ] **Step 9: Run the full suite — confirm no regressions in existing measured-gate tests**

Run: `bash tests/spec2pr/run-tests.sh`
Expected: the pre-existing tests still pass. The new `test_ignore_plan_limit_proceeds_past_plan_gate` will fail until Task 3 (it needs the forecast wired in); that is expected and is fixed at the end of Task 3.

- [ ] **Step 10: Commit**

```bash
git add scripts/spec2pr.sh scripts/review-pr.sh scripts/lib/pr-review-engine.sh \
  tests/spec2pr/test-stages.sh tests/spec2pr/test-review-pr.sh
git commit -m "feat(spec2pr): add --ignore-plan-limit/--ignore-pr-limit override flags for measured size gates"
```

---

## Task 2: Forecast runtime helpers

Pure additions to the shared runtime: env defaults plus three functions. Unit-tested by sourcing the runtime in a subshell (never in the test runner's own process — sourcing installs an `EXIT` trap and `finish` calls `exit`).

**Files:**
- Modify: `scripts/lib/spec2pr-runtime.sh` (config defaults block near `:9`; new helpers after the model-call layer near `:440`)
- Test: `tests/spec2pr/test-forecast.sh` (create)

**Interfaces:**
- Produces:
  - env vars `SPEC2PR_FORECAST` (default `1`), `SPEC2PR_FORECAST_BYTES_PER_LINE` (default `40`)
  - `split_forecast <est-bytes> <limit>` → `finish 2 "SPLIT forecast est=<est> limit=<limit>"` (exits 2)
  - `forecast_claude_attempt <tag> <prompt-file> <out>` → runs claude read-only via `claude_json_attempt`, then enforces the read-only contract. Return codes: `0` ok; `2` claude process failure; `3` invalid envelope JSON; `4` worktree modified (HEAD changed or dirty). On `2`/`3` the worktree is already cleaned by `claude_json_attempt`; on `4` this function cleans back to the pre-call HEAD.
  - `forecast_payload_valid <forecast.json> <plan-sha> <spec-sha>` → exit 0 iff the file is a structurally valid forecast payload whose `plan_sha256`/`spec_sha256` equal the passed shas and whose `est_bytes == current_diff_bytes + implementation_est_bytes`.

- [ ] **Step 1: Write the failing unit tests (create `tests/spec2pr/test-forecast.sh`)**

```bash
#!/usr/bin/env bash
# Forecast step: runtime helpers (this task) + integration cases (Tasks 3-4).

# Source the runtime in a SUBSHELL only: it installs an EXIT trap and `finish`
# calls `exit`, which would abort the whole test runner otherwise.
run_split_forecast() {
  ( source "$REPO_ROOT/scripts/lib/spec2pr-runtime.sh"; STAGE=forecast; split_forecast "$1" "$2" ) 2>&1
}

payload_valid_rc() {  # <json-string> <plan-sha> <spec-sha>
  local f="$SANDBOX/payload.json"
  printf '%s' "$1" > "$f"
  ( source "$REPO_ROOT/scripts/lib/spec2pr-runtime.sh"; forecast_payload_valid "$f" "$2" "$3" )
  printf '%s' "$?"
}

test_split_forecast_emits_forecast_token() {
  make_sandbox
  local out rc
  out="$(run_split_forecast 150000 131072)"; rc=$?
  assert_eq "2" "$rc" "split_forecast exits 2"
  assert_eq "SPEC2PR SPLIT forecast est=150000 limit=131072" "$out" \
    "split_forecast prints the forecast split token"
  rm -rf "$SANDBOX"
}

test_forecast_payload_valid_accepts_good_fits() {
  make_sandbox
  local json
  json='{"plan_sha256":"aa","spec_sha256":"bb","current_diff_bytes":1000,"files":[{"path":"x.ts","loc":10}],"total_loc":10,"implementation_est_bytes":400,"est_bytes":1400,"verdict":"fits"}'
  assert_eq "0" "$(payload_valid_rc "$json" aa bb)" "valid fits payload accepted"
  rm -rf "$SANDBOX"
}

test_forecast_payload_valid_requires_parts_on_exceeds() {
  make_sandbox
  local json
  json='{"plan_sha256":"aa","spec_sha256":"bb","current_diff_bytes":110000,"files":[{"path":"x.ts","loc":1000}],"total_loc":1000,"implementation_est_bytes":40000,"est_bytes":150000,"verdict":"exceeds"}'
  assert_eq "1" "$(payload_valid_rc "$json" aa bb)" "exceeds payload without parts/summary rejected"
  json='{"plan_sha256":"aa","spec_sha256":"bb","current_diff_bytes":110000,"files":[{"path":"x.ts","loc":1000}],"total_loc":1000,"implementation_est_bytes":40000,"est_bytes":150000,"verdict":"exceeds","summary":"split it","parts":["part-1","part-2"]}'
  assert_eq "0" "$(payload_valid_rc "$json" aa bb)" "exceeds payload with parts/summary accepted"
  rm -rf "$SANDBOX"
}

test_forecast_payload_valid_rejects_hash_mismatch() {
  make_sandbox
  local json
  json='{"plan_sha256":"WRONG","spec_sha256":"bb","current_diff_bytes":1000,"files":[],"total_loc":0,"implementation_est_bytes":400,"est_bytes":1400,"verdict":"fits"}'
  assert_eq "1" "$(payload_valid_rc "$json" aa bb)" "plan hash mismatch rejected"
  rm -rf "$SANDBOX"
}

test_forecast_payload_valid_rejects_est_inconsistency() {
  make_sandbox
  local json
  json='{"plan_sha256":"aa","spec_sha256":"bb","current_diff_bytes":1000,"files":[],"total_loc":0,"implementation_est_bytes":400,"est_bytes":9999,"verdict":"fits"}'
  assert_eq "1" "$(payload_valid_rc "$json" aa bb)" "est_bytes != current + impl rejected"
  rm -rf "$SANDBOX"
}
```

- [ ] **Step 2: Run the unit tests to verify they fail**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A2 forecast_payload_valid`
Expected: FAIL — `split_forecast` / `forecast_payload_valid` are undefined (jq/source errors, non-matching rc).

- [ ] **Step 3: Add env defaults to `scripts/lib/spec2pr-runtime.sh`**

In the `-- Config defaults --` block (after `SPEC2PR_MAX_DIFF`, near `:12`), add:

```bash
SPEC2PR_FORECAST="${SPEC2PR_FORECAST:-1}"
SPEC2PR_FORECAST_BYTES_PER_LINE="${SPEC2PR_FORECAST_BYTES_PER_LINE:-40}"
```

- [ ] **Step 4: Add `split_forecast` next to the other finish-helpers**

After `split()` (currently `:97-99`), add:

```bash
# Forecast early-stop: an ESTIMATE, not a measured size. Distinct token
# (`SPLIT forecast est=`) so split tooling never confuses it with a measured
# `SPLIT <gate> size=` gate.
split_forecast() {
  finish 2 "SPLIT forecast est=$1 limit=$2"
}
```

- [ ] **Step 5: Add the fail-soft wrapper and validator after the model-call layer**

After `run_claude_json()` (currently ends `:440`), add:

```bash
# forecast_claude_attempt <tag> <prompt-file> <out>
# Optional, read-only claude call for the forecast step. Reuses
# claude_json_attempt (claude invocation, worktree cleanup, envelope JSON
# check) but returns a status code instead of halting, and additionally
# enforces the read-only contract: the prompt edits nothing, yet claude runs
# with write permissions, so a HEAD change or any dirty/untracked file is a
# contract failure. Return codes: 0 ok; 2 claude process failure; 3 invalid
# envelope JSON; 4 worktree modified (cleaned back to the pre-call HEAD).
forecast_claude_attempt() {
  local tag="$1" prompt_file="$2" out="$3"
  local pre_head rc post_head
  pre_head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
  set +e
  claude_json_attempt "$tag" "$prompt_file" "$out"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  post_head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
  if [ "$post_head" != "$pre_head" ] \
      || [ -n "$(git -C "$WORKTREE" status --porcelain --untracked-files=all)" ]; then
    clean_worktree_to "$pre_head"
    return 4
  fi
  return 0
}

# forecast_payload_valid <forecast.json> <plan-sha> <spec-sha>
# Exit 0 iff <forecast.json> is a structurally valid forecast payload whose
# plan_sha256/spec_sha256 equal the shell-computed shas and whose
# est_bytes == current_diff_bytes + implementation_est_bytes. Used for both a
# freshly extracted payload and a cached one.
forecast_payload_valid() {
  local f="$1" plan_sha="$2" spec_sha="$3"
  jq -e --arg ps "$plan_sha" --arg ss "$spec_sha" '
    type == "object"
    and (.plan_sha256 | type == "string") and (.plan_sha256 == $ps)
    and (.spec_sha256 | type == "string") and (.spec_sha256 == $ss)
    and (.files | type == "array")
    and ([.files[] | (
      type == "object"
      and (.path | type == "string")
      and (.loc | type == "number" and . == floor and . >= 0)
    )] | all)
    and (.total_loc | type == "number" and . == floor and . >= 0)
    and (.implementation_est_bytes | type == "number" and . == floor and . >= 0)
    and (.current_diff_bytes | type == "number" and . == floor and . >= 0)
    and (.est_bytes | type == "number" and . == floor and . >= 0)
    and (.est_bytes == (.current_diff_bytes + .implementation_est_bytes))
    and (.verdict == "fits" or .verdict == "exceeds")
    and (if .verdict == "exceeds"
         then ((.summary | type == "string" and . != "")
               and (.parts | type == "array" and length > 0)
               and ([.parts[] | type == "string"] | all))
         else true end)
  ' "$f" > /dev/null 2>&1
}
```

- [ ] **Step 6: Run the unit tests to verify they pass**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -E 'split_forecast|forecast_payload_valid'`
Expected: PASS for all five `test_*` functions added in Step 1.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/spec2pr-runtime.sh tests/spec2pr/test-forecast.sh
git commit -m "feat(spec2pr): add forecast runtime helpers (split_forecast, fail-soft claude wrapper, payload validator)"
```

---

## Task 3: Wire the forecast step into spec2pr.sh

Insert the forecast call + decision at the fresh-implement boundary, with the kill-switch and fail-soft branches. No caching yet (Task 4). Update existing full-run tests to feed a forecast fixture.

**Files:**
- Modify: `scripts/spec2pr.sh` (define `forecast_before_implement` + `forecast_decide`; call them in the fresh-implement branch near `:514`)
- Modify: `tests/spec2pr/helpers.sh` (add `queue_clean_forecast`)
- Modify: existing `tests/spec2pr/test-*.sh` that reach a fresh implement (add forecast fixture; bump claude counts)
- Test: `tests/spec2pr/test-forecast.sh` (integration cases)

**Interfaces:**
- Consumes: `WORKTREE`, `BASE_SHA`, `WT_PLAN_REL`, `WT_SPEC_REL`, `META_DIR`, `SPEC2PR_MAX_DIFF`, `SPEC2PR_FORECAST`, `SPEC2PR_FORECAST_BYTES_PER_LINE`, `${IGNORE_PR_LIMIT:-}` (Task 1), and runtime helpers `sha256_of`, `forecast_claude_attempt`, `forecast_payload_valid`, `split_forecast`, `status` (Task 2).
- Produces: `$META_DIR/forecast.prompt`, `$META_DIR/forecast.claude.json` (raw claude envelope), `$META_DIR/forecast.json` (extracted+validated forecast payload). Shell helper `queue_clean_forecast <NN-name>` for tests.

- [ ] **Step 1: Add the `queue_clean_forecast` test helper to `tests/spec2pr/helpers.sh`**

Add at the end of the file (after `claude_calls`). The fixture runs with `cwd` = the worktree, so it computes the plan/spec hashes from the files themselves to match the shell:

```bash
# Queue a claude forecast fixture returning a "fits" verdict whose
# plan_sha256/spec_sha256 match the worktree's committed plan/spec files.
# (Test plan/spec paths are fixed by the toy fixture.)
queue_clean_forecast() {
  enqueue_claude "$1" <<'EOF'
plan_sha="$(sha256sum docs/superpowers/plans/toy-spec-plan.md | awk '{print $1}')"
spec_sha="$(sha256sum docs/superpowers/specs/toy-spec.md | awk '{print $1}')"
printf '{"result":{"plan_sha256":"%s","spec_sha256":"%s","current_diff_bytes":1000,"files":[{"path":"version.txt","loc":1}],"total_loc":1,"implementation_est_bytes":40,"est_bytes":1040,"verdict":"fits"}}' \
  "$plan_sha" "$spec_sha"
EOF
}

# Queue a claude forecast fixture returning an "exceeds" verdict with parts.
queue_exceeds_forecast() {
  enqueue_claude "$1" <<'EOF'
plan_sha="$(sha256sum docs/superpowers/plans/toy-spec-plan.md | awk '{print $1}')"
spec_sha="$(sha256sum docs/superpowers/specs/toy-spec.md | awk '{print $1}')"
printf '{"result":{"plan_sha256":"%s","spec_sha256":"%s","current_diff_bytes":110000,"files":[{"path":"big.ts","loc":1000}],"total_loc":1000,"implementation_est_bytes":40000,"est_bytes":150000,"verdict":"exceeds","summary":"Forecast exceeds diff limit. Recommended split: part-1 helpers; part-2 wiring + tests.","parts":["part-1: helpers + types","part-2: wiring + tests"]}}' \
  "$plan_sha" "$spec_sha"
EOF
}
```

- [ ] **Step 2: Write the failing integration tests (append to `tests/spec2pr/test-forecast.sh`)**

```bash
test_forecast_fits_proceeds_to_implement() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  queue_spec2pr_subject_implementation_commit 05-implement
  queue_clean_pr_review 06-pr-review
  run_spec2pr "$SPEC"

  assert_eq "0" "$RC" "forecast fits run reaches done"
  assert_contains "$OUT" "SPEC2PR OK forecast: fits est=1040 limit=131072" "fits status printed"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1" "fits run reaches done"
  assert_file_exists "$SPEC2PR_HOME/$ID/forecast.json" "forecast payload extracted"
  assert_file_exists "$SPEC2PR_HOME/$ID/forecast.claude.json" "raw claude envelope stored"
}

test_forecast_exceeds_splits_without_implement() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_exceeds_forecast 04-forecast
  # Implement fixture intentionally present but must NOT be consumed.
  queue_spec2pr_subject_implementation_commit 05-implement
  run_spec2pr "$SPEC"

  assert_eq "2" "$RC" "forecast exceeds exits 2 (split)"
  assert_contains "$OUT" "SPEC2PR SPLIT forecast est=150000 limit=131072" "forecast split token printed"
  assert_contains "$OUT" "Recommended split: part-1 helpers" "recommended split summary printed before split"
  assert_eq "2" "$(codex_calls)" "no implement codex call spent (only spec-review + plan-review)"
}

test_forecast_exceeds_overridden_by_ignore_pr_limit() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_exceeds_forecast 04-forecast
  queue_spec2pr_subject_implementation_commit 05-implement
  queue_clean_pr_review 06-pr-review
  run_spec2pr --ignore-pr-limit "$SPEC"

  assert_eq "0" "$RC" "ignore-pr-limit overrides forecast split"
  assert_contains "$OUT" "SPEC2PR OK forecast: est=150000 exceeds limit; overridden" "override status printed"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1" "override run reaches done"
}

test_forecast_claude_failure_warns_and_proceeds() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  enqueue_claude 04-forecast <<'EOF'
echo "boom" >&2
exit 7
EOF
  queue_spec2pr_subject_implementation_commit 05-implement
  queue_clean_pr_review 06-pr-review
  run_spec2pr "$SPEC"

  assert_eq "0" "$RC" "forecast claude failure does not block the run"
  assert_contains "$OUT" "SPEC2PR WARN forecast: claude failed; proceeding to implement" "process-failure warn"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1" "fail-soft run reaches done"
}

test_forecast_malformed_payload_warns_and_proceeds() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  enqueue_claude 04-forecast <<'EOF'
printf '{"result":{"verdict":"maybe"}}'
EOF
  queue_spec2pr_subject_implementation_commit 05-implement
  queue_clean_pr_review 06-pr-review
  run_spec2pr "$SPEC"

  assert_eq "0" "$RC" "malformed forecast payload does not block the run"
  assert_contains "$OUT" "SPEC2PR WARN forecast: malformed forecast JSON; proceeding to implement" "malformed warn"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1" "malformed fail-soft reaches done"
}

test_forecast_worktree_modification_is_cleaned_and_warns() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  enqueue_claude 04-forecast <<'EOF'
printf 'sneaky\n' > sneaky.txt
git add sneaky.txt
git commit -qm "forecast should not commit"
printf '{"result":{"verdict":"fits"}}'
EOF
  queue_spec2pr_subject_implementation_commit 05-implement
  queue_clean_pr_review 06-pr-review
  run_spec2pr "$SPEC"

  local wt="$SPEC2PR_WORKTREES/$ID"
  assert_eq "0" "$RC" "worktree-modifying forecast does not block the run"
  assert_contains "$OUT" "SPEC2PR WARN forecast: claude modified worktree; proceeding to implement" "worktree-modified warn"
  assert_not_contains "$(git -C "$wt" log --format=%s)" "forecast should not commit" "forecast commit was discarded"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1" "cleaned fail-soft reaches done"
}

test_forecast_kill_switch_skips_step() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  # No forecast fixture queued: the step must not call claude at all.
  queue_spec2pr_subject_implementation_commit 04-implement
  queue_clean_pr_review 05-pr-review
  SPEC2PR_FORECAST=0 run_spec2pr "$SPEC"

  assert_eq "0" "$RC" "kill-switch run reaches done"
  assert_not_contains "$OUT" "forecast" "no forecast status lines emitted"
  assert_file_absent "$SPEC2PR_HOME/$ID/forecast.json" "no forecast payload written"
}
```

Note `run_spec2pr` runs `bash "$SPEC2PR"` in a child process, so a leading `SPEC2PR_FORECAST=0` env assignment on the call line is inherited correctly.

- [ ] **Step 3: Run the new integration tests to verify they fail**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -E 'forecast_(fits|exceeds|claude_failure|malformed|worktree|kill)'`
Expected: FAIL — the forecast step is not wired in, so `04-forecast` fixtures are consumed by the wrong call (pr-review) and runs misbehave.

- [ ] **Step 4: Define the forecast functions in `scripts/spec2pr.sh`**

Add these two functions before the implement section (e.g. just after `implementation_ok_record()` near `:430`):

```bash
forecast_decide() {
  local f="$1" est
  est="$(jq -r '.est_bytes' "$f")"
  if [ "$est" -le "$SPEC2PR_MAX_DIFF" ]; then
    status "OK" "fits est=$est limit=$SPEC2PR_MAX_DIFF"
    return 0
  fi
  if [ -n "${IGNORE_PR_LIMIT:-}" ]; then
    status "OK" "est=$est exceeds limit; overridden"
    return 0
  fi
  # Print the recommended split summary unconditionally (NOT show_summary, which
  # is gated by SPEC2PR_VERBOSE) before split_forecast exits the process.
  jq -r '.summary // empty' "$f"
  split_forecast "$est" "$SPEC2PR_MAX_DIFF"
}

forecast_before_implement() {
  STAGE="forecast"
  local plan_sha spec_sha cur_bytes pf rc
  plan_sha="$(sha256_of "$WORKTREE/$WT_PLAN_REL")"
  spec_sha="$(sha256_of "$WORKTREE/$WT_SPEC_REL")"

  cur_bytes="$(git -C "$WORKTREE" diff "$BASE_SHA...HEAD" | wc -c | tr -d ' ')"
  pf="$META_DIR/forecast.prompt"
  cat > "$pf" <<EOF
Read the implementation plan at $WT_PLAN_REL and the spec at $WT_SPEC_REL in
this worktree. This is a READ-ONLY estimation task: do not edit, create, or
delete any file; do not run git; do not commit, push, or open a PR.

Estimate the size of the final pull-request diff this plan will produce:
1. List every implementation file you would create or modify, with a rough
   added/changed lines-of-code (loc) count for each.
2. Sum the loc into total_loc.
3. Multiply total_loc by $SPEC2PR_FORECAST_BYTES_PER_LINE bytes/line to get
   implementation_est_bytes.
4. Add the already-present diff bytes ($cur_bytes) to implementation_est_bytes
   to get est_bytes (the estimated final PR diff size in bytes).
5. Set verdict to "exceeds" if est_bytes > $SPEC2PR_MAX_DIFF, else "fits".
   When "exceeds", also include a non-empty "parts" array (sequential,
   independently implementable sub-plans) and a one-line "summary" recommending
   the split.

Return ONLY this JSON object as your result (no other prose):
{"plan_sha256":"$plan_sha","spec_sha256":"$spec_sha","current_diff_bytes":$cur_bytes,"files":[{"path":"...","loc":0}],"total_loc":0,"implementation_est_bytes":0,"est_bytes":0,"verdict":"fits"}
EOF

  set +e
  forecast_claude_attempt forecast "$pf" "$META_DIR/forecast.claude.json"
  rc=$?
  set -e
  case "$rc" in
    2) status "WARN" "claude failed; proceeding to implement"; return 0 ;;
    3) status "WARN" "invalid claude JSON; proceeding to implement"; return 0 ;;
    4) status "WARN" "claude modified worktree; proceeding to implement"; return 0 ;;
  esac

  if ! jq -e 'if (.result | type) == "object" then .result
              else (.result | tostring | fromjson?) end
              | select(type == "object")' \
      "$META_DIR/forecast.claude.json" > "$META_DIR/forecast.json" 2>/dev/null; then
    rm -f "$META_DIR/forecast.json"
    status "WARN" "malformed forecast JSON; proceeding to implement"
    return 0
  fi
  if ! forecast_payload_valid "$META_DIR/forecast.json" "$plan_sha" "$spec_sha"; then
    rm -f "$META_DIR/forecast.json"
    status "WARN" "malformed forecast JSON; proceeding to implement"
    return 0
  fi

  forecast_decide "$META_DIR/forecast.json"
}
```

- [ ] **Step 5: Call the forecast at the fresh-implement boundary in `scripts/spec2pr.sh`**

In the `elif [ "$ls_remote_rc" -eq 2 ]` branch, inside the `else` that runs a fresh implement (currently `:513-514`), insert the forecast call as the first statement, immediately before `before_impl_head=...`:

```bash
    else
      if [ "$SPEC2PR_FORECAST" != "0" ]; then
        forecast_before_implement
      fi
      before_impl_head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
      pf="$META_DIR/implement.prompt"
```

(This is after the open-PR check, the remote-branch check, and the `local_impl_head` reuse check — exactly the spec's "no valid local implementation, remote branch, or open PR to reuse" boundary. A resumed run with valid markers never reaches this `else`, so it spends no forecast call.)

- [ ] **Step 6: Run the new integration tests to verify they pass**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -E 'forecast_(fits|exceeds|claude_failure|malformed|worktree|kill)'`
Expected: PASS for all seven integration tests.

- [ ] **Step 7: Update existing full-run tests for the extra forecast call**

Every test that reaches a *fresh* implement now also makes one forecast claude call. Fix them:

Run the suite and inspect failures: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -E 'FAIL'`

For each failing test that runs a fresh implement (NOT the resume/skip tests, which never reach the forecast):
1. Insert `queue_clean_forecast NN-forecast` between the `queue_clean_plan_review` (or plan-review enqueue) and the implement enqueue, renumbering later fixtures if the test asserts specific `NN-` names.
2. Bump that test's `claude_calls` assertion by `+1`. Known sites (verify against current output):
   - `tests/spec2pr/test-pipeline.sh:39` — `"3"` → `"4"` (happy path: plan + forecast + review + classify)
   - `tests/spec2pr/test-pipeline.sh:101` — `"5"` → `"6"`
   - `tests/spec2pr/test-pipeline.sh:208` — `"4"` → `"5"`
   - `tests/spec2pr/test-pipeline.sh:230` — `"4"` → `"5"`
   - `tests/spec2pr/test-resume-recovery.sh:327` — `"3"` → `"4"`
3. Leave `codex_calls` assertions unchanged (forecast is a claude call). Resume tests whose `codex_calls` count proves implement was skipped (e.g. test-stages `:181,:342,:368,:404,:492`) need **no** forecast fixture and **no** count change — confirm they still pass.
4. Also enqueue `queue_clean_forecast` in `test_ignore_plan_limit_proceeds_past_plan_gate` (Task 1, Step 1) — already written to expect `04-forecast`; confirm it now passes.

Repeat until `bash tests/spec2pr/run-tests.sh` reports `0 failed`.

- [ ] **Step 8: Run the full suite — all green**

Run: `bash tests/spec2pr/run-tests.sh`
Expected: `N tests run, 0 failed`.

- [ ] **Step 9: Commit**

```bash
git add scripts/spec2pr.sh tests/spec2pr/helpers.sh tests/spec2pr/test-forecast.sh \
  tests/spec2pr/test-pipeline.sh tests/spec2pr/test-resume-recovery.sh tests/spec2pr/test-stages.sh
git commit -m "feat(spec2pr): forecast PR diff size before implement; early-split or fail-soft-continue"
```

---

## Task 4: Forecast resume/caching + start-from cleanup

Reuse a valid `forecast.json` on a re-run that reaches a fresh implement (skip the claude call), regenerate it when the plan/spec hash is stale, and remove forecast artifacts on the relevant `--start-from` rewinds.

**Files:**
- Modify: `scripts/spec2pr.sh` (cache check at the top of `forecast_before_implement`; forecast-artifact removal in the `--start-from` cleanup near `:249-261`)
- Test: `tests/spec2pr/test-forecast.sh`

**Interfaces:**
- Consumes: `forecast_payload_valid`, `sha256_of`, `$META_DIR/forecast.json` (Task 3).
- Produces: cache-reuse behavior (no new claude call when the cached payload's hashes still match); start-from cleanup of `forecast.json`, `forecast.claude.json`, `forecast.prompt`.

- [ ] **Step 1: Write the failing tests (append to `tests/spec2pr/test-forecast.sh`)**

```bash
test_forecast_cache_reused_when_hashes_match() {
  make_sandbox
  # First run: forecast fits, but implement is BLOCKED so no marker/PR is left
  # and a re-run will re-enter the fresh-implement path.
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  queue_blocked_implementation 05-implement
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "blocked implement halts first run"
  assert_file_exists "$SPEC2PR_HOME/$ID/forecast.json" "forecast cached after first run"
  local calls_before
  calls_before="$(claude_calls)"

  # Second run: plan/spec unchanged, so the cached forecast is reused with NO
  # new claude forecast call. No 06-forecast fixture is queued on purpose.
  queue_clean_spec_review 06-spec-review
  queue_clean_plan_review 07-plan-review
  queue_spec2pr_subject_implementation_commit 08-implement
  queue_clean_pr_review 09-pr-review
  run_spec2pr "$SPEC"

  assert_eq "0" "$RC" "cached-forecast resume reaches done"
  assert_contains "$OUT" "SPEC2PR OK forecast: fits est=1040 limit=131072" "cached forecast still decides fits"
  # Second run claude calls = pr-review review + classify only (plan exists, no
  # new forecast call). If the forecast had re-called claude it would consume
  # the pr-review fixtures and break.
  assert_eq "$((calls_before + 2))" "$(claude_calls)" "resume adds only the two pr-review claude calls"
}

test_forecast_stale_hash_regenerates() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  queue_blocked_implementation 05-implement
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "blocked implement halts first run"

  # Corrupt the cached plan hash so the cache is stale.
  local fj="$SPEC2PR_HOME/$ID/forecast.json"
  jq '.plan_sha256 = "deadbeef"' "$fj" > "$fj.tmp" && mv "$fj.tmp" "$fj"

  # Second run must DISCARD the stale cache and regenerate (06-forecast call).
  queue_clean_spec_review 06-spec-review
  queue_clean_plan_review 07-plan-review
  queue_clean_forecast 08-forecast
  queue_spec2pr_subject_implementation_commit 09-implement
  queue_clean_pr_review 10-pr-review
  run_spec2pr "$SPEC"

  assert_eq "0" "$RC" "stale-cache resume regenerates and reaches done"
  assert_contains "$OUT" "SPEC2PR OK forecast: fits est=1040 limit=131072" "regenerated forecast decides fits"
  assert_eq "deadbeef" "$(jq -r 'select(.==null) // empty' /dev/null; jq -r '.plan_sha256' "$fj" | grep -c deadbeef || true)" \
    "regenerated payload no longer carries the corrupted hash" 2>/dev/null || true
}

test_forecast_regenerated_mismatch_warns_and_proceeds() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  # Forecast returns hashes that will never match the worktree files.
  enqueue_claude 04-forecast <<'EOF'
printf '{"result":{"plan_sha256":"nope","spec_sha256":"nope","current_diff_bytes":1000,"files":[],"total_loc":0,"implementation_est_bytes":40,"est_bytes":1040,"verdict":"fits"}}'
EOF
  queue_spec2pr_subject_implementation_commit 05-implement
  queue_clean_pr_review 06-pr-review
  run_spec2pr "$SPEC"

  assert_eq "0" "$RC" "mismatched fresh forecast does not block run"
  assert_contains "$OUT" "SPEC2PR WARN forecast: malformed forecast JSON; proceeding to implement" "hash mismatch treated as malformed"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1" "mismatch fail-soft reaches done"
}

test_forecast_start_from_plan_review_clears_forecast_artifacts() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  queue_blocked_implementation 05-implement
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "blocked implement halts first run"
  assert_file_exists "$SPEC2PR_HOME/$ID/forecast.json" "forecast cached before restart"

  run_spec2pr --start-from plan-review "$SPEC"
  assert_file_absent "$SPEC2PR_HOME/$ID/forecast.json" "start-from plan-review removed forecast.json"
  assert_file_absent "$SPEC2PR_HOME/$ID/forecast.claude.json" "start-from plan-review removed raw envelope"
}
```

The third assertion in `test_forecast_stale_hash_regenerates` is awkward to express; simplify it to a direct check that the regenerated `forecast.json` validates against the *current* worktree hashes:

```bash
  local cur_plan_sha
  cur_plan_sha="$(sha256sum "$SPEC2PR_WORKTREES/$ID/docs/superpowers/plans/toy-spec-plan.md" | awk '{print $1}')"
  assert_eq "$cur_plan_sha" "$(jq -r '.plan_sha256' "$fj")" "regenerated payload carries the live plan hash"
```

Replace the awkward assertion line with the block above.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -E 'forecast_(cache|stale|regenerated_mismatch|start_from)'`
Expected: FAIL — no caching yet (the cache-reuse test makes an extra claude call; the start-from test still finds `forecast.json`).

- [ ] **Step 3: Add the cache check to `forecast_before_implement` in `scripts/spec2pr.sh`**

Insert, right after the `plan_sha`/`spec_sha` are computed and before `cur_bytes=...`:

```bash
  # Resume/cache: reuse a forecast whose plan AND spec hashes still match the
  # current artifacts; otherwise discard and regenerate so a re-reviewed plan
  # never decides on stale size data.
  if [ -f "$META_DIR/forecast.json" ] \
      && forecast_payload_valid "$META_DIR/forecast.json" "$plan_sha" "$spec_sha"; then
    forecast_decide "$META_DIR/forecast.json"
    return 0
  fi
  rm -f "$META_DIR/forecast.json" "$META_DIR/forecast.claude.json"
```

So the function body order becomes: compute hashes → cache check (above) → measure `cur_bytes` → write prompt → call → fail-soft branches → extract → validate → `forecast_decide`. (A regenerated payload with mismatched hashes fails `forecast_payload_valid` in the validate step and is handled as malformed → WARN + proceed, per Task 3.)

- [ ] **Step 4: Add forecast-artifact cleanup to the `--start-from` rewind in `scripts/spec2pr.sh`**

After the existing `case "$START_FROM" in ... esac` cleanup block (currently `:249-261`), add a second case that clears forecast artifacts for the rewinds that invalidate the plan/spec, while `implementation` keeps them:

```bash
  case "$START_FROM" in
    spec-review|plan|plan-review)
      rm -f "$META_DIR/forecast.json" \
        "$META_DIR/forecast.claude.json" \
        "$META_DIR/forecast.prompt"
      ;;
  esac
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -E 'forecast_(cache|stale|regenerated_mismatch|start_from)'`
Expected: PASS.

- [ ] **Step 6: Run the full suite**

Run: `bash tests/spec2pr/run-tests.sh`
Expected: `N tests run, 0 failed`.

- [ ] **Step 7: Commit**

```bash
git add scripts/spec2pr.sh tests/spec2pr/test-forecast.sh
git commit -m "feat(spec2pr): cache forecast by plan/spec hash and clear it on start-from rewind"
```

---

## Task 5: Split-tooling compatibility for `SPLIT forecast`

Teach the manual split-recovery tooling to treat `SPLIT forecast est=<n> limit=<n>` as a first-class split event whose recommended parts come from the forecast summary.

**Files:**
- Modify: `scripts/spec2pr-split-context.sh` (gate regex near `:33`)
- Modify: `commands/rulez/spec2pr-split.md` (gate validation in step 1; handling in step 5)
- Test: `tests/spec2pr/test-spec2pr-split-context.sh` (add forecast fixture)

**Interfaces:**
- Consumes: a pasted blob containing `SPEC2PR SPLIT forecast est=<n> limit=<n>` and a spec path.
- Produces: `gate=forecast` on stdout from the context helper.

- [ ] **Step 1: Write the failing test (append to `tests/spec2pr/test-spec2pr-split-context.sh`)**

```bash
test_context_extracts_forecast_gate_from_messy_paste() {
  make_sandbox
  printf '# Import design\n' > "$PROJECT/docs/superpowers/specs/import-design.md"
  write_blob <<'EOF'
spec docs/superpowers/specs/import-design.md
forecast says this is too big before implement
SPEC2PR SPLIT forecast est=150000 limit=131072
EOF
  run_split_context "$SANDBOX/blob.txt"

  assert_eq "0" "$RC" "forecast gate parse exits 0"
  assert_contains "$OUT" "gate=forecast" "gate extracted as forecast"
  assert_eq "" "$ERR" "valid forecast blob keeps stderr empty"
  rm -rf "$SANDBOX"
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A2 forecast_gate`
Expected: FAIL — the gate regex matches only `spec|plan|diff`, so it warns and defaults `gate=spec`.

- [ ] **Step 3: Extend the gate regex in `scripts/spec2pr-split-context.sh`**

Replace (currently `:33`):

```bash
gate="$(grep -oE 'SPLIT[[:space:]]+(spec|plan|diff)' <<<"$content" | head -n1 | awk '{print $2}' || true)"
```

with:

```bash
gate="$(grep -oE 'SPLIT[[:space:]]+(spec|plan|diff|forecast)' <<<"$content" | head -n1 | awk '{print $2}' || true)"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A2 forecast_gate`
Expected: PASS.

- [ ] **Step 5: Update `commands/rulez/spec2pr-split.md`**

Three edits, matching the spec:

1. In step 1, the gate validation line currently reads:
   `After parsing` `gate`, validate that it is exactly one of `spec`, `plan`, or `diff`.
   Change it to include `forecast`:
   > After parsing `gate`, validate that it is exactly one of `spec`, `plan`, `diff`, or `forecast`.

2. In step 1, where it extracts `SPLIT ... size=N limit=M`, note that a forecast split uses `est=N limit=M` instead of `size=N limit=M`; extract `est` as the size figure when the gate is `forecast`.

3. In step 5 (manual next steps), add a `forecast` branch alongside `gate=spec`/`gate=plan` (a forecast split stops *before* implement, so there is no PR/branch/worktree from an implement to clean up):
   > - If `gate=forecast`:
   >   - State that there is no PR to clean up (the forecast stopped the run before implement).
   >   - Note that the recommended split parts come from the forecast `summary`/`parts`, not from a measured `size=<n>` payload; prefer them as the brainstorming seed.
   >   - Tell the operator to surface any stale local worktree or metadata identifier/path from the original run evidence if available; otherwise state that it was not parsed and cleanup must be found manually.
   >   - Keep all cleanup commands print-only and manual; do not execute them here.

- [ ] **Step 6: Run the full suite**

Run: `bash tests/spec2pr/run-tests.sh`
Expected: `N tests run, 0 failed`.

- [ ] **Step 7: Commit**

```bash
git add scripts/spec2pr-split-context.sh commands/rulez/spec2pr-split.md \
  tests/spec2pr/test-spec2pr-split-context.sh
git commit -m "feat(spec2pr): treat SPLIT forecast as a first-class split gate in manual split tooling"
```

---

## Task 6: Versioning + command docs

Bump the version, add the upgrade note, and document the new flags + forecast behavior in the spec2pr command doc.

**Files:**
- Modify: `VERSION`
- Modify: `UPGRADE.md` (new top section)
- Modify: `commands/rulez/spec2pr.md`

**Interfaces:** none (docs + version metadata only).

- [ ] **Step 1: Bump `VERSION`**

Replace the contents of `VERSION` (currently `1.7.1`) with:

```
1.8.0
```

- [ ] **Step 2: Add the new top section to `UPGRADE.md`**

Insert immediately after the header block (before `## To v1.7.1 - from v1.7.0`):

```markdown
## To v1.8.0 - from v1.7.1

**Action:** None.

**Caveat:** spec2pr now spends one extra claude call per run, after
plan-review, to forecast the final PR diff size. If the forecast
exceeds the diff limit it stops early (SPEC2PR SPLIT forecast) and prints a
recommended split instead of running implement. New flags --ignore-plan-limit
and --ignore-pr-limit force a run past the respective size limit;
--ignore-pr-limit also applies to review-pr. Set SPEC2PR_FORECAST=0 to disable
the forecast step.
```

- [ ] **Step 3: Document the flags + forecast in `commands/rulez/spec2pr.md`**

In the `## Usage` list, add a flags line; and extend the outcome-reaction list to cover the forecast split. Add after the `## Usage` block:

```markdown
- `/rulez:spec2pr --ignore-plan-limit <spec-path>` — proceed even if the plan
  file exceeds the size limit
- `/rulez:spec2pr --ignore-pr-limit <spec-path>` — proceed even if the
  forecast (or the final diff) exceeds the PR diff limit
```

And in the "When the background task completes" reaction list, add a bullet for the forecast split (the recommended parts are printed before the split line):

```markdown
- `SPLIT forecast est=<n> limit=<n>` — the pre-implement forecast predicts the
  PR diff will exceed the limit; no implement call was spent. Recommended split
  parts are printed just above the SPLIT line. Run `/rulez:spec2pr-split` with
  the output, or re-run with `--ignore-pr-limit` to force the run through.
```

Also note `SPEC2PR_FORECAST=0` disables the forecast step (one line near the flags).

- [ ] **Step 4: Verify version/docs consistency**

Run: `cat VERSION && head -20 UPGRADE.md`
Expected: `VERSION` shows `1.8.0`; `UPGRADE.md` top section is `## To v1.8.0 - from v1.7.1`.

- [ ] **Step 5: Run the full suite one final time**

Run: `bash tests/spec2pr/run-tests.sh`
Expected: `N tests run, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add VERSION UPGRADE.md commands/rulez/spec2pr.md
git commit -m "docs(spec2pr): bump to v1.8.0; document forecast + override flags"
```

---

## Notes / deferrals

- [PUNT]: The spec's Files list names `commands/rulez/review-pr.md`, but no such command doc exists in the repo (`review-pr.sh` is invoked directly, with no `/rulez:review-pr` wrapper). This plan documents `--ignore-pr-limit` only in `commands/rulez/spec2pr.md`. If a review-pr command doc is later added, mirror the flag note there.

## Self-Review

Spec coverage check against the design sections:

- §1 new `forecast` step at the fresh-implement boundary, not a `--start-from` target, planner untouched, `SPEC2PR_FORECAST=0` kill-switch → Task 3 (Steps 4-5), Task 2 (default).
- §2 forecast call via fail-soft wrapper around `claude_json_attempt`, read-only contract (HEAD + clean worktree), current-diff-bytes measurement, prompt, raw envelope vs extracted payload, hashes, bytes-per-line constant, payload validation incl. `est_bytes == current + impl` and hash equality → Task 2 (`forecast_claude_attempt`, `forecast_payload_valid`), Task 3 (prompt, extraction).
- §3 decision + early stop (`fits` / `exceeds` split via `split_forecast` with unconditional summary print / `exceeds` overridden) → Task 2 (`split_forecast`), Task 3 (`forecast_decide`).
- §4 override flags (`--ignore-plan-limit`, `--ignore-pr-limit`) + gate guards + override status lines → Task 1 (plan + diff gates), Task 3 (forecast override).
- §5 split-tooling compatibility (`spec2pr-split-context.sh`, `spec2pr-split.md`, test fixture) → Task 5.
- §6 resume/caching + start-from cleanup → Task 4.
- §7 fail-soft error handling (rc 2/3/4 + malformed payload) → Task 2 (return codes), Task 3 (WARN branches).
- §8 status/contract surface → covered across Tasks 1, 3 (exact lines in Global Constraints).
- Testing list → Task 2 (unit), Tasks 3-4 (integration), Task 5 (split-context fixture).
- Versioning → Task 6.

Type/name consistency: `IGNORE_PLAN_LIMIT`/`IGNORE_PR_LIMIT`, `SPEC2PR_FORECAST`, `SPEC2PR_FORECAST_BYTES_PER_LINE`, `split_forecast`, `forecast_claude_attempt`, `forecast_payload_valid`, `forecast_before_implement`, `forecast_decide`, `queue_clean_forecast`, `queue_exceeds_forecast` are used identically across all tasks. The forecast payload fields match the spec's JSON example exactly.
