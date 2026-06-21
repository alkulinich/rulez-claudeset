# plan author: claude writes the plan, codex reviews it

## Context

spec2pr runs spec-review → plan → plan-review → implement → pr-review. Today
codex authors the plan (`spec2pr.sh:241`, `codex_call plan plan "$pf"`) and the
plan-review loop (`spec2pr.sh:260`, `review_loop plan-review`) also runs codex
(`codex_call review`). So **plan-review is codex grading a plan codex wrote** —
the one self-review hole in the pipeline.

Every other artifact is already graded by a different model family than authored
it: codex implements and claude reviews the PR (default), claude classifies, and
codex fixes. Flipping plan authoring from codex to claude closes the plan hole
and completes the chain — **claude plans → codex reviews + implements → claude
reviews the PR → codex fixes** — so each stage is judged by the opposite family.

This is the minimal cross-model shift. The review side needs no change: codex is
already the plan reviewer, so a claude-authored plan becomes cross-model for
free. Claude is already a hard dependency (`require_claude`, `spec2pr.sh:88`,
because claude is the default PR reviewer), so nothing new is required to run.

## Settled decisions

Decided in brainstorming; fixed scope.

- **Capture = file + free summary.** Claude has no `--output-schema`
  (`codex_call` uses one, `spec2pr-runtime.sh:272-273`; claude returns its own
  envelope with the model text in `.result`). So we do not ask claude for a
  `{plan_path, summary}` object. Claude writes the plan file; we verify it
  structurally with the guards already in the code; the summary is `.result`.
- **No new knob.** Plan authoring is hardcoded to claude, like the rest of the
  default topology. No `--author` flag (YAGNI).
- **Review loop untouched.** `review_loop` keeps its fused review+fix codex
  call. Codex still patches the plan it reviews — the independence we want is
  authoring vs. judgment, which the author flip already gives us. No
  reviewer/fixer split, no fixer-context for plan-review here.
- **Spec-review stays single-model codex.** The spec is human-authored, so codex
  reviewing it is already cross-author; there is no self-review hole to close.
- **Separate PR.** Lands independently of the fixer-context spec already on
  `main` (`docs/superpowers/specs/2026-06-21-review-pr-fixer-context-design.md`).

## Affected code

Single change locus: the plan-authoring block in `spec2pr.sh` (the
`STAGE="plan"` `if [ ! -f ... ]` branch, `:231-258`).

**Not** affected:

- `review_loop` (`spec2pr.sh:151-227`) and its `plan-review` call (`:260`) — the
  reviewer is already codex.
- `pr_review_engine_run` and the spec-review call (`:229`).
- `run_claude_json` / `codex_call` (`spec2pr-runtime.sh`) — reused as-is.
- The resume gate `if [ ! -f "$WORKTREE/$WT_PLAN_REL" ]` (`:232`) — file-based,
  independent of which model authored the plan.

## The change

### Prompt

Keep the `$superpowers:writing-plans` invocation — it is a Claude/superpowers
skill, so a claude author runs it natively (codex only treated it as a hint).
Drop the schema line; add the standard safety rail; ask for a prose summary as
the final message:

```
Use $superpowers:writing-plans to write an implementation plan for the
feature spec at $WT_SPEC_REL.

Create exactly one plan file at $WT_PLAN_REL. Do not edit any other files. Do
not commit, push, or create branches or PRs. Your final message should briefly
summarize the plan.
```

### Call and capture

Replace `codex_call plan plan "$pf"` and the codex result parsing with:

```bash
run_claude_json plan "$pf" "$META_DIR/plan.claude.json"
[ -f "$WORKTREE/$WT_PLAN_REL" ] || halt "planner did not write plan"
assert_only_planner_path_changed
plan_summary="$(jq -r '.result // ""' "$META_DIR/plan.claude.json")"
jq -n --arg p "$WT_PLAN_REL" --arg s "$plan_summary" \
  '{plan_path:$p, summary:$s}' > "$META_DIR/plan.json"
```

`run_claude_json` already HALTs on a non-zero claude exit or invalid JSON
envelope (`spec2pr-runtime.sh:351-363`). The claude envelope is written to
`plan.claude.json`; we synthesize the schema-shaped `plan.json`
(`{plan_path, summary}`) so every downstream reader is byte-compatible:

- `show_summary "$META_DIR/plan.json"` (`:255`) reads `.summary` — unchanged.
- Nothing else reads `plan.json` after authoring.

