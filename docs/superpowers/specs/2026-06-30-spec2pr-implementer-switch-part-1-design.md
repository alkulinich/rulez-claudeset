# spec2pr `--implementer codex|claude` — part 1: agent selection

*Part 1 of 2. Part 2 adds the `claude:sonnet` model tier and builds on this.*

> Split note: this is a deliberate decomposition along the agent/model seam, not
> a size-gate recovery — the source blob carried no `SPLIT size=N limit=M`
> evidence (gate defaulted to `spec`). Part 1 delivers a complete, useful
> feature on its own: pick the implement agent, with the pr-review reviewer
> following as the opposite agent.

## Context

spec2pr's implement stage is hardcoded to codex
(`codex_call implement implement`, `scripts/spec2pr.sh:643`). The pipeline is
already cross-agent and adversarial — claude authors the plan and reviews the
PR, codex reviews the plan, implements, and fixes pr-review findings. This part
lets a run choose the *implement* agent (`codex` or `claude`) and flips the
final pr-review to the opposite agent. The model-tier knob (`claude:sonnet`) is
intentionally deferred to part 2.

Backward-compatible: the default is `codex`, reproducing today's behavior
byte-for-byte.

## Settled decisions

- **Flag lives on `spec2pr.sh` only.** Not plumbed through `mctl` or
  `spec2pr-chain`.
- **Part-1 grammar is a strict two-value allowlist:** `codex` (default) and
  `claude`. Any other value is rejected at parse time — including anything
  containing a `:` (so `claude:sonnet` is rejected *in part 1*) and `codex:*`.
  `claude:sonnet` becomes valid in part 2.
