# spec2pr `--implementer` switch — part 2: `claude:sonnet` model tier

*Part 2 of 2.* **part-1 is already merged into main; build on it, do not
re-specify its changes.**

> Split note: deliberate decomposition along the agent/model seam, not a
> size-gate recovery — the source blob carried no `SPLIT size=N limit=M`
> evidence (gate defaulted to `spec`).

## Context

Part 1 added `--implementer codex|claude` (the agent switch), the claude
implement adapter, and the reviewer-opposite wiring. This part adds the optional
**model tier**: `--implementer claude:sonnet` pins *only* the implement call to
Sonnet, while every other Claude stage (plan author, forecast, spec/plan-review,
and the Claude side of pr-review) keeps its strong default model. The goal is a
cheaper/faster implement pass without weakening the plan or the critic.

## Settled decisions

> part-1 is already merged into main; build on it, do not re-specify its changes.

- **Extend the part-1 allowlist** from `{codex, claude}` to
  `{codex, claude, claude:sonnet}`. `claude:haiku`, `claude:opus`, `codex:*`,
  and bare `claude:` remain rejected. Sonnet is the only tier (haiku/opus are
  YAGNI; add later by extending the allowlist).
- **`claude:sonnet` ⟹ `IMPLEMENTER_AGENT=claude`, `IMPLEMENTER_MODEL=sonnet`.**
- **The model attaches to the implement call ONLY.** plan author, forecast,
  spec-review, plan-review, and the Claude side of pr-review (including the
  claude fixer) keep their default model.
- **No regression to part 1:** `codex` and `claude` (no tier) behave exactly as
  part 1 shipped them; with an empty model no `--model` is ever emitted.

## Affected code

> part-1 is already merged into main; build on it, do not re-specify its changes.

- `scripts/spec2pr.sh`
  - extend the `--implementer` allowlist and parse the `:sonnet` suffix into
    `IMPLEMENTER_MODEL`.
  - persist and validate the normalized model tier in metadata alongside the
    part-1 `implementer-agent`, so resumed runs keep the same implement model.
  - forward `IMPLEMENTER_MODEL` into the part-1 claude implement adapter.
- `scripts/lib/spec2pr-runtime.sh`
  - add an optional trailing `model` argument to `claude_json_attempt` and
    `run_claude_json`; emit `--model` only when it is non-empty.
- `VERSION`, `UPGRADE.md`.
- `tests/spec2pr/test-implementer.sh` (extend with tier cases).

## The change

### 1. Arg parsing (`spec2pr.sh`)

Accept `claude:sonnet` in addition to part-1's `codex` / `claude`:

| input           | `IMPLEMENTER_AGENT` | `IMPLEMENTER_MODEL` |
|-----------------|---------------------|---------------------|
| `codex`         | `codex`             | *(empty)*           |
| `claude`        | `claude`            | *(empty)*           |
| `claude:sonnet` | `claude`            | `sonnet`            |

Everything else still halts at parse time, with the message updated to
`halt "invalid --implementer: <value> (want codex|claude|claude:sonnet)"`.

Initialize `IMPLEMENTER_MODEL=""` before argument parsing. Normalize the raw
`--implementer` value immediately after parsing:

- `codex` -> `IMPLEMENTER_AGENT=codex`, `IMPLEMENTER_MODEL=""`
- `claude` -> `IMPLEMENTER_AGENT=claude`, `IMPLEMENTER_MODEL=""`
- `claude:sonnet` -> `IMPLEMENTER_AGENT=claude`, `IMPLEMENTER_MODEL=sonnet`

Do not persist the raw flag value as the agent; the rest of the pipeline should
continue to branch on `IMPLEMENTER_AGENT=codex|claude`.

### 1a. Resume metadata (`spec2pr.sh`)

Persist the normalized tier in `$META_DIR/implementer-model` alongside the
part-1 `$META_DIR/implementer-agent`:

- Fresh worktree: write both files. `codex` and bare `claude` write an empty
  `implementer-model`; `claude:sonnet` writes `sonnet`.
- Resumed worktree with both files: read and validate both. If
  `--implementer` was supplied, compare the normalized requested
  `(IMPLEMENTER_AGENT, IMPLEMENTER_MODEL)` pair to the recorded pair and halt on
  any mismatch before model calls.
- Recorded metadata is valid only for these normalized pairs:
  `(codex, "")`, `(claude, "")`, and `(claude, "sonnet")`. Reject unknown
  agents, unknown model strings, and inconsistent pairs such as
  `(codex, "sonnet")`.
- Resumed part-1 worktree missing `implementer-model`: treat it as an empty
  model, create the empty metadata file, and keep the existing
  `implementer-agent` migration behavior for pre-part-1 worktrees.