Everything below the capture is **unchanged**: the `SPEC2PR_MAX_PLAN` size check
→ `split` (`:246-249`), the `spec2pr: write plan` commit (`:250-253`), the
`status "OK" "plan ok $WT_PLAN_REL"` line (`:254`), and `show_summary` (`:255`).

### Guards that change

Codex's enforced schema gave two guards that claude cannot; the structural
guards already in the block cover the same failures.

| Bad plan | Old (codex) halt | New (claude) halt |
|---|---|---|
| wrote to wrong path | `planner wrote unexpected path` (self-report) | `planner did not write plan` (`-f` check; correct file absent) |
| malformed / no JSON | `codex plan violated plan schema` | n/a — no schema to violate |
| edited an extra file | `planner changed unexpected files` | same (`assert_only_planner_path_changed`) |
| oversized plan | `SPLIT plan` | same (size check on the file) |

We delete the `plan_path="$(jq -r '.plan_path' ...)"` parse and the
`[ "$plan_path" = "$WT_PLAN_REL" ] || halt "planner wrote unexpected path"`
assertion. The `-f` existence check (run before `assert_only_planner_path_changed`)
and the planner scope guard already catch wrong-path and stray-edit failures.

## Edge cases & invariants

- **Resume with plan present:** the `if [ ! -f ]` gate skips authoring entirely;
  claude is not called for the plan on resume. Unchanged.
- **Empty `.result`:** `jq -r '.result // ""'` yields an empty summary; the plan
  file guard (`-f`) is the real gate, so an empty summary is non-fatal.
- **`plan.json` shape:** preserved as `{plan_path, summary}` for downstream
  parity, even though `plan_path` is now synthesized rather than self-reported.
- **No new dependency, no new knob, no review-loop change.**

## Testing

`tests/spec2pr/`. The harness already exercises claude (pr-review uses claude for
review + classify), so `enqueue_claude` / `claude_calls` are wired
(`helpers.sh:116,142`). The claude stub runs its fixture with cwd = the worktree
(via the `cd "$WORKTREE"` in `claude_json_attempt`), so a claude plan fixture can
write the plan file exactly as the codex one does.

### Fixture migration

`queue_valid_planner` (`test-stages.sh:19`) moves from a codex fixture to a
claude fixture: still `mkdir -p` + write the plan file, but enqueued with
`enqueue_claude` and its stdout is the claude **envelope** `{"result":"wrote
plan"}` instead of `{"plan_path":...,"summary":...}`.

### Count shifts (mechanical)

Each full run moves one model call from the codex queue to the claude queue. So:

- `codex_calls` assertions drop by 1 each (plan is authored once per scenario
  and persists across reruns): the seven `=6` checks in `test-stages.sh` → `=5`,
  and the two `=7` forged-marker checks → `=6`.
- `test-pipeline.sh` `codex_calls` assertions also drop by 1 for scenarios that
  author a plan: `=4` → `=3`, `=5` → `=4`, and each `=7` resume/stale-implementation
  assertion → `=6`.
- The existing `claude_calls` assertions in `test-pipeline.sh` rise by the same
  one plan-authoring claude call in those tests: `=2` → `=3`, `=4` → `=5`, and
  each `=3` classifier-retry assertion → `=4`.

Recount per run after the change — codex authors: spec-review, plan-review,
implement; claude authors: plan, pr-review (review + classify).

### Plan-error tests (`test-stages.sh`)

- `test_plan_wrong_path_halts` → claude fixture writes only `wrong.md`; expected
  message becomes `planner did not write plan` (the correct file is absent).
- `test_plan_schema_violation_halts` → **replaced** by `test_plan_missing_file_halts`:
  a claude fixture that writes no plan file and returns a normal envelope →
  `planner did not write plan`. (There is no schema to violate anymore.)
- `test_oversized_plan_splits` and `test_plan_unrelated_file_change_halts` →
  move the fixture to the claude queue (`enqueue_claude`, envelope stdout);
  assertions (`SPLIT plan`, `planner changed unexpected files`) stay.

### New positive assertion

In a full-pipeline test (e.g. `test_plan_written_and_committed`), assert the plan
authoring call went to claude: `claude_calls` increased, and the plan stage still
reaches `plan ok $PLAN_REL` + `plan-review r1 ... clean`.

All other existing tests must stay green.

## Out of scope

- **Spec-review cross-model.** The spec is human-authored; codex review is
  already cross-author. No change.
- **Reviewer/fixer split for plan-review.** The fused review+fix codex call
  stays. Deferred.
- **Fixer-context for plan-review.** Separate, already-specced concern for the
  PR-review fixer; not extended to plan-review here.
- **An author-model knob.** Hardcoded claude; YAGNI.