- **pr-review reviewer = the opposite agent of the implementer.** `codex` ⟹
  claude reviews (today's default); `claude` ⟹ codex reviews. The fixer is the
  engine's opposite-of-reviewer, which equals the implementer.
- **Resume preserves the implementer choice.** Store the selected implementer in
  metadata before any worktree setup. A resumed run must use the recorded value,
  so a run that implemented with claude still gets a codex pr-review even if the
  resume command omits `--implementer`.
- **Default `codex` ⟹ identical to current behavior.** The existing suite stays
  green untouched.
- **Both `require_codex` and `require_claude` remain.** codex still runs
  plan-review and claude still authors the plan regardless of implementer.
- **Part 1 never passes `--model`.** No model-tier concept is introduced here.

## Affected code

- `scripts/spec2pr.sh`
  - usage + arg parsing: document/add `--implementer`, set
    `IMPLEMENTER_AGENT`.
  - metadata: persist and reload `$META_DIR/implementer-agent` so resumed runs
    keep the original reviewer/fixer pairing.
  - implement dispatch (`643`–`670`): branch codex vs claude before the shared
    `status` handling.
  - pr-review call (`696`): pass the opposite reviewer when implementer=claude.
- `scripts/lib/spec2pr-runtime.sh`
  - factor the `implement` jq filter out of `validate_codex_output` into a
    shared `implement_json_valid` check that preserves the exact current schema:
    the payload must be an object with exactly `status`, `summary`, and
    `blocked_reason`; `status` must be `done` or `blocked`; both text fields
    must be strings; no additional keys are accepted.
  - add the claude implement adapter (calls `run_claude_json` **without** a
    model argument — model plumbing is part 2).
- `VERSION`, `UPGRADE.md`.
- `tests/spec2pr/test-implementer.sh` (new).
- `tests/spec2pr/test-preflight.sh` (usage assertion update).

## The change

### 1. Arg parsing (`spec2pr.sh`)

Accept `--implementer <agent>` and `--implementer=<agent>`. Validate against the
two-value allowlist and set `IMPLEMENTER_AGENT` (default `codex`):

| input        | `IMPLEMENTER_AGENT` |
|--------------|---------------------|
| *(absent)*   | `codex`             |
| `codex`      | `codex`             |
| `claude`     | `claude`            |

Anything else halts before any worktree setup:
`halt "invalid --implementer: <value> (want codex|claude)"`.

Persist the selected value in `$META_DIR/implementer-agent` as part of the
run metadata:

- **New worktree:** write `IMPLEMENTER_AGENT` next to `source-path`,
  `source-sha256`, and `base-sha` immediately after creating `$META_DIR`.
- **Resumed worktree:** require the metadata file. If the user supplied
  `--implementer`, it must match the recorded value or halt before doing any
  stage work: `halt "worktree implementer is <recorded>; rerun with matching --implementer or omit the flag"`.
  Then set `IMPLEMENTER_AGENT` from the recorded value before implementation or
  pr-review decisions.

Update `usage()` in `spec2pr.sh` and the existing preflight usage assertion so
the contract includes the new flag:

```
spec2pr.sh [--fast] [--implementer codex|claude] [--ignore-plan-limit] [--ignore-pr-limit] [--start-from spec-review|plan|plan-review|implementation] <spec-path>
```

### 2. Implement dispatch (`spec2pr.sh`)

Replace the single `codex_call implement implement "$pf"` with a branch. Both
branches must leave `$META_DIR/implement.json` holding
`{status, summary, blocked_reason}`; the existing `blocked` / `done` /
unexpected handling (`644`–`670`) then runs unchanged.

- **codex branch:** exactly as today — `codex_call implement implement "$pf"`.
  `codex_call` sets `CALL_START_HEAD` and gets the schema-validated object for
  free via `codex exec --output-schema`.

- **claude branch:** the Claude CLI has no `--output-schema` equivalent, so
  Claude is *prompted* to emit the JSON and the orchestrator re-parses it — the
  same pattern the forecast stage already uses (`spec2pr.sh:528`–`532`). Steps:
  1. Set `CALL_START_HEAD="$(git -C "$WORKTREE" rev-parse HEAD)"` before the
     call (mirroring `codex_call`) so a failed/blocked run cleans back to the
     right base.
  2. Write the claude implement prompt (below) to
     `$META_DIR/implement.claude.prompt`.
     Preserve the literal `$superpowers` token by escaping `$` in the shell
     heredoc (`\$superpowers`) or by using a quoted heredoc and substituting the
     plan/spec paths separately.
  3. `run_claude_json implement "$META_DIR/implement.claude.prompt" \
     "$META_DIR/implement.envelope.json"` (no model argument in part 1).
  4. Normalize the envelope result into `$META_DIR/implement.json`: if `.result`
     is already an object, write it directly; otherwise treat `.result` as text
     and extract the first balanced JSON object with the existing
     `extract_json_object` helper (the same fallback shape used by forecast and
     pr-review classification).
  5. Validate with `implement_json_valid`, using the same strict contract as the
     existing codex implement output (`status`, `summary`, and `blocked_reason`
     only; exact key set; string text fields; `done|blocked` status). On failure:
     `clean_worktree_to "$CALL_START_HEAD"` then
     `halt "claude implement returned invalid result"`.

Claude implement prompt:

```
Use $superpowers:subagent-driven-development to implement the plan at
$WT_PLAN_REL for the spec at $WT_SPEC_REL.

Make the necessary code, test, and documentation changes in this worktree.
Commit the implementation changes. Do not push, do not create a PR.

Your final message MUST be exactly one JSON object and nothing else (no prose,
no markdown, no code fences):
{"status":"done"|"blocked","summary":"<what you did>","blocked_reason":"<empty unless blocked>"}
```

### 3. pr-review reviewer (`spec2pr.sh:696`)

```sh
if [ "$IMPLEMENTER_AGENT" = "claude" ]; then
  pr_review_engine_run codex      # codex reviews, claude fixes
else
  pr_review_engine_run            # default: claude reviews, codex fixes
fi
```

The engine already pairs reviewer with the opposite fixer
(`pr-review-engine.sh:79`–`81`); this only chooses the argument.
Because `IMPLEMENTER_AGENT` is reloaded from `$META_DIR/implementer-agent` on
resume, this branch remains correct after implementation, push, PR creation, or
pr-review retries.

## Edge cases & invariants

- **Default is untouched:** no flag ⟹ codex ⟹ identical contract lines and exit
  codes. Verified by a baseline-equivalence test.
- **Malformed claude output:** prose- or fence-wrapped JSON is recovered with
  the existing first-balanced-object fallback; still invalid ⟹ clean worktree +
  contract halt (nonzero), recoverable by a resume run. No partial/corrupt state.
- **Strict schema parity:** both codex and claude implement results use the same
  exact `implement_json_valid` schema, including rejection of extra or missing
  keys.
- **Blocked path parity:** claude `status:blocked` halts with `blocked_reason`,
  exactly like the codex blocked path; no implementation markers written.
- **Clean-tree invariant:** after `status:done` the worktree must be
  committed-clean (existing check at `652`) — enforced for both agents.
- **`CALL_START_HEAD` discipline:** set before the claude call so a failed or
  blocked run resets to the pre-call HEAD, matching `codex_call`.
- **Resume reviewer invariant:** once a worktree exists, the recorded
  `$META_DIR/implementer-agent` is authoritative. A no-flag resume uses it; a
  conflicting flag halts before model calls, pushes, or pr-review.
- **Validation precedes side effects:** `codex:*`, bare `claude:`, and
  `claude:sonnet` (not yet supported) all halt at arg-parse, before any worktree
  or branch is created.

## Testing

New `tests/spec2pr/test-implementer.sh`, reusing the existing codex and claude
stubs and sandbox helpers:

- **default (no flag):** codex implement path reaches DONE; contract matches the
  baseline codex run.
- **`--implementer codex` (explicit):** identical to default.
- **`--implementer=codex` (equals form):** identical to default.
- **`--implementer claude` happy:** stub claude envelope `.result` =
  `{"status":"done",...}` and makes a commit ⟹ DONE, `implementation-ok` marker
  written.
- **`--implementer=claude` (equals form):** same claude happy path, proving both
  accepted parser forms dispatch to the claude implement branch.
- **`--implementer claude` blocked:** `.result` status `blocked` ⟹ HALT with the
  reason; no markers written.
- **`--implementer claude` schema violation:** extra keys, missing keys, or an
  invalid `status` in the normalized `.result` ⟹ HALT
  `claude implement returned invalid result`, clean worktree, no markers written.
- **reviewer opposite:** `--implementer claude` ⟹ pr-review invokes the codex
  reviewer and the claude fixer (assert via stub call records).
- **resume preserves reviewer opposite:** start with `--implementer claude`,
  stop after a valid implementation marker or before pr-review completes, then
  rerun without `--implementer`; assert pr-review still invokes the codex
  reviewer and claude fixer. A rerun with `--implementer codex` against that
  worktree halts on the metadata mismatch before model calls.
- **invalid inputs:** `claude:sonnet`, `codex:fast`, bare `claude:` ⟹ arg-parse
  halt, nonzero exit, no worktree created.
- **usage:** no-arg preflight output includes
  `[--implementer codex|claude]`.

## Out of scope

- The `claude:sonnet` model tier and any `--model` plumbing — **part 2**.
- Plumbing `--implementer` through `mctl` or `spec2pr-chain`.
- Any model selection for codex (codex `fast_mode` is a separate, unchanged
  toggle).

## Version

`VERSION` `1.10.1` → `1.11.0` (new user-facing flag — minor). `UPGRADE.md` top
section:

```
## To v1.11.0 - from v1.10.1

**Action:** None.

**Caveat:** spec2pr accepts `--implementer codex|claude` (default `codex`,
identical to before). `claude` implements with the Claude CLI and flips the
pr-review reviewer to codex. Not available via mctl or spec2pr-chain.
```
