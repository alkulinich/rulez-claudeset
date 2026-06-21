# spec2pr Codex Fast Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `--fast` flag that spends Codex Fast mode credits only on `spec2pr` implementation and PR-fix Codex calls.

**Architecture:** Keep the behavior centralized in `scripts/lib/spec2pr-runtime.sh`, where all Codex calls already pass through `codex_call()`. Script parsers set `SPEC2PR_CODEX_FAST=1`; `codex_call()` decides whether the current role (`implement` or `pr-fix`) receives `--enable fast_mode -c 'service_tier="fast"'`. `mctl` persists and forwards `--fast` the same way it already persists and forwards non-default `--reviewer`.

**Tech Stack:** Bash, git, tmux/script stubs, existing shell test harnesses in `tests/spec2pr` and `tests/mctl`, Codex CLI `exec` config overrides.

---

## File Structure

- `scripts/lib/spec2pr-runtime.sh` owns the shared Codex invocation policy. It is the only place that decides whether a Codex role receives Fast mode arguments.
- `scripts/spec2pr.sh` owns direct `spec2pr` CLI parsing and sets the shared fast-mode variable when `--fast` is present.
- `scripts/review-pr.sh` owns direct `review-pr` CLI parsing and sets the same shared fast-mode variable while preserving `--reviewer`.
- `scripts/mctl.sh` owns detached-run metadata and runner command reconstruction. It persists `fast=1` and forwards `--fast` to the underlying script.
- `tests/spec2pr/stub-codex.sh` records Codex invocation arguments so role-gated fast-mode behavior can be asserted.
- `tests/spec2pr/test-stages.sh`, `tests/spec2pr/test-review-pr.sh`, and `tests/spec2pr/test-harness.sh` cover direct script behavior and Codex argument logging.
- `tests/mctl/test-add.sh` covers `mctl add` metadata and forwarded command construction.
- `README.md` documents direct and `mctl` fast-mode usage.

### Task 1: Record Codex Invocation Arguments In Tests

**Files:**
- Modify: `tests/spec2pr/stub-codex.sh`
- Test: `tests/spec2pr/test-harness.sh`

- [ ] **Step 1: Add a failing harness assertion for raw Codex args**

In `tests/spec2pr/test-harness.sh`, update `test_stub_codex_consumes_fixture_queue()` to assert that the invocation log records the raw arguments before parsing. Replace the final invocation-log assertion block with:

```bash
  local invocation_log
  invocation_log="$(cat "$SPEC2PR_TEST_FIXTURES/invocations.log")"
  assert_contains "$invocation_log" "schema=review.json" "invocation logged"
  assert_contains "$invocation_log" "args=exec --cd $PROJECT --output-schema" "raw codex args are logged"
```

- [ ] **Step 2: Run the harness test and verify it fails**

Run:

```bash
bash tests/spec2pr/run-tests.sh
```

Expected: FAIL in `test_stub_codex_consumes_fixture_queue` because `stub-codex.sh` does not yet log `args=...`.

- [ ] **Step 3: Extend the Codex stub log**

In `tests/spec2pr/stub-codex.sh`, capture raw args before the parser:

```bash
raw_args="$*"
```

Then replace the existing log line:

```bash
printf 'CALL cd=%s schema=%s fixture=%s\n' \
  "$cd_dir" "$(basename "$schema")" "$(basename "$fixture")" >> "$queue/invocations.log"
```

with:

```bash
printf 'CALL cd=%s schema=%s fixture=%s args=%s\n' \
  "$cd_dir" "$(basename "$schema")" "$(basename "$fixture")" "$raw_args" >> "$queue/invocations.log"
```

- [ ] **Step 4: Run tests and verify the harness passes**

Run:

```bash
bash tests/spec2pr/run-tests.sh
```

Expected: all existing `tests/spec2pr` tests pass.

- [ ] **Step 5: Commit**

```bash
git add tests/spec2pr/stub-codex.sh tests/spec2pr/test-harness.sh
git commit -m "test: log codex invocation arguments"
```

### Task 2: Add Runtime Fast-Role Tests And Implementation

