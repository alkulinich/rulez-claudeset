# review-pr fixer-context: feed the fixer prior rounds' findings and fixes

## Context

`pr_review_engine_run` (`scripts/lib/pr-review-engine.sh`) runs a review→fix
loop: a fresh-eyes reviewer reads the diff, classifies severity, and on any
blocker/major the opposite model fixes the findings in the worktree; the engine
commits + pushes, regenerates the diff, and re-reviews, up to `MAX_FIX_ROUNDS`
(default 3, `scripts/lib/spec2pr-runtime.sh:18`).

Today the fixer is the most context-starved actor in the loop. Its prompt
(`pr-review-engine.sh:198-235`, both the codex and claude branches) contains
only the **current** round's review findings plus read access to the worktree.
It cannot see what earlier rounds changed or why — only the current complaint.

The reviewer, by contrast, has implicit memory: fixes are committed each round
and the diff is recomputed `BASE_SHA...HEAD` (`:240`), so round-N review sees the
cumulative result of all prior fixes. That asymmetry is the problem. A blind
fixer can re-try an approach a previous round already attempted and the reviewer
already rejected, so the loop can oscillate instead of converging — and each
extra round is another model call.

This feature closes the asymmetry: give the fixer a compact, chronological
record of what was flagged and what was changed in prior rounds, with an
explicit instruction not to undo prior fixes and to try a different approach for
a recurring finding.

## Settled decisions

These were decided in brainstorming and are fixed scope:

- **Context = finding+action log only.** Per prior round: the review findings
  text and the fixer's own summary. No raw diff, no full source (the worktree
  already provides current state).
- **All prior rounds, no window.** `MAX_FIX_ROUNDS` is 3, so the fixer never
  sees more than two prior rounds — windowing would be dead code. Include every
  prior round; no magic number, no byte cap.
- **Reuse existing files.** The per-round `pr-review-r$r.review` and
  `pr-review-r$r.fix` files already exist; no new artifact, no summarization
  call.
- **Push, not pull.** The history is assembled into the fix prompt, not left for
  the fixer to fetch via git. Deterministic, matches the engine's strict style.
- **Reviewer untouched.** The preamble goes only into the fix prompt. The
  reviewer stays fresh-eyes (diff only) so it remains an independent detector.
- **No spec/plan to the fixer, no loop-break overseer.** Both explicitly
  deferred (see Out of scope).

## Affected code

Single change locus: the fix-prompt assembly in `pr_review_engine_run`
(`pr-review-engine.sh:198-235`), both fixer branches:

- codex fixer `:199-216`
- claude fixer `:217-235`

Both branches call `pr_review_engine_run`, so the change reaches **both**
entry points:

- `review-pr.sh:134` — the standalone PR-review fixer.
- `spec2pr.sh:404` — spec2pr's final PR-review stage fixer.

**Not** affected: spec2pr's separate spec-review and plan-review loops
(`spec2pr.sh:156`), which have their own fix prompts. Extending history to those
is out of scope (see Punts).

## The change

### History preamble assembly

Before building the fix prompt, assemble a preamble from the prior rounds'
existing files. For each round `r` in `1 … round-1`, read
`$META_DIR/pr-review-r$r.review` (what was flagged) and
`$META_DIR/pr-review-r$r.fix` (what the fixer reported doing), and emit one
block per round, oldest first.

The preamble resolves to an **empty string on round 1** (no prior rounds), so
the round-1 fix prompt is byte-identical to today's — preserving current
behavior and existing single-round tests. From round 2 on, the preamble is
prepended to the existing prompt body.

A prior-round file should always exist by construction, but the assembly reads
defensively: a missing or empty `.review`/`.fix` for a round is skipped, never a
`halt`. This is advisory context; a finished or in-progress run must not fail
because a metadata file is absent.

### Prompt format

When history exists, the assembled fix prompt is:

```
The earlier rounds below already attempted fixes on this PR. Shown oldest
first: what the reviewer flagged, and what was changed in response. Do not
undo a prior fix unless the current findings require it. If a finding keeps
recurring, try a different approach than the ones already attempted.

=== Round 1 ===
Reviewer findings:
<pr-review-r1.review verbatim>
Fix attempt:
<pr-review-r1.fix verbatim>

=== Round 2 ===
Reviewer findings:
<pr-review-r2.review verbatim>
Fix attempt:
<pr-review-r2.fix verbatim>

Fix the blocker and major findings from this fresh-eyes PR review.

Review findings:
<current round's pr-review-r$round.review verbatim>

Make the necessary code, test, and documentation changes in this worktree.
Do not push, do not create a PR. <existing per-branch trailer>
```

The existing body below the preamble is unchanged, including the per-branch
trailer (the codex branch keeps its "Your final message must be exactly the
JSON required by the output schema" line; the claude branch keeps its shorter
ending). Both branches receive the identical preamble.

Mechanically: compute the preamble into a shell variable that is either empty or
ends with a blank line, and place it at the very start of each fix-prompt
heredoc. When empty, the heredoc begins with the existing first line, giving the
byte-identical round-1 prompt.

The anti-oscillation instruction in the preamble is the payload — it is what
turns raw history into convergence pressure rather than just more context.

## Edge cases & invariants

- **Round 1:** no preamble; prompt byte-identical to today.
- **Symmetry:** codex and claude fixers get the same preamble.
- **Reviewer prompt:** unchanged.
- **Missing metadata file:** skip that round's block, do not halt.
- **No new knobs, no new artifacts, no windowing.**

## Testing

Add to `tests/spec2pr/test-review-pr.sh`. The harness already supports
multi-round fixtures (see `test_review_pr_cap_exits_dirty`, which enqueues three
dirty rounds) and the fix prompt persists at
`$META_DIR/…/pr-review-r$N.fix.prompt`, so assertions can read it directly.

New test — **two dirty rounds then clean** (default codex-fixer path):

- round-2 fix prompt **contains** round-1's reviewer findings text;
- round-2 fix prompt **contains** round-1's fix summary text;
- round-1 fix prompt **does not contain** the preamble header (`=== Round`),
  i.e. the first round's prompt is unchanged;
- the run still reaches `PRREVIEW DONE`.

Add one analogous assertion on the **claude-fixer path** (`--reviewer codex`,
two dirty rounds then clean) confirming round-2's fix prompt carries round-1's
findings — since both fixer branches are edited.

All existing tests must stay green (round-1 prompt unchanged ⇒ no regression in
the single-round fixtures).

## Out of scope

- **Spec/plan in the fix prompt.** The fixer's design-intent need is met by the
  reviewer (which already receives the spec/plan in the spec2pr path) writing
  well-scoped findings. Adding the whole spec to the fixer is high-token,
  low-yield, and would diverge review-pr (no spec) from spec2pr. Deferred.
- **Loop-break overseer.** Early oscillation detection that breaks the loop
  before the cap. No thrashing has been observed in practice; the round cap is a
  sufficient backstop today. YAGNI.
- **Cheaper fixer/implementer model via gateway (openmodel/openrouter).** A
  separate change. This feature deliberately lands first because fixer memory is
  what makes a cheaper fixer safe and keeps round counts down.

[PUNT]: spec2pr's spec-review and plan-review loops (`spec2pr.sh:156`) have the
same context-starved fixer but their own fix prompts; extending history to them
is a follow-up, not part of this engine change.
