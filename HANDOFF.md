# Handoff

## Task
Split spec2pr's PR-review loop into a standalone tool that can review **any**
GitHub PR (not just spec2pr-generated ones), reusing the same review→fix→repeat
engine via a shared library rather than a copy-paste fork.

## Current State
- All work is **merged to `main`** (`e15ad64`, squash of PR #4). Working tree is
  clean (only untracked `tmp/` and `docs/research-auto-handoff-at-context-threshold.md`).
- Full suite green: `bash tests/spec2pr/run-tests.sh` → **222 passed, 0 failed**.
  punts (34) and codex (19) suites also green.
- Shipped on `main`:
  - `scripts/lib/spec2pr-runtime.sh` — shared lifecycle (`status`/`finish`/`halt`/
    `split`/`dirty`/`on_exit`), verbose helpers, utils, codex/claude model layer
    (`codex_call`/`validate_codex_output`/`claude_json_attempt`/`run_claude_json`/
    `extract_json_object`/`changed_paths`), `write_schemas`, and a shared
    race-safe `acquire_lock`. Adds lazy `CONTRACT_PREFIX` (default `SPEC2PR`).
  - `scripts/lib/pr-review-engine.sh` — `pr_review_engine_run` (diff-gate →
    review → classify → fix → commit/push → DONE/DIRTY). Knobs: `REVIEW_RUN_DESC`,
    `COMMIT_PREFIX`, `DONE_COMMENT_HEADER`, `PUSH_REFSPEC`, optional spec/plan
    sentence — all defaulted to spec2pr's current values.
  - `scripts/spec2pr.sh` — sources both libs; tail is just `pr_review_engine_run`.
    480 → 344 lines, byte-identical behavior.
  - `scripts/review-pr.sh <pr-number|pr-url>` — standalone tool. `PRREVIEW`
    contract lines.
  - `tests/spec2pr/test-review-pr.sh` (8 tests) + `stub-gh.sh` `pr view` case.
- **Not yet deployed** to the dogfood server `rulez@5.9.78.28` (still on branch
  `feat/spec2pr-cross-review`).

## What Worked
- Extraction done in two behavior-preserving phases, each gated by the spec2pr
  suite staying green (baseline was 195, not the stale "188" from an earlier
  branch). Final tree = 222 after adding review-pr tests.
- `review-pr.sh` flow: `require_*` deps → `gh pr view --json
  number,url,headRefName,headRefOid,baseRefName,isCrossRepository` → fork HALT →
  `acquire_lock` → fetch head+base → fresh throwaway worktree at the PR head on a
  local `reviewpr/<head>-pr-<n>` branch → `BASE_SHA = merge-base(origin/base, HEAD)`
  → `write_schemas` → `pr_review_engine_run`. Fixes push to the PR head ref via
  `PUSH_REFSPEC="HEAD:refs/heads/<headRefName>"`. A pre-existing unregistered
  worktree dir is `rm -rf`'d (covered by a test) since the lock guarantees no
  live owner.
- macOS bash 3.2 safety: lowercasing in `acquire_lock` uses `tr`, not `${x,,}`.
- Tests reuse the existing harness (autodiscovery, `stub-claude`/`stub-codex`/
  `stub-gh`, and `queue_clean_pr_review`/`queue_dirty_pr_review` from
  test-pipeline.sh). `make_pr_sandbox` builds an origin with a pushed head branch
  and writes canned `gh pr view` JSON whose `headRefOid` = the branch tip.

## What Didn't Work
- Adding `# shellcheck source=lib/...` directives made shellcheck noisier (it
  then flagged the libs' own intentional env-default vars as SC2034), so they
  were reverted. shellcheck is **not** a CI gate here; remaining SC1091/SC2034
  are inherent false positives from dynamic `source "$(dirname "$0")/..."`.
- My first `Write` of `spec2pr.sh` dropped its exec bit (755→644); fixed with
  `chmod 755` + `git commit --amend`. Watch for this when rewriting scripts.

## Next Steps
1. **Deploy to the dogfood box** `rulez@5.9.78.28`: its `~/rulez-claudeset` is on
   `feat/spec2pr-cross-review`, so a plain `git pull` won't fast-forward — needs
   a checkout/merge of `main`. Then `review-pr.sh` + `SPEC2PR_VERBOSE` are live.
2. **Manual smoke** there: `SPEC2PR_VERBOSE=1 bash scripts/review-pr.sh <pr-url>`
   on a small throwaway PR — confirm fetch→worktree, per-round findings printed,
   a fix commit pushed to the head branch, ending on `PRREVIEW DONE`.
3. **Optional** `/rulez:review-pr` command wrapper (`commands/rulez/review-pr.md`)
   so it's invokable from a session — deliberately deferred (script-first v1).

## Key Decisions
- **Shared library, not a fork** — explicit user choice. Rationale: we just paid
  for divergence (the stale-lock fix stranded on a branch + `MAX_FIX_ROUNDS=3`
  regression). One engine, two thin frontends.
- **Reused the `SPEC2PR_*` env namespace + home dir** for review-pr (one config
  for the family); distinguished only by `CONTRACT_PREFIX=PRREVIEW`.
- **Fork PRs HALT in v1** — fixes push to the PR head branch, which a fork
  doesn't allow.
- **`PUSH_REFSPEC` knob** lets review-pr push a throwaway local branch back to
  the PR's real head ref without the engine assuming `local branch == remote ref`
  (true for spec2pr, not here).
- Do **not** edit `docs/superpowers/specs/2026-06-11-spec2pr-design.md` (resume
  SHA guard for the merged dogfood source).
