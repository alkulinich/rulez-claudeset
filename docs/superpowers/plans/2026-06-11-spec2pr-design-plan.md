# spec2pr Design Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` or `superpowers:executing-plans` to implement this plan task-by-task. Track progress by changing each checkbox from `- [ ]` to `- [x]` as it is completed.

**Goal:** Implement `spec2pr`, a single unattended bash pipeline that takes a `superpowers:brainstorming` spec and drives it through spec review, plan creation, plan review, implementation, cross-model PR review, and an open PR ready for human review.

**Source spec:** `docs/superpowers/specs/2026-06-11-spec2pr-design.md`

**Core architecture:** One sequential bash orchestrator at `scripts/spec2pr.sh`. It owns preflight, worktree creation, prompt rendering, schema files, codex/claude invocation, review loops, resume checks, PR creation, status logging, and exit-contract printing. A thin slash command at `commands/rulez/spec2pr.md` launches the script in the background and supports status inspection.

**Implementation posture:** Build this with tests first where practical, but keep the runtime plain and small. Do not introduce the old `feat/auto-pipeline` workflow runtime, helper layer, state machine, subagents, or LLM-interpreted shim.

## File Structure

- Create or update `scripts/spec2pr.sh` - all orchestration logic and embedded prompt/schema templates.
- Create or update `commands/rulez/spec2pr.md` - slash command wrapper and status behavior.
- Update `settings.json` - permission entries required for the slash command background launch.
- Create or update `tests/spec2pr/` - stubbed no-network integration tests for the pipeline.
- Create or update `docs/superpowers/smoke-tests/2026-06-11-spec2pr-e2e.md` - manual real-codex/real-claude/real-gh smoke test.

## Task 1: Build the Stubbed Test Harness

**Files:**
- `tests/spec2pr/run-tests.sh`
- `tests/spec2pr/helpers.sh`
- `tests/spec2pr/stub-codex.sh`
- `tests/spec2pr/stub-claude.sh`
- `tests/spec2pr/stub-gh.sh`

- [ ] Add a `run-tests.sh` runner following the existing shell test convention in `tests/punts/` and `tests/what-have-i-done/`.
- [ ] Add helpers that create an isolated scratch git repo, a bare file-based `origin`, a toy spec under `docs/superpowers/specs/`, isolated `SPEC2PR_HOME`, isolated worktree root, and stub binaries on `PATH`.
- [ ] Add `stub-codex.sh` that accepts `codex exec --cd --output-schema --output-last-message`, saves stdin prompts for assertions, replays queued fixture scripts, writes the fixture output to the requested last-message path, and exits with the fixture status.
- [ ] Add `stub-claude.sh` that accepts `claude -p --output-format json --dangerously-skip-permissions`, saves stdin prompts, replays queued JSON-envelope fixture output, and supports fixtures that intentionally edit the worktree for negative tests.
- [ ] Add `stub-gh.sh` that records invocations and supports `pr list`, `pr create`, and `pr comment` with canned success and failure modes.
- [ ] Add assertions for exit code, final stdout line, file existence, committed changes, invocation count/order, status file tail, and prompt contents.

## Task 2: Implement Preflight, Identity, Locking, and Import

**Files:**
- `scripts/spec2pr.sh`
- `tests/spec2pr/test-preflight.sh`

