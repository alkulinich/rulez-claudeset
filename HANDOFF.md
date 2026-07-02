# Handoff

## Task
Two things this session, both in `rulez-claudeset`
(`/Users/rulez/Dropbox/Projects/26.03-shared-tools`, GitHub `alkulinich/rulez-claudeset`):
1. **Merge PR #29** — the headless-SDD implement fix (ceiling=0 +
   `SPEC2PR_IMPLEMENT_TIMEOUT` + prompt hardening) designed last session.
2. **Research + design a v2 hardening**: the user suspected the `claude -p` +
   subagent + background-wait-timeout trap is not unique to us. Research the web
   for better fixes, then design a v2. Outcome: a spec to **schema-bind every
   structured claude call** with `--json-schema`. Deliver = user chose spec →
   committed + pushed.

## Current State
- **Branch `main`**, HEAD `ff90c4b`, synced with `origin/main` (pushed).
- **PR #29 merged** into main (`5 files +779 -9`), local+remote branch deleted,
  remotes pruned. Verified green first: **1004/1004** spec2pr tests passed on the
  PR head (run in a subagent). No CI on this repo — local suite is the only gate.
- **v2 spec written, committed, pushed:**
  `docs/superpowers/specs/2026-07-02-spec2pr-claude-json-schema-binding-design.md`
  (`ff90c4b`, 13,359 bytes). **Not yet implemented** — no `scripts/` changes for
  v2 yet. Spec is on `origin/main`, so a dogfood spec2pr run can pick it up.
- Protected untracked paths still present/untracked (never staged):
  `references/`, `tmp/`, `docs/research-auto-handoff-at-context-threshold.md`,
  `docs/superpowers/specs/2026-06-29-spec2pr-chain-design.md`,
  `docs/superpowers/specs/2026-06-30-spec2pr-implementer-switch-design.md`.

## What Worked
- **PR #29 merge** via `git-merge-pr.sh 29 merge` after a subagent ran
  `tests/spec2pr/run-tests.sh` on the PR branch (1004/1004, repo returned to main
  clean). Merge touched `scripts/spec2pr.sh`, `scripts/lib/spec2pr-runtime.sh`,
  `tests/spec2pr/stub-claude.sh`, `tests/spec2pr/test-implement-headless.sh`,
  and the plan doc.
- **Web research (3 parallel subagents + self-verification against primary docs).**
  Confirmed verbatim from https://code.claude.com/docs/en/headless and
  https://code.claude.com/docs/en/env-vars:
  - In `claude -p`, background subagents ARE awaited, but that wait is **capped
    at 10 min since v2.1.182**; `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` = wait
    unlimited. (Our merged fix rests on this documented switch — validated.)
  - `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` makes subagents run
    **synchronously/foreground** (a cleaner lever than ceiling=0) — user chose to
    **defer** it this round.
  - `--output-format json --json-schema <schema>` = **constrained decoding**
    (grammar restricts token generation; model literally cannot emit
    non-conforming tokens) and **composes with full agentic tool use** — the
    agent uses tools, returns schema JSON in `.structured_output`. Reliability
    fix landed in **claude 2.1.187** (2026-06-23).
  - Community corroboration of the exact failure: GitHub #56540, #49150, #59962
    (parallel Task fan-out under a non-TTY parent can deadlock; both closed
    "not planned"). SDD dispatches serially, so we're mostly not exposed — but
    the outer `timeout` is doing real work, not theater.
  - superpowers `subagent-driven-development` is scoped in its SKILL.md to
    "the current session" — never designed for `claude -p`; sibling
    `executing-plans` is the inline, no-fan-out path. (obra/superpowers)
