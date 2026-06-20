# review-pr: selectable reviewer model (`--reviewer claude|codex`)

## Context

`review-pr.sh` runs the shared review→fix loop (`scripts/lib/pr-review-engine.sh`,
`pr_review_engine_run`). Today that loop has two fixed model roles:

- **reviewer** — `claude` does a fresh-eyes prose review of the diff
  (`run_claude_json`), then a *second* claude call classifies the prose into
  `blockers_found` / `majors_found` counts.
- **fixer** — `codex` fixes the blocker/major findings (`codex_call pr-fix`).

So the loop is **claude-finds → codex-fixes**. When the human implements a PR by
hand *with claude* and then runs review-pr, claude reviews claude's own work —
same model on both sides. The goal is to let the reviewer be switched to codex
to restore cross-model contrast.

The engine is **shared**: `pr-review-engine.sh` is sourced by both
`review-pr.sh` and `spec2pr.sh`. spec2pr's final PR review must stay
claude-reviews → codex-fixes, byte-for-byte. In particular, an ambient
environment variable from a user's shell must not be able to flip spec2pr's
topology.

## Goal

Add a `--reviewer <claude|codex>` flag to `review-pr.sh` (default `claude`) that
selects the reviewer and **swaps the pair**: the fixer is always the other
model. Thread the same choice through `mctl add review-pr`.

## Non-goals

- No change to spec2pr's model topology (codex implements, claude reviews the
  final PR). spec2pr never sets the knob.
- No two-independent-knobs design — one flag picks the reviewer, the fixer is
  derived.
- No change to the commit/push/approve/ready done-path.

## Model topology

| `--reviewer` | reviews the diff | fixes findings | status |
|---|---|---|---|
| `claude` *(default)* | claude | codex | today's behavior, unchanged |
| `codex` | codex | claude | new |

The fixer is **derived**: `fixer = claude` when `reviewer == codex`, else `codex`.

## Change 1 — engine (`scripts/lib/pr-review-engine.sh`)

At the top of `pr_review_engine_run`, alongside the existing knobs, read one new
optional global behind an explicit caller opt-in:

```bash
local pr_reviewer="claude"
if [ "${PR_REVIEWER_SELECTABLE:-}" = "1" ]; then
  pr_reviewer="${PR_REVIEWER:-claude}"       # review-pr sets; spec2pr never opts in
fi
```

Validate it once (`claude` or `codex`); `halt` on anything else. Derive the
fixer locally (`codex` by default, `claude` when `pr_reviewer = codex`).
Because spec2pr never sets `PR_REVIEWER_SELECTABLE=1`, exported shell values
like `PR_REVIEWER=codex scripts/spec2pr.sh …` are ignored and spec2pr keeps the
existing claude-reviewer/codex-fixer topology.

### Reviewer branch (replaces the review + classify block, lines ~47–124)

- **`pr_reviewer = claude`** — unchanged from today:
  1. `run_claude_json "pr-review-r$round" …` → prose, extract `.result` →
     `$review_file`.
  2. Assert the worktree is clean (reviewer must not edit).
  3. **Classify** (the existing two-attempt second claude call) → `b` / `m`.

- **`pr_reviewer = codex`** — new, reuses the existing `review` codex schema:
  1. Write a codex-flavored review prompt (review the diff; do **not** edit,
     commit, push, or comment; the `--output-schema` already forces the shape).
     The prompt must carry the same severity contract as the existing classifier:
     blockers are release-blocking correctness, safety, data-loss, security, or
     contract failures; majors are high or medium severity regressions that should
     be fixed before human review; minor/low/nit observations go in `notes` only
     and never in `findings` or the blocker/major counts.
  2. `codex_call review "pr-review-r$round" "$review_prompt"` →
     `$META_DIR/pr-review-r$round.json`, validated against the `review` schema
     (`blockers_found`, `majors_found`, `notes`, `findings[]` with
     `artifact`/`evidence`/`severity`/`summary`).
  3. Assert the worktree is clean (reviewer must not edit).
  4. `b` / `m` come **straight from the schema** (`.blockers_found` /
     `.majors_found`) — the separate classify call is **skipped**.
  5. Mirror the existing codex review-loop integrity guard: count
     `findings[] | select(.severity=="blocker")` and
     `findings[] | select(.severity=="major")`; if either count differs from
     `.blockers_found` / `.majors_found`, `halt "review counts do not match
     findings ($review_json)"`.
  6. Render `$review_file` from the codex JSON (a `jq` render of `notes` plus
     each finding as `- [severity] artifact: summary` / `evidence: …`) so
     `show_review` and the downstream fix prompt consume it unchanged.

Both branches converge on the same `(review_file, b, m)`. The clean-vs-dirty
decision (`b + m == 0`), `show_review`, and the round/cap logic are unchanged.

### Fixer branch (replaces the `codex_call pr-fix` block, lines ~133–156)

- **fixer = codex** (reviewer = claude) — unchanged: `codex_call pr-fix …`,
  then `jq -r '.summary' …fix.json > …fix`.
- **fixer = claude** (reviewer = codex) — new:
  1. Write a claude fix prompt: fix the blocker/major findings, make the code/
     test/doc changes **in this worktree**, do **not** commit or push. (Omit the
     codex-only "final message must be the output-schema JSON" line.)
  2. `run_claude_json "pr-review-r$round.fix" "$fix_prompt" …fix.json` — the same
     `claude -p --dangerously-skip-permissions` call that already runs in the
     worktree, here *permitted to edit files*.
  3. Extract the summary from `.result` (claude envelope) → `…fix`.