- [ ] Start `scripts/spec2pr.sh` with `set -euo pipefail`, a `current_stage` variable, and a single `EXIT` trap that prints and appends a `SPEC2PR HALT <stage>: unexpected exit` line if no contract line was printed, preserving the final-stdout-line contract even on unexpected exits.
- [ ] Accept exactly one spec path. Reject missing args, extra args, missing files, files outside a git repository, and paths that cannot be resolved relative to the source repo root.
- [ ] Resolve the source repo root, the spec-relative path, `raw_slug`, `raw_repo`, normalized `slug`, normalized `repo`, `id=<repo>-<slug>`, branch `spec2pr/<slug>`, worktree path, metadata dir, status file, and log dir.
- [ ] Support env overrides: `SPEC2PR_HOME`, `SPEC2PR_WORKTREES`, `SPEC2PR_CODEX_BIN`, `SPEC2PR_CLAUDE_BIN`, `SPEC2PR_MAX_SPEC`, `SPEC2PR_MAX_PLAN`, and `SPEC2PR_MAX_DIFF`.
- [ ] Set the spec's default size gates exactly when overrides are absent: `SPEC2PR_MAX_SPEC=32768`, `SPEC2PR_MAX_PLAN=65536`, and `SPEC2PR_MAX_DIFF=131072`.
- [ ] Preflight `git`, `jq`, `gh`, `codex`, and `claude` using the binary override variables where applicable.
- [ ] Enforce the spec size gate before any branch or worktree mutation. On failure, print and record `SPEC2PR SPLIT spec size=<n> limit=<n>` and exit 2.
- [ ] Fetch `origin main`, resolve `base_sha=$(git rev-parse origin/main)`, and create or reuse branch `spec2pr/<slug>` and worktree `~/.worktrees/<id>/` from that exact base.
- [ ] Add atomic locking with `mkdir ~/.spec2pr/<id>.lock`, a PID file, and cleanup only by the owning process. A concurrent invocation for the same id exits with `SPEC2PR HALT preflight: already running`.
- [ ] Add a source hash helper for `source-sha256` that uses `shasum -a 256` when available and falls back to `sha256sum`; halt clearly if neither exists.
- [ ] On first import, write metadata files `source-path`, `source-sha256`, and `base-sha` under `~/.spec2pr/<id>/`. On resume, halt if the source path or source hash does not match.
- [ ] Copy the spec into the worktree at the same relative path and commit only that copied spec as `spec2pr: import spec`. Use an empty commit only if the source spec is already identical to a tracked file on the base branch and a commit is still needed to mark import.
- [ ] Add tests for missing dependencies, default and overridden size gates, split spec, slug normalization, identity metadata, source hash helper selection on the host, path/hash mismatch, lock behavior, worktree creation, import commit, and resume reuse.

## Task 3: Add Shared Codex Execution and Schemas

**Files:**
- `scripts/spec2pr.sh`
- `tests/spec2pr/test-stages.sh`

- [ ] Create a private temporary directory at startup for JSON schema files and remove it on exit.
- [ ] Write all codex schemas as heredocs with `additionalProperties: false` at every object level.
- [ ] Include schemas for review, plan, implement, and PR-fix:
  - review: `blockers_found`, `majors_found`, `findings`, `notes`
  - plan: `plan_path`, `summary`
  - implement: `status`, `summary`, `blocked_reason`
  - PR-fix: `summary`
- [ ] Add a `run_codex` helper that invokes `codex exec --cd <worktree> --output-schema <schema> --output-last-message <logfile>` with the rendered prompt on stdin and stderr captured to the per-stage log path.
- [ ] Validate codex output files with `jq` after each run and halt with a stage-specific message if codex exits non-zero, writes invalid JSON, or violates the expected schema contract.
- [ ] Add tests that verify stdin prompt delivery, schema path usage, output-last-message path usage, stderr capture, non-zero codex halt behavior, and malformed output halt behavior.

## Task 4: Implement the Shared Spec/Plan Review Loop

**Files:**
- `scripts/spec2pr.sh`
- `tests/spec2pr/test-review-loop.sh`

- [ ] Add one prompt template for codex self-review loops. It must ask codex to review the artifact in fresh context, list blocker/major findings with severity and evidence, and then fix blockers and majors.
- [ ] Implement the shared loop for `spec-review` and `plan-review`, capped at 3 review calls per invocation.
- [ ] Validate that `blockers_found` and `majors_found` match the returned finding list by severity.
- [ ] Commit dirty rounds as `spec2pr: <stage> review fixes r<N>`.
- [ ] Exit a loop cleanly only when a round reports zero blockers and zero majors before fixing anything.
- [ ] Halt if a clean round leaves a dirty worktree, because a clean review must not also modify files.
- [ ] On round 3 with findings, commit any resulting fixes, print `SPEC2PR DIRTY <stage> blockers=<n> majors=<n> log=<path>`, and exit 3.
- [ ] Write status lines for each review round, including blockers/majors counts and `clean` on clean exit.
- [ ] Add tests for clean first round, dirty then clean, cap-hit dirty, count mismatch, clean-round dirty tree violation, and rerun convergence.

## Task 5: Implement Plan Creation

**Files:**
- `scripts/spec2pr.sh`
- `tests/spec2pr/test-stages.sh`