**Files:**
- Modify: `scripts/lib/spec2pr-runtime.sh`
- Modify: `tests/spec2pr/test-stages.sh`
- Modify: `tests/spec2pr/test-review-pr.sh`

- [ ] **Step 1: Add a failing spec2pr fast implementation test**

Append this helper to `tests/spec2pr/test-stages.sh` near the other stage tests:

```bash
test_fast_mode_only_marks_implementation_codex_call() {
  make_sandbox
  queue_clean_review spec-review-r1
  queue_plan_success
  queue_clean_review plan-review-r1
  queue_spec2pr_subject_implementation_commit 04-implement
  queue_clean_pr_review 05-pr-review

  run_spec2pr --fast "$SPEC"

  local invocations
  invocations="$(cat "$SPEC2PR_TEST_FIXTURES/invocations.log")"

  assert_eq "0" "$RC" "fast spec2pr exits 0"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1" "fast spec2pr reaches done"
  assert_contains "$invocations" "schema=implement.json" "implementation call was made"
  assert_contains "$invocations" "schema=implement.json fixture=04-implement.sh args=exec --enable fast_mode -c service_tier=\"fast\"" "implementation call uses fast mode"
  assert_not_contains "$invocations" "schema=review.json fixture=01-spec-review-r1.sh args=exec --enable fast_mode" "spec review call is not fast"
  assert_not_contains "$invocations" "schema=review.json fixture=03-plan-review-r1.sh args=exec --enable fast_mode" "plan review call is not fast"
}
```

- [ ] **Step 2: Add a failing review-pr fast fixer test**

Append this test to `tests/spec2pr/test-review-pr.sh`:

```bash
test_review_pr_fast_marks_codex_fixer_only() {
  make_pr_sandbox
  queue_dirty_pr_review 01-pr
  queue_clean_pr_review 02-pr

  run_review_pr --fast "$PR_NUMBER"

  local invocations
  invocations="$(cat "$SPEC2PR_TEST_FIXTURES/invocations.log")"

  assert_eq "0" "$RC" "fast review-pr dirty then clean exits 0"
  assert_contains "$OUT" "PRREVIEW DONE pr=$PR_URL_VAL" "fast review-pr reaches done"
  assert_contains "$invocations" "schema=pr-fix.json" "codex fixer call was made"
  assert_contains "$invocations" "schema=pr-fix.json fixture=01-pr-fix.sh args=exec --enable fast_mode -c service_tier=\"fast\"" "codex fixer uses fast mode"
}
```

- [ ] **Step 3: Add a failing review-pr codex-reviewer exclusion test**

Append this test to `tests/spec2pr/test-review-pr.sh`:

```bash
test_review_pr_fast_does_not_mark_codex_reviewer_when_fixer_is_claude() {
  make_pr_sandbox
  queue_dirty_codex_pr_review 01-pr
  queue_claude_pr_fix 01-pr
  queue_clean_codex_pr_review 02-pr

  run_review_pr --fast --reviewer codex "$PR_NUMBER"

  local invocations
  invocations="$(cat "$SPEC2PR_TEST_FIXTURES/invocations.log")"

  assert_eq "0" "$RC" "fast codex-reviewer run exits 0"
  assert_contains "$OUT" "PRREVIEW DONE pr=$PR_URL_VAL" "fast codex-reviewer run reaches done"
  assert_contains "$invocations" "schema=review.json" "codex reviewer call was made"
  assert_not_contains "$invocations" "--enable fast_mode" "codex reviewer is not fast when fixer is claude"
}
```

- [ ] **Step 4: Run tests and verify the new runtime tests fail**

Run:

```bash
bash tests/spec2pr/run-tests.sh
```

Expected: the new fast-mode assertions fail because `--fast` is not parsed and runtime fast args are not added yet.

- [ ] **Step 5: Add the runtime fast-role helper**

In `scripts/lib/spec2pr-runtime.sh`, add this default near the existing config defaults:

```bash
SPEC2PR_CODEX_FAST="${SPEC2PR_CODEX_FAST:-}"
```

Add this helper immediately before `codex_call()`:

```bash
codex_fast_enabled_for_role() {
  local role="$1"
  [ -n "$SPEC2PR_CODEX_FAST" ] || return 1
  case "$role" in
    implement|pr-fix) return 0 ;;
    *) return 1 ;;
  esac
}
```

- [ ] **Step 6: Thread fast args through `codex_call()`**

Replace the start of `codex_call()` with:

```bash
codex_call() {
  local role="$1" tag="$2" prompt_file="$3"
  local last="$META_DIR/$tag.json"
  local err="$META_DIR/$tag.stderr"
  local codex_args=()
  local progress_suffix=""

  if codex_fast_enabled_for_role "$role"; then
    codex_args+=(--enable fast_mode -c 'service_tier="fast"')
    progress_suffix=" fast"
  fi

  progress "running codex $tag$progress_suffix"
  if ! "$SPEC2PR_CODEX_BIN" exec "${codex_args[@]}" --cd "$WORKTREE" \
      --output-schema "$TMP_DIR/$role.json" \
      --output-last-message "$last" \
      < "$prompt_file" > "$META_DIR/$tag.stdout" 2> "$err"; then
    halt "codex $tag failed (stderr: $err)"
  fi
  jq -e . "$last" > /dev/null 2>&1 || halt "codex $tag returned invalid JSON ($last)"
  validate_codex_output "$role" "$tag" "$last"
}
```

Keep the rest of `validate_codex_output()` unchanged.

- [ ] **Step 7: Run tests and verify runtime is ready for parser work**

Run:

```bash
bash tests/spec2pr/run-tests.sh
```

Expected: tests may still fail on `--fast` usage because the scripts do not parse the flag yet, but no syntax errors or runtime helper errors should appear.

- [ ] **Step 8: Commit runtime and failing tests if they are isolated**

If the only failures are the expected parser failures, commit the test/runtime checkpoint:

```bash
git add scripts/lib/spec2pr-runtime.sh tests/spec2pr/test-stages.sh tests/spec2pr/test-review-pr.sh
git commit -m "test: cover codex fast roles"
```

If the test suite has unrelated or syntax failures, fix those before committing.

### Task 3: Add Direct Script `--fast` Parsers

**Files:**
- Modify: `scripts/spec2pr.sh`
- Modify: `scripts/review-pr.sh`
- Test: `tests/spec2pr/test-stages.sh`
- Test: `tests/spec2pr/test-review-pr.sh`

- [ ] **Step 1: Add a failing spec2pr suffix flag test**

Append this test to `tests/spec2pr/test-stages.sh`:

```bash
test_fast_mode_flag_is_accepted_after_spec_path() {
  make_sandbox
  queue_clean_review spec-review-r1
  queue_plan_success
  queue_clean_review plan-review-r1
  queue_spec2pr_subject_implementation_commit 04-implement
  queue_clean_pr_review 05-pr-review

  run_spec2pr "$SPEC" --fast

  local invocations
  invocations="$(cat "$SPEC2PR_TEST_FIXTURES/invocations.log")"

  assert_eq "0" "$RC" "spec2pr accepts --fast after spec path"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1" "suffix fast run reaches done"
  assert_contains "$invocations" "schema=implement.json fixture=04-implement.sh args=exec --enable fast_mode -c service_tier=\"fast\"" "suffix fast implementation uses fast mode"
}
```

- [ ] **Step 2: Add a failing default no-fast regression**

Append this test to `tests/spec2pr/test-stages.sh`:

```bash
test_default_spec2pr_does_not_use_fast_mode() {
  make_sandbox
  queue_clean_review spec-review-r1
  queue_plan_success
  queue_clean_review plan-review-r1
  queue_spec2pr_subject_implementation_commit 04-implement
  queue_clean_pr_review 05-pr-review

  run_spec2pr "$SPEC"

  local invocations
  invocations="$(cat "$SPEC2PR_TEST_FIXTURES/invocations.log")"

  assert_eq "0" "$RC" "default spec2pr exits 0"
  assert_not_contains "$invocations" "--enable fast_mode" "default spec2pr has no fast mode args"
}
```

- [ ] **Step 3: Add a failing review-pr parser order test**

Append this test to `tests/spec2pr/test-review-pr.sh`:

```bash
test_review_pr_fast_flag_is_accepted_after_pr_ref() {
  make_pr_sandbox
  queue_dirty_pr_review 01-pr
  queue_clean_pr_review 02-pr

  run_review_pr "$PR_NUMBER" --fast

  local invocations
  invocations="$(cat "$SPEC2PR_TEST_FIXTURES/invocations.log")"

  assert_eq "0" "$RC" "review-pr accepts --fast after PR ref"
  assert_contains "$OUT" "PRREVIEW DONE pr=$PR_URL_VAL" "review-pr suffix fast reaches done"
  assert_contains "$invocations" "schema=pr-fix.json fixture=01-pr-fix.sh args=exec --enable fast_mode -c service_tier=\"fast\"" "suffix fast review-pr fixer uses fast mode"
}
```

- [ ] **Step 4: Run tests and verify parser tests fail**

Run:

```bash
bash tests/spec2pr/run-tests.sh
```

Expected: `--fast` parser tests fail with usage errors.

- [ ] **Step 5: Implement `spec2pr.sh` parsing**

At the top of `scripts/spec2pr.sh`, replace:

```bash
[ "$#" -eq 1 ] || halt "usage: spec2pr.sh <spec-path>"

SPEC_INPUT="$1"
```

with:

```bash
usage() {
  halt "usage: spec2pr.sh [--fast] <spec-path>"
}

SPEC_INPUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --fast)
      SPEC2PR_CODEX_FAST=1
      shift
      ;;
    --*)
      usage
      ;;
    *)
      [ -z "$SPEC_INPUT" ] || usage
      SPEC_INPUT="$1"
      shift
      ;;
  esac
done

[ -n "$SPEC_INPUT" ] || usage
```

- [ ] **Step 6: Implement `review-pr.sh` parsing**

In `scripts/review-pr.sh`, update `usage()` to:

```bash
usage() {
  halt "usage: review-pr.sh [--fast] [--reviewer <claude|codex>] <pr-number|pr-url>"
}
```

Then add a `--fast` case to the existing parse loop before `--reviewer`:

```bash
    --fast)
      SPEC2PR_CODEX_FAST=1
      shift
      ;;
```

Keep the existing `--reviewer` cases and validation unchanged.

- [ ] **Step 7: Run tests and verify direct scripts pass**

Run:

```bash
bash tests/spec2pr/run-tests.sh
```

Expected: all `tests/spec2pr` tests pass.

- [ ] **Step 8: Commit parser work**

```bash
git add scripts/spec2pr.sh scripts/review-pr.sh tests/spec2pr/test-stages.sh tests/spec2pr/test-review-pr.sh
git commit -m "feat: add fast flag to spec2pr scripts"
```

### Task 4: Add `mctl --fast` Forwarding

**Files:**
- Modify: `scripts/mctl.sh`
- Modify: `tests/mctl/test-add.sh`

- [ ] **Step 1: Add failing mctl spec2pr fast test**

Append this test to `tests/mctl/test-add.sh`:

```bash
test_add_spec2pr_with_fast_persists_and_forwards_flag() {
  make_sandbox
  run_mctl add --fast spec2pr "$SPEC"

  local run_dir="$RULEZ_CLAUDESET_HOME/mctl/repo-foo-bar"
  local log
  log="$(cat "$SANDBOX/tmux.log")"

  assert_eq "0" "$RC" "add --fast spec2pr exits 0"
  assert_eq "1" "$(meta_value "$run_dir/meta" fast)" "fast persisted in meta"
  assert_contains "$log" "$REPO_ROOT/scripts/spec2pr.sh" "runner uses spec2pr script"
  assert_contains "$log" "--fast" "runner forwards fast flag"
  assert_contains "$log" "$SPEC" "runner forwards spec path"
}
```

- [ ] **Step 2: Add failing mctl review-pr fast test**

Append this test to `tests/mctl/test-add.sh`:

```bash
test_add_review_pr_with_fast_and_reviewer_persists_and_forwards_flags() {
  make_sandbox
  run_mctl_in_dir "$REPO" add --fast review-pr 7 --reviewer codex

  local run_dir="$RULEZ_CLAUDESET_HOME/mctl/repo-pr-7"
  local log
  log="$(cat "$SANDBOX/tmux.log")"

  assert_eq "0" "$RC" "add --fast review-pr with reviewer exits 0"
  assert_eq "1" "$(meta_value "$run_dir/meta" fast)" "fast persisted in review-pr meta"
  assert_eq "codex" "$(meta_value "$run_dir/meta" reviewer)" "reviewer still persisted"
  assert_contains "$log" "$REPO_ROOT/scripts/review-pr.sh" "runner uses review-pr script"
  assert_contains "$log" "--fast" "runner forwards fast flag"
  assert_contains "$log" "--reviewer" "runner still forwards reviewer flag"
  assert_contains "$log" "'codex'" "runner forwards reviewer value"
  assert_contains "$log" "'7'" "runner forwards PR number"
}
```

- [ ] **Step 3: Add failing default mctl regression**

Append this test to `tests/mctl/test-add.sh`:

```bash
test_add_default_runs_do_not_write_or_forward_fast() {
  make_sandbox
  run_mctl add spec2pr "$SPEC"

  local run_dir="$RULEZ_CLAUDESET_HOME/mctl/repo-foo-bar"
  local log
  log="$(cat "$SANDBOX/tmux.log")"

  assert_eq "0" "$RC" "default add spec2pr exits 0"
  assert_eq "" "$(meta_value "$run_dir/meta" fast)" "default fast omitted from meta"
  assert_not_contains "$log" "--fast" "default runner does not forward fast"
}
```

- [ ] **Step 4: Run mctl tests and verify failures**

Run:

```bash
bash tests/mctl/run-tests.sh
```

Expected: new `--fast` tests fail because `mctl add` does not parse or persist fast yet.

- [ ] **Step 5: Update mctl usage**

In `scripts/mctl.sh`, update `add_usage()` to:

```bash
add_usage() {
  die "usage: mctl add [--fast] spec2pr <spec.md> | mctl add [--fast] review-pr <pr#> [--reviewer <claude|codex>]"
}
```

- [ ] **Step 6: Persist fast in metadata**

Change `write_meta()` signature from:

```bash
write_meta() {
  local run_dir="$1" kind="$2" token="$3" session="$4" repo="$5" started="$6" spec_home="$7" wt_home="$8" target="$9" reviewer="${10:-}"
```

to:

```bash
write_meta() {
  local run_dir="$1" kind="$2" token="$3" session="$4" repo="$5" started="$6" spec_home="$7" wt_home="$8" target="$9" reviewer="${10:-}" fast="${11:-}"
```

After the reviewer block, add:

```bash
  if [ -n "$fast" ]; then
    printf 'fast=%s\n' "$fast" >> "$run_dir/meta"
  fi
```

- [ ] **Step 7: Forward fast from metadata**

In `build_inner_runner_command()`, add `fast` to locals:

```bash
local kind repo target spec_home wt_home reviewer fast runner exit_path runner_args
```

Read it:

```bash
fast="$(meta_get "$meta" fast)"
```

After `runner_args="$(shell_quote "$target")"`, add:

```bash
if [ -n "$fast" ]; then
  runner_args="--fast $runner_args"
fi
```

Leave the existing reviewer forwarding after this block so review-pr commands become:

```text
--reviewer 'codex' --fast '7'
```

or, if preferred, place fast after reviewer. The direct parser accepts either order. Update tests to match the chosen order.

- [ ] **Step 8: Parse fast in `cmd_add()`**

In `cmd_add()`, change the initial argument requirement to:

```bash
[ "$#" -ge 2 ] || add_usage
```

Then replace the current fixed `kind="$1" arg="$2"; shift 2` setup with a parser that accepts `--fast` before the kind:

```bash
local fast=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --fast)
      fast=1
      shift
      ;;
    *)
      break
      ;;
  esac
done

[ "$#" -ge 2 ] || add_usage
local kind="$1" arg="$2" reviewer="" repo target repo_slug name token session run_dir started
shift 2
```

In the existing post-target option loop, add another `--fast` case:

```bash
      --fast)
        fast=1
        shift
        ;;
```