Both fixers leave uncommitted edits in the worktree; the existing
`before_fix_head` / `after_fix_head` equality guard (fixer must not commit) and
the engine's own `add` / `commit` / `push` are unchanged.

### Status / log lines

Include the active reviewer in the per-round status (e.g.
`pr-review r$round reviewer=codex blockers=…`) so logs show which model ran.

## Change 2 — `scripts/review-pr.sh`

Replace the rigid single-positional check (`[ "$#" -eq 1 ]`, `PR_REF="$1"`) with
a small parse loop:

- Accept `--reviewer <claude|codex>` in any position; default `claude`.
- Keep exactly one positional (the PR ref); error on zero or more than one.
- Validate the reviewer value; `halt` with usage on anything else.
- Export `PR_REVIEWER` so the sourced engine sees it.
- Export `PR_REVIEWER_SELECTABLE=1` so the shared engine knows this caller is
  allowed to honor `PR_REVIEWER`; spec2pr does not set this opt-in.

Usage string becomes: `review-pr.sh [--reviewer <claude|codex>] <pr-number|pr-url>`.

## Change 3 — mctl forwarding (`scripts/mctl.sh`)

- `cmd_add` accepts `mctl add review-pr <pr#> [--reviewer <claude|codex>]`.
  Parse the optional flag; validate the value; **reject `--reviewer` for the
  `spec2pr` kind** with a clear `die` (its topology is fixed).
- Persist the choice as an **optional `reviewer` line in `meta`**, written only
  when set. `write_meta` gains a trailing optional positional
  (`reviewer="${10:-}"`) and emits the line only when non-empty, so the spec2pr
  callers (9 args) are unchanged.
- `build_inner_runner_command` reads the `reviewer` meta field and, when present
  (review-pr only), appends `--reviewer <r>` to the `review-pr.sh` invocation.

## Error handling

- Invalid `--reviewer` value rejected at both entry points (`halt` in
  `review-pr.sh`, `die` in `mctl.sh`) with the usage line.
- Two model-contract guards mirrored across modes: the reviewer must not modify
  the worktree (assert clean); the fixer must not commit (HEAD unchanged).
- The claude-fixer and codex-fixer both rely on the engine to commit/push; a
  fixer that wrongly commits trips the existing guard and `halt`s.

## Testing

Reuse the existing stub harness (`tests/spec2pr/stub-claude.sh`,
`stub-codex.sh`, `stub-gh.sh`, fixture queues, `codex_calls` counter; add a
`claude_calls` counter if not already present).

- **Engine, codex-reviews → claude-fixes, clean:** queue a codex `review`
  fixture with `blockers_found=0` / `majors_found=0`; assert `PRREVIEW DONE`,
  one codex review call, **zero** codex fix calls, and the claude classify call
  is **not** made.
- **Engine, codex-reviews → claude-fixes, one fix round:** first review returns
  a blocker, second is clean; assert one claude fix call, a commit + push, then
  `PRREVIEW DONE`.
- **Default path regression:** existing `test-review-pr.sh` (claude-reviews →
  codex-fixes) stays green untouched.
- **mctl:** in `tests/mctl/`, `mctl add review-pr <pr#> --reviewer codex`
  writes `reviewer=codex` to `meta` and the built inner command contains
  `--reviewer codex`; `--reviewer` on `spec2pr` is rejected.
- **spec2pr guard:** a spec2pr clean-done pipeline test asserts the engine call
  path never emits `--reviewer` / never flips to a claude fixer. Also run this
  guard with `PR_REVIEWER=codex` exported to prove ambient environment cannot
  change spec2pr's final PR-review topology.
- **Codex reviewer count integrity:** queue a schema-valid codex `review`
  fixture whose `blockers_found` / `majors_found` values do not match the
  severities in `findings[]`; assert the engine halts with
  `review counts do not match findings` instead of treating the round as clean
  or dirty from the inconsistent counters.

Run both suites; the spec2pr count and mctl count rise by the new asserts:
`bash tests/spec2pr/run-tests.sh` and `bash tests/mctl/run-tests.sh`.

## Files

- **edit** `scripts/lib/pr-review-engine.sh` — `PR_REVIEWER` knob; reviewer and
  fixer branches; review_file render for the codex reviewer.
- **edit** `scripts/review-pr.sh` — parse/validate `--reviewer`, export
  `PR_REVIEWER`.
- **edit** `scripts/mctl.sh` — accept/validate/persist/forward `--reviewer`
  (`cmd_add`, `write_meta`, `build_inner_runner_command`).
- **edit** `tests/spec2pr/test-review-pr.sh` (+ stubs) — new codex-reviewer
  coverage and the spec2pr guard.
- **edit** `tests/mctl/test-add.sh` — `mctl add review-pr --reviewer` persistence
  and forwarding coverage, plus `spec2pr --reviewer` rejection.

## Verification

- `bash tests/spec2pr/run-tests.sh` → all green.
- `bash tests/mctl/run-tests.sh` → all green.
- Manual (optional, real PR): `review-pr.sh --reviewer codex <pr#>` on a small
  PR → ends `PRREVIEW DONE`, logs show `reviewer=codex` and a claude fix call on
  any non-clean round. Default `review-pr.sh <pr#>` unchanged.
- `mctl add review-pr <pr#> --reviewer codex` → launched run's `brief.log`
  shows the codex reviewer; `mctl add spec2pr <spec> --reviewer codex` is
  rejected.

## Out of scope

- [PUNT]: a `--reviewer`-style knob for spec2pr's own review topology — not
  requested; spec2pr is already cross-model (codex implements, claude reviews).