- [ ] Add the plan prompt using `$superpowers:writing-plans` wording and require codex to create exactly `docs/superpowers/plans/<slug>-plan.md` in the worktree.
- [ ] Validate that returned `plan_path` exactly equals the deterministic plan path.
- [ ] Verify that plan creation changed no files except the expected plan file.
- [ ] Enforce the plan size gate after creation. On failure, print and record `SPEC2PR SPLIT plan size=<n> limit=<n>` and exit 2.
- [ ] Commit the plan as `spec2pr: write plan`.
- [ ] On resume, skip plan creation when the deterministic in-worktree plan path already exists; ignore other files in `docs/superpowers/plans/`.
- [ ] Add tests for happy-path plan creation, wrong plan path, extra-file mutation, plan split gate, commit message, and resume skip.

## Task 6: Implement the Implementation Stage and Resume Guard

**Files:**
- `scripts/spec2pr.sh`
- `tests/spec2pr/test-stages.sh`

- [ ] Add the implementation prompt using `$superpowers:subagent-driven-development` wording and pass the reviewed spec and reviewed plan paths.
- [ ] Let codex commit as it goes, but require a `done` result to leave `git status --porcelain` empty. If not empty, halt with `SPEC2PR HALT implement: uncommitted changes after done`.
- [ ] If codex returns `blocked`, halt with `SPEC2PR HALT implement: <blocked_reason>`.
- [ ] After a successful implementation, write `implementation-base`, `implementation-head`, and an `implementation-ok` checksum record under `~/.spec2pr/<id>/`.
- [ ] Push the branch from the script after implementation succeeds.
- [ ] Before creating a PR, check for an existing open PR with `gh pr list --head`. If one exists, reuse it.
- [ ] If no PR exists, create one with `gh pr create`; title is derived from the slug, body links the spec and plan paths.
- [ ] Implement resume rules:
  - Skip implementation only when an open PR or remote branch exists and the current head is the recorded implementation head or only known PR-review fix commits are on top.
  - Halt when spec-review or plan-review commits appear after the recorded implementation.
  - Halt when unknown commits appear after the recorded implementation.
- [ ] Add tests for done with clean tree, done with dirty tree, blocked result, push and PR create, PR create failure, existing PR reuse, remote-branch resume, stale implementation after review fixes, and unknown commits after implementation.

## Task 7: Implement PR Diff Gate and Cross-Model PR Review

**Files:**
- `scripts/spec2pr.sh`
- `tests/spec2pr/test-pipeline.sh`

- [ ] Compute the PR-review diff from the immutable metadata base with `git diff "$base_sha"...HEAD`.
- [ ] Enforce the diff size gate before the PR-review loop. On failure, print and record `SPEC2PR SPLIT diff size=<n> limit=<n>` and exit 2.
- [ ] Add `run_claude_json` for `claude -p --output-format json --dangerously-skip-permissions`, with prompts on stdin and stderr captured per round.
- [ ] Implement the PR review call. It feeds Claude the immutable-base diff and asks for fresh-eyes review only; Claude must not edit files.
- [ ] Extract `.result` from Claude's JSON envelope into `pr-review-r<N>.review`.
- [ ] Halt with `SPEC2PR HALT pr-review: reviewer modified worktree` if the review call changes the tree.
- [ ] Implement the classify call. It receives the review file and returns `{blockers_found, majors_found}`. Because Claude has no schema enforcement, parse JSON tolerantly, validate with `jq`, retry malformed output once, and halt on a second malformed reply.
- [ ] Halt with `SPEC2PR HALT pr-review: classifier modified worktree` if the classify call changes the tree.
- [ ] If classify returns zero blockers and zero majors, exit the loop cleanly without a fix or commit.
- [ ] Otherwise invoke codex with the PR-fix schema and the review findings embedded in the prompt, then commit fixes as `spec2pr: pr-review review fixes r<N>` and push.
- [ ] Cap at 3 review calls per invocation. On round 3 with findings, commit any resulting fixes, print `SPEC2PR DIRTY pr-review blockers=<n> majors=<n> log=<path>`, and exit 3.
- [ ] Record each PR-review round in status and write the codex fix summary to `pr-review-r<N>.fix`.
- [ ] Add tests for clean PR review, dirty then clean, cap-hit dirty, diff split gate, reviewer edits tree, classifier edits tree, malformed classify retry, malformed classify halt, fix prompt includes the Claude review text, and push after PR-review fixes.