This allows both `mctl add --fast spec2pr <spec>` and `mctl add spec2pr <spec> --fast`.

Finally, update the `write_meta` call:

```bash
  write_meta "$run_dir" "$kind" "$token" "$session" "$repo" "$started" \
    "$(effective_spec2pr_home)" "$(effective_spec2pr_worktrees)" "$target" "$reviewer" "$fast"
```

- [ ] **Step 9: Run mctl tests and verify pass**

Run:

```bash
bash tests/mctl/run-tests.sh
```

Expected: all `tests/mctl` tests pass.

- [ ] **Step 10: Commit mctl work**

```bash
git add scripts/mctl.sh tests/mctl/test-add.sh
git commit -m "feat: forward fast mode through mctl"
```

### Task 5: Documentation And Final Verification

**Files:**
- Modify: `README.md`
- Verify: `scripts/lib/spec2pr-runtime.sh`
- Verify: `scripts/spec2pr.sh`
- Verify: `scripts/review-pr.sh`
- Verify: `scripts/mctl.sh`
- Verify: `tests/spec2pr/stub-codex.sh`
- Verify: `tests/spec2pr/test-harness.sh`
- Verify: `tests/spec2pr/test-stages.sh`
- Verify: `tests/spec2pr/test-review-pr.sh`
- Verify: `tests/mctl/test-add.sh`

- [ ] **Step 1: Update README fast-mode docs**

In `README.md`, under `## spec2pr & review-pr`, add this subsection after the direct script descriptions and before the `mctl mission control` subsection:

````markdown
### Codex fast mode

Use `--fast` to spend Codex Fast mode credits on code-changing Codex calls:

```bash
scripts/spec2pr.sh --fast docs/superpowers/specs/feature-a.md
scripts/review-pr.sh --fast 7
mctl add --fast spec2pr docs/superpowers/specs/feature-a.md
mctl add --fast review-pr 7
```

Fast mode applies only to Codex implementation and PR-fix calls. Review,
planning, classification, and all Claude calls stay on their normal settings.
Codex Fast mode depends on Codex account support and may not apply when Codex is
authenticated with an API key instead of ChatGPT.
````

- [ ] **Step 2: Run spec2pr tests**

Run:

```bash
bash tests/spec2pr/run-tests.sh
```

Expected: all `tests/spec2pr` tests pass.

- [ ] **Step 3: Run mctl tests**

Run:

```bash
bash tests/mctl/run-tests.sh
```

Expected: all `tests/mctl` tests pass.

- [ ] **Step 4: Run syntax checks**

Run:

```bash
bash -n scripts/lib/spec2pr-runtime.sh scripts/spec2pr.sh scripts/review-pr.sh scripts/mctl.sh tests/spec2pr/stub-codex.sh tests/spec2pr/test-harness.sh tests/spec2pr/test-stages.sh tests/spec2pr/test-review-pr.sh tests/mctl/test-add.sh
```

Expected: exit 0.

- [ ] **Step 5: Run whitespace check**

Run:

```bash
git diff --check
```

Expected: exit 0 and no output.

- [ ] **Step 6: Inspect changed file scope**

Run:

```bash
git diff --stat HEAD~4..HEAD
git diff --name-only HEAD~4..HEAD
```

Expected changed files:

```text
README.md
scripts/lib/spec2pr-runtime.sh
scripts/mctl.sh
scripts/review-pr.sh
scripts/spec2pr.sh
tests/mctl/test-add.sh
tests/spec2pr/stub-codex.sh
tests/spec2pr/test-harness.sh
tests/spec2pr/test-review-pr.sh
tests/spec2pr/test-stages.sh
```

If the implementation plan file is committed on the same branch, it may also
appear in the final branch diff:

```text
docs/superpowers/plans/2026-06-21-spec2pr-codex-fast-mode-design-plan.md
```

- [ ] **Step 7: Commit docs and final verification state**

```bash
git add README.md
git commit -m "docs: document codex fast mode"
```

- [ ] **Step 8: Final report**

Report:

- Whether `--fast` is off by default.
- Which Codex roles receive fast args.
- Which direct and `mctl` commands accept `--fast`.
- Exact verification commands and pass/fail results.
