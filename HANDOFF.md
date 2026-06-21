# Handoff

## Task
Two threads this session:
1. **Brainstorm** adding a switch to run the spec2pr "implementer" and "fixer"
   roles on **deepseek-v4-flash via openmodel.ai** (a cheaper model), then
   decide go / no-go.
2. **Merge** the two spec2pr-authored PRs that had landed (PR #13 fixer-context,
   PR #14 plan-author-claude).

## Current State
- Branch: `main` (clean working tree apart from the three protected untracked
  paths below).
- **PR #13 merged** — review-pr fixer-context (feeds the fixer prior rounds'
  findings + fixes). Touched `scripts/lib/pr-review-engine.sh`,
  `tests/spec2pr/test-review-pr.sh`, plus its spec/plan docs.
- **PR #14 merged** — plan-author cross-model: **claude now authors the plan,
  codex reviews it** (`scripts/spec2pr.sh` `STAGE="plan"` block). Touched
  `scripts/spec2pr.sh` and four `tests/spec2pr/*.sh` files.
- Both features are live on `main`. Full suite green: **396 tests, 0 failed**.
- **No open issues, no open PRs.**
- The deepseek-flash idea was **dropped (no-go)** — see Key Decisions.

## What Worked
- **Research-before-build killed a bad idea cheaply.** Dispatched a web-research
  subagent on "deepseek-v4-flash: codex vs claude as harness." It surfaced
  hard blockers (below), so we never wrote code.
- **PR #13 merge:** clean via
  `~/.claude/skills/rulez-claudeset/scripts/git-merge-pr.sh 13 merge`.
- **PR #14 merge with conflict resolution:**
  - Only conflict was `tests/spec2pr/test-review-pr.sh` in
    `test_review_pr_cap_exits_dirty`.
  - Diagnosed all three versions (merge-base, PR#14 HEAD, main/PR#13).
    PR#13's unrolled per-round cap test is a **strict superset** of PR#14's
    intent (it already carried the `MAX_FIX_ROUNDS=3` prefix PR#14 added).
  - Resolved by keeping PR#13's version, dropping PR#14's stale loop `done`.
    Confirmed resolved function is byte-identical to main's; no markers left;
    `bash -n` clean.
  - Ran the **full suite (396 tests, 0 failed) before committing** the merge.
  - Merged via `git-merge-pr.sh 14 merge` (6 files, +619/-44).

## What Didn't Work
- **deepseek-v4-flash for implementer/fixer — not viable as designed:**
  - **Codex path blocked.** Codex CLI requires the OpenAI **Responses API**
    (since Feb 2026); openmodel.ai serves DeepSeek **only over the Anthropic
    Messages endpoint**. So `codex exec` cannot reach deepseek-flash through
    openmodel.ai without an OpenRouter/LiteLLM shim.
  - **Codex silently ignores `--output-schema` when tools/MCP are active**
    (open bug codex #15451) — exactly our case (tools + enforced JSON). The
    `codex_call` schema guarantee would vanish silently.
  - **Claude-as-harness is the only structural fit** (openmodel exposes DeepSeek
    over Anthropic Messages; reuse `run_claude_json`), but carries edit-format
    degradation on deepseek and the `reasoning_content` round-trip 400 bug
    (V4 thinking mode). Judged not worth it.
- Minor: `gh pr diff 14 --name-only` returns empty for a CONFLICTING PR; used
  `gh pr view 14 --json files` + `git merge-tree` instead.

## Next Steps
Nothing is queued — the board is empty. Optional / latent:
1. **Dogfood the plan-author-claude change.** Next spec2pr run will have claude
   author the plan and codex grade it cross-model. Watch the first real run for
   plan-stage halts (`planner did not write plan`, scope-guard).
2. **(Parked) cheap fixer only**, *if* revisited: the one defensible slice is
   the fixer (not implementer) via claude-CLI-pointed-at-deepseek
   (`ANTHROPIC_BASE_URL`), non-thinking mode, behind a default-off knob — and
   only after a standalone spike proving (a) no `reasoning_content` 400,
   (b) clean worktree edits, (c) usable `.result` summary. Implementer is a no
   (multi-file + must-commit, weakest tier, hard-halt failure modes).
3. **Prevent future parallel-PR conflicts:** both #13/#14 collided only in
   `tests/spec2pr/test-review-pr.sh`. Merging spec2pr PRs in order (or having
   the server rebase the queued PR after each merge) avoids it.

## Key Decisions
- **deepseek-flash: NO-GO.** Decided by the user after research. The codex route
  is blocked at the protocol layer, not just on quality. Documented here so it
  isn't re-litigated.
- **Conflict resolution = take the superset, not a hand-merge.** PR#13's cap
  test already contained PR#14's only delta, so "keep theirs for that function"
  was correct and lossless — verified by diffing against `origin/main` (empty
  diff) and running the full suite.
- **Validate before committing a merge.** Ran 396 tests on the merged working
  tree *before* creating the merge commit, so a red result would never reach
  `main`.

## Protected — DO NOT touch / commit
These untracked paths are intentionally excluded from all commits:
- `tmp/`
- `references/`
- `docs/research-auto-handoff-at-context-threshold.md`