## Task 8: Finish Status, Exit Contract, and DONE Behavior

**Files:**
- `scripts/spec2pr.sh`
- `tests/spec2pr/test-pipeline.sh`

- [ ] Centralize contract-line printing so every terminal outcome is both appended to the status file and printed as the final stdout line.
- [ ] Ensure final lines and exit codes match the spec exactly:
  - `SPEC2PR DONE pr=<url> worktree=<path>` exits 0
  - `SPEC2PR SPLIT <spec|plan|diff> size=<n> limit=<n>` exits 2
  - `SPEC2PR DIRTY <stage> blockers=<n> majors=<n> log=<path>` exits 3
  - `SPEC2PR HALT <stage>: <reason>` exits 1
- [ ] Keep logs under `~/.spec2pr/<id>/`, overwritten by stage/round on rerun, and keep `~/.spec2pr/<id>.status` append-only.
- [ ] On clean PR-review exit, post one best-effort `gh pr comment` containing review rounds, final counts, and log path.
- [ ] Treat PR comment failure as non-fatal: record it in status but still print `DONE`.
- [ ] Print the worktree path in the `DONE` line and leave the worktree in place for human pre-merge testing.
- [ ] Add full-pipeline happy path tests and tests that stdout and the status file always end with the final contract line, including unexpected exits.

## Task 9: Add the Slash Command

**Files:**
- `commands/rulez/spec2pr.md`
- `settings.json`

- [ ] Add `/rulez:spec2pr <spec-path>` instructions that launch `scripts/spec2pr.sh <spec-path>` as a background Bash task and report that completion will arrive by notification.
- [ ] Add `/rulez:spec2pr status` instructions that print `tail -1` for every `~/.spec2pr/*.status`.
- [ ] Document how Claude should react to completion notifications:
  - `DONE`: offer to review the PR.
  - `SPLIT`: recommend splitting the spec.
  - `DIRTY` or `HALT`: show the log path or halt reason.
- [ ] Update `settings.json` with the minimum permission entry needed for the background launch to run without prompting.
- [ ] Verify the command text stays thin and does not duplicate orchestration logic from the script.

## Task 10: Add Manual Smoke Test Documentation

**Files:**
- `docs/superpowers/smoke-tests/2026-06-11-spec2pr-e2e.md`

- [ ] Document setup for a scratch GitHub repository with `origin/main`, `gh` auth, real `codex`, and real `claude -p`.
- [ ] Use a toy spec such as "add a `--version` flag" so the test exercises real implementation, review, PR creation, and PR comments without a large diff.
- [ ] Include checks for codex CLI schema behavior, `$superpowers:*` prompt expansion under `codex exec`, Claude JSON envelope shape, classifier parsing, no reviewer worktree edits, PR comment creation, status file tail, and final `DONE`.
- [ ] Explicitly state that this smoke test must run once before first real use, because stub tests do not validate external CLI contracts or GitHub auth.

## Task 11: Final Verification

**Files:**
- All implementation files above.

- [ ] Run `tests/spec2pr/run-tests.sh` and fix failures.
- [ ] Run the existing shell test suites to catch regressions outside `spec2pr`.
- [ ] Run `shellcheck` on `scripts/spec2pr.sh` and test stubs if available; if unavailable, do a manual bash review for quoting, `set -e` hazards, and pipeline exit handling.
- [ ] Verify `git status --short` contains only the intended implementation, command, settings, tests, and smoke-test files.
- [ ] Manually inspect `scripts/spec2pr.sh` against the spec's out-of-scope list and remove any accidental auto-merge, checkpoint, timeout, or non-main-base behavior.
- [ ] Confirm the runtime does not depend on anything from the abandoned `feat/auto-pipeline` design.

## Risk Notes

- The highest-risk code is resume logic around existing PRs and commits after implementation. Keep that logic explicit and test each branch with real git commits in the scratch repo.
- The second-highest-risk area is shell error handling. Centralize terminal outcomes and avoid hidden exits inside command substitutions where possible.
- Claude classification is intentionally weaker than codex schema enforcement. Keep the parse-and-retry helper small, logged, and thoroughly tested with malformed envelopes and prose-wrapped JSON.
- Worktree cleanliness is a safety contract. Check it after every reviewer/classifier call and after codex `done`.