- **v2 design (brainstorming skill → spec).** Inventoried every claude JSON call
  and classified structured (schema-bindable) vs prose (must NOT touch):
  - Schema-bind: `implement`, `forecast`, `pr-review classify` (all share
    `claude_json_attempt`), `punts-enrich` (separate script).
  - Leave alone: `plan`, `pr-review` round, `pr-review` fix (freeform prose);
    `spec-review`/`plan-review` already run through `codex_call`.
  - Exact result shapes captured from `implement_json_valid`,
    `forecast_payload_valid`, the classify checks, and
    `punts-extract-prompt.sh`; schemas written into the spec.

## What Didn't Work
- First spec commit attempt failed: backticks in the `-m "$(cat <<'EOF'…)"`
  message were eval'd inside command substitution (`unexpected EOF`). Fixed by
  committing with `git commit -F <msgfile>` (message file in scratchpad). File
  was already correctly staged; only the commit re-ran.

## Next Steps
Ordered; none blocking.
1. **Write the implementation plan** for the v2 spec (writing-plans skill). It is
   NOT to be split (13 KB << 32 KB gate; cohesive; core-plus-dependents). Plan =
   ~3 TDD tasks in one spec:
   - **Task 1 (core):** `schema_name` param on `claude_json_attempt` /
     `run_claude_json`; new `spec2pr_schema <name>` helper (case → JSON for
     implement/forecast/classify); on success normalize
     `.result = .structured_output` via one `jq`. Files:
     `scripts/lib/spec2pr-runtime.sh` (~482-531). + tests.
   - **Task 2:** pass schema names at the three call sites — implement
     (`scripts/spec2pr.sh` ~748), forecast (`forecast_claude_attempt` ~1388),
     classify (`scripts/lib/pr-review-engine.sh` ~163). Assert flag present for
     these, absent for plan/pr-review/fix; normalization end-to-end.
   - **Task 3:** `punts-enrich.sh` (~72) `--json-schema` + inline array schema +
     local `.structured_output` normalization; `check-deps.sh` non-fatal
     `claude >= 2.1.187` advisory. + tests.
   - Tests: `tests/spec2pr/` stub-driven; `stub-claude.sh` must accept
     `--json-schema <file>` and emit `.structured_output`.
2. **Deliver v2** via either dogfood spec2pr with **codex** (spec already on
   origin/main; `cd ~/barevibe-ETL`-style, but this repo is
   `alkulinich/rulez-claudeset` — run from a clone) or manual writing-plans +
   subagent-driven-development → PR (how #29 shipped).
3. **(User-triggered, still open) leaseweb codex retry** on the dogfood box
   (`rulez@dogfood`, `~/barevibe-ETL`): `spec2pr.sh docs/.../2026-07-01-leaseweb-
   bundle-first-base-recovery-design.md` (default codex; immune). Won't exercise
   the claude fixes.
4. **Deferred:** `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` lever; VERSION/UPGRADE
   bump when v2 ships (minor, backward-compatible, opt-in-per-call).

## Key Decisions
- **`--json-schema` enforces SHAPE only; the `*_valid` validators STAY** as the
  semantic gate (sha matching, forecast arithmetic, exact-key sets — not
  expressible in JSON Schema). The schema just stops prose-instead-of-JSON.
- **Opt-in per call via `schema_name`, never tag-inferred** — a prose call can
  never be schema-bound by accident.
- **One normalization line, zero extraction-site edits.** Downstream parsers
  already handle an object-valued `.result` (`if (.result|type)=="object" …`),
  so setting `.result = .structured_output` in `claude_json_attempt` needs no
  other changes.
- **Scope = all four structured calls** (incl. punts-enrich); prose calls
  untouched. **Compat = assume support + floor claude ≥ 2.1.187 + check-deps
  advisory** (user's explicit choices via AskUserQuestion).
- **Do NOT split the v2 spec** (size + cohesion). Decompose at plan level.
- **Merged implement fix stays** — ceiling=0 + timeout solve the subagent-WAIT
  problem, orthogonal to output shape; both changes are complementary.
- **codex is the safe implementer** for dogfooding this fix (single schema-bound
  agent, no fan-out).
- **Commit trailer = co-author line only**
  (`Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`).