- Resumed worktree without `--implementer`: reuse both recorded values, so a
  partial `claude:sonnet` run still invokes the implement stage with Sonnet
  after process restart.

Recommended conflict halt text:

```sh
halt "worktree implementer is $recorded_display; rerun with matching --implementer or omit the flag"
```

where `recorded_display` is `codex`, `claude`, or `claude:sonnet`.

### 2. Model plumbing (`spec2pr-runtime.sh`)

`claude_json_attempt` and `run_claude_json` gain an optional trailing `model`
argument. The invocation becomes:

```sh
"$SPEC2PR_CLAUDE_BIN" -p ${model:+--model "$model"} --output-format json \
  --dangerously-skip-permissions
```

Empty `model` (the default for every existing caller, including part-1's claude
implement adapter call) emits no `--model`, so plan / forecast / pr-review
behavior is unchanged.

### 3. Wire the tier into the implement adapter (`spec2pr.sh`)

The part-1 claude branch already calls
`run_claude_json implement "$prompt" "$envelope"`. Add the model argument:
`run_claude_json implement "$prompt" "$envelope" "$IMPLEMENTER_MODEL"`. The codex
branch is unaffected.

## Edge cases & invariants

- **Tier is implement-only:** when implementer is `claude:sonnet`, the pr-review
  *fixer* is also claude but runs at the default model — the Sonnet tier never
  leaks into review, fix, plan, or forecast.
- **`claude` (no tier) is unchanged:** still the default Claude model, no
  `--model`.
- **Resume preserves the tier:** after a run started with
  `--implementer claude:sonnet`, rerunning without `--implementer` reuses
  `IMPLEMENTER_AGENT=claude` and `IMPLEMENTER_MODEL=sonnet`. Rerunning that
  worktree with `--implementer claude` halts before any model call because it
  conflicts with the recorded `claude:sonnet` pair.
- **Legacy metadata stays compatible:** part-1 worktrees with
  `implementer-agent` but no `implementer-model` are migrated to an empty model.
- **Empty model ⟹ no invocation behavior change from part 1** for the `codex`
  and bare `claude` paths: no `--model` appears on any Claude call. Metadata is
  intentionally not byte-identical because the new `implementer-model` file is
  written even when empty.
- **Validation precedes side effects:** `claude:haiku`, `claude:opus`,
  `codex:sonnet`, and bare `claude:` halt at arg-parse before any worktree is
  created.

## Testing

Extend `tests/spec2pr/test-implementer.sh` (existing codex/claude stubs):

- **`--implementer claude:sonnet`:** stub claude records argv; assert
  `--model sonnet` is present on the implement call and **absent** on the
  plan / forecast calls. Include a dirty codex pr-review round that invokes the
  Claude fixer, and assert that fixer invocation also has no `--model`.
- **`--implementer claude` (no tier):** no `--model` on any call.
- **resume preservation:** seed a `claude:sonnet` worktree that reaches a
  resumable point before implementation completion, rerun without
  `--implementer`, and assert the resumed implement call still receives
  `--model sonnet`.
- **resume conflict:** seed a `claude:sonnet` worktree, rerun with
  `--implementer claude`, and assert it halts before model calls with the
  recorded implementer shown as `claude:sonnet`.
- **legacy migration:** a part-1 worktree containing `implementer-agent=claude`
  but no `implementer-model` resumes as bare `claude` and emits no `--model`.
- **invalid inputs:** `claude:haiku`, `claude:opus`, `codex:sonnet`, bare
  `claude:` ⟹ arg-parse halt, nonzero exit, no worktree created.
- **regression:** part-1 cases (codex default, claude happy/blocked, reviewer
  opposite) still pass.

## Out of scope

- Tiers other than `sonnet` (haiku/opus) — extend the allowlist when actually
  needed.
- Selecting the reviewer's or fixer's model independently of the implementer.
- Plumbing `--implementer` through `mctl` or `spec2pr-chain`.
- Any model selection for codex.

## Version

`VERSION` `1.11.2` → `1.11.3` (additive tier on an existing flag — patch). The
original draft targeted `1.11.0` → `1.11.1`, but `1.11.1` (implement-branch
reattach) and `1.11.2` (spec2pr-chain merge-cleanup fix) shipped as hotfixes
first; bump from whatever `VERSION` reads on `main` at implement time if it has
moved past `1.11.2`.
`UPGRADE.md` top section:

```
## To v1.11.3 - from v1.11.2

**Action:** None.

**Caveat:** `--implementer` now also accepts `claude:sonnet`, which pins only
the implement call to Sonnet (every other Claude stage keeps its default model).
`claude:haiku`/`claude:opus` are not supported.
```
