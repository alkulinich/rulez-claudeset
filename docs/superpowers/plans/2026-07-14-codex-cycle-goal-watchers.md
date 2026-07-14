# Codex Cycle Goal Watchers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose PR #34's six review/fix cycle watchers through the Codex `rulez-tools` skill as persistent goals with a shorter, goal-only invocation.

**Architecture:** Keep `scripts/cycle-prompt.sh` as the single owner of all watcher templates. The Codex skill validates the public selectors, refuses to replace an unfinished task goal, renders the shared builder's existing `goal` form, enforces Codex's 4,000-character objective limit, and calls `create_goal` once. README and shell contract tests document the new adapter surface without changing the Claude launcher or prompt builder.

**Tech Stack:** Markdown Codex skill instructions, Bash 3.2-compatible shell tests, existing `cycle-prompt.sh`, Codex `get_goal` and `create_goal` tools.

## Global Constraints

- Public Codex syntax is exactly `use rulez-tools to cycle <reviewer|fixer> <spec|plan|PR> <target(s)>`; it has no `mode` selector.
- Codex always invokes `scripts/cycle-prompt.sh <role> goal <type> <target(s)>`.
- Preserve all six existing prompt templates verbatim in `scripts/cycle-prompt.sh`; do not copy them into the Codex skill.
- One invocation starts one watcher in the current task; reviewer and fixer watchers remain separate tasks.
- Any unfinished goal, including an active, paused, or blocked goal, stops the launch without goal mutation.
- A completed prior goal may be replaced.
- Reject rendered objectives over 4,000 characters before calling `create_goal`.
- Do not clear, edit, merge with, or call `update_goal` on an existing goal from the launcher.
- Do not change `scripts/cycle-prompt.sh`, `commands/rulez/cycle.md`, installer behavior, `VERSION`, or `UPGRADE.md`.
- Leave unrelated untracked files untouched.

---

### Task 1: Add The Codex Cycle Goal Launcher

**Files:**
- Modify: `tests/cycle/test-cycle-prompt.sh:5-115`
- Modify: `tests/codex/test-setup-codex.sh:255-277`
- Modify: `adapters/codex/skills/rulez-tools/SKILL.md:3-111,205-209`

**Interfaces:**
- Consumes: `scripts/cycle-prompt.sh <reviewer|fixer> goal <spec|plan|PR> <target...>`; stdout is the complete goal objective, stderr is authoritative validation output, and exit `0` means success.
- Consumes: Codex `get_goal` with no arguments; no goal or status `complete` permits launch, every other returned status blocks launch.
- Produces: the natural-language skill invocation `use rulez-tools to cycle <reviewer|fixer> <spec|plan|PR> <target(s)>`.
- Produces: one `create_goal({objective: PROMPT})` call after successful preflight; no `token_budget` is supplied.

- [ ] **Step 1: Add a characterization test for all six Codex goal prompts**

Append this helper and test to `tests/cycle/test-cycle-prompt.sh` after the target constants and before the existing tests:

```bash
assert_codex_goal_prompt_fits() {
  local role="$1" type="$2"
  local prompt_chars within_limit="no"
  shift 2

  run_cycle "$role" goal "$type" "$@"
  assert_eq "0" "$CY_RC" "Codex $role/$type goal prompt: exit 0"

  prompt_chars="$(printf '%s' "$CY_OUT" | wc -m | tr -d '[:space:]')"
  if [ "$prompt_chars" -le 4000 ]; then
    within_limit="yes"
  fi
  assert_eq "yes" "$within_limit" "Codex $role/$type goal prompt: at most 4000 characters"
}

test_cycle_codex_goal_variants_fit_objective_limit() {
  assert_codex_goal_prompt_fits reviewer spec "$SPEC_TARGET"
  assert_codex_goal_prompt_fits fixer spec "$SPEC_TARGET"
  assert_codex_goal_prompt_fits reviewer plan "$PLAN_TARGET"
  assert_codex_goal_prompt_fits fixer plan "$PLAN_TARGET"
  assert_codex_goal_prompt_fits reviewer PR 87
  assert_codex_goal_prompt_fits fixer PR 87
}
```

- [ ] **Step 2: Run the cycle characterization test**

Run:

```bash
bash tests/cycle/run-tests.sh
```

Expected: PASS with `59 tests run, 0 failed`. This is a characterization test of the already-shared builder, so it must be green before the Codex launcher changes.

- [ ] **Step 3: Add the failing Codex skill contract test**

Append this test to `tests/codex/test-setup-codex.sh` after `test_rulez_tools_skill_documents_punts_workflows`:

```bash
test_rulez_tools_skill_documents_cycle_goal_workflow() {
  local skill_file skill_body skill_description
  skill_file="$REPO_ROOT/adapters/codex/skills/rulez-tools/SKILL.md"
  skill_body="$(cat "$skill_file")"
  skill_description="$(sed -n '3p' "$skill_file")"

  assert_contains "cycle goal watchers" "$skill_description" "skill description advertises cycle goal watchers"
  assert_contains "launching a cycle watcher" "$skill_body" "skill trigger list includes cycle watchers"
  assert_contains 'use rulez-tools to cycle <reviewer|fixer> <spec|plan|PR> <target(s)>' "$skill_body" "skill documents Codex cycle syntax"
  assert_not_contains 'use rulez-tools to cycle <reviewer|fixer> <loop|goal>' "$skill_body" "Codex cycle syntax omits mode"
  assert_contains 'Call `get_goal` before running the builder.' "$skill_body" "cycle preflights task goal"
  assert_contains 'status other than no goal or `complete`' "$skill_body" "cycle refuses unfinished goals"
  assert_contains 'cycle-prompt.sh" <role> goal <type> <target...>' "$skill_body" "cycle delegates with literal goal mode"
  assert_contains 'show its stderr unchanged' "$skill_body" "cycle preserves builder validation errors"
  assert_contains '4,000-character' "$skill_body" "cycle enforces Codex objective limit"
  assert_contains 'Call `create_goal` once' "$skill_body" "cycle launches one persisted goal"
  assert_contains 'Do not use `update_goal`' "$skill_body" "cycle never mutates existing goal state"
}
```

- [ ] **Step 4: Run the Codex suite to verify the new contract fails**

Run:

```bash
bash tests/codex/run-tests.sh
```

Expected: FAIL. The existing assertions remain green, while the new test reports missing cycle description, invocation, `get_goal`, builder, limit, and `create_goal` text.

- [ ] **Step 5: Extend the skill discovery text and shared-script list**

In `adapters/codex/skills/rulez-tools/SKILL.md`, replace the frontmatter description with:

```yaml
description: "Use for Rulez shared tooling in Codex: GitHub workflows, cycle goal watchers, handoffs, and punts backed by this repository's scripts."
```

Replace the opening trigger paragraph with:

```markdown
Use this skill when the user asks Codex to use `rulez-tools`, or asks for Rulez-style GitHub workflow tasks such as starting an issue, creating a PR, testing a PR, pushing fixes, merging a PR, launching a cycle watcher, writing a handoff, enriching punts, or triaging punts.
```

Add this bullet after the Handoff entry in `## Shared Scripts`:

```markdown
- Cycle prompt: `scripts/cycle-prompt.sh <reviewer|fixer> goal <spec|plan|PR> <target...>`
```

- [ ] **Step 6: Add the command mapping and complete Cycle Watcher workflow**

Insert this mapping after the handoff mapping and before the punts mappings:

```markdown
When the user says `use rulez-tools to cycle <reviewer|fixer> <spec|plan|PR> <target(s)>`:

1. Use the `Cycle Watcher` workflow below.
2. Report the launched role, artifact type, and target, or the blocking error.
```

Insert this section after `## Command Mapping` and all of its mappings, immediately before `## Punts Enrich`:

````markdown
## Cycle Watcher

Use this workflow when the user says `use rulez-tools to cycle <reviewer|fixer> <spec|plan|PR> <target(s)>`.

Codex always launches cycle watchers as persisted goals. The public Codex syntax has no `loop|goal` mode selector. One invocation starts one watcher in the current task; start reviewer and fixer watchers in separate tasks.

Enforce Codex's 4,000-character objective limit before creating a goal.

Target forms:

```text
spec <spec.md>
plan <plan.md> [<spec.md>]
PR <#n|n>
```

Workflow:

1. Parse the arguments as `<role> <type> <target(s)>`. Require `role` to be `reviewer` or `fixer`, `type` to be `spec`, `plan`, or `PR`, and at least one non-empty target. On failure, print `use rulez-tools to cycle <reviewer|fixer> <spec|plan|PR> <target(s)>` and stop without changing goal state. Leave the detailed target validation to the shared builder.
2. Call `get_goal` before running the builder. No current goal or a goal with status `complete` permits launch. Treat any status other than no goal or `complete`, including active, paused, or blocked, as an unfinished goal: stop and tell the user to use a fresh task or clear the current goal. Do not clear, edit, merge with, or replace it.
3. Resolve `RULEZ_HOME` using the repository-layout rule above. Run `bash "$RULEZ_HOME/scripts/cycle-prompt.sh" <role> goal <type> <target...>`, preserving each target as a separate shell argument and capturing stdout as `PROMPT`. If the builder exits nonzero, show its stderr unchanged and stop without calling `create_goal`.
4. Count the objective characters with `PROMPT_LENGTH="$(printf '%s' "$PROMPT" | wc -m | tr -d '[:space:]')"`. If `PROMPT_LENGTH` is greater than `4000`, report `Cycle goal is <PROMPT_LENGTH> characters; Codex allows at most 4,000.` and stop without creating a goal.
5. Call `create_goal` once with `objective` set to the complete `PROMPT`. Do not supply `token_budget`. If the tool is unavailable or rejects the request, report that the watcher did not start. Do not fall back to an ordinary prompt.
6. Report the launched role, artifact type, and target. State that it runs as this task's persistent goal until the template's stop condition is met. Do not run the watcher protocol, poll, sleep, or process a review round in the launcher itself.

Do not use `update_goal` from this launcher. The running goal owns its completion state.
````

Replace the `## First-Pass Scope` paragraph with:

```markdown
This skill currently covers GitHub workflow, cycle goal watchers, handoff, punts enrich, and punts triage workflows. It does not install or manage Codex hooks, statusline behavior, `what-have-i-done`, `.codex/punts/`, or Claude transcript/session storage.
```

- [ ] **Step 7: Run the focused suites and verify the launcher contract passes**

Run:

```bash
bash tests/cycle/run-tests.sh
bash tests/codex/run-tests.sh
```

Expected: both commands exit `0`; cycle reports `59 tests run, 0 failed`, and Codex setup reports `0 failed` with every new cycle assertion green.

- [ ] **Step 8: Commit the Codex launcher**

```bash
git add adapters/codex/skills/rulez-tools/SKILL.md tests/cycle/test-cycle-prompt.sh tests/codex/test-setup-codex.sh
git commit -m "feat: add Codex cycle goal watchers"
```

### Task 2: Document The Codex Cycle Interface

**Files:**
- Modify: `tests/codex/test-setup-codex.sh:255-end`
- Modify: `README.md:52-64,125-127`

**Interfaces:**
- Consumes: the Task 1 public invocation and one-watcher-per-task lifecycle.
- Produces: install-page examples and capability text that a Codex user can follow without reading the skill source.

- [ ] **Step 1: Add the failing README contract test**

Append this test to `tests/codex/test-setup-codex.sh`:

```bash
test_readme_documents_codex_cycle_goal_workflow() {
  local readme
  readme="$(cat "$REPO_ROOT/README.md")"

  assert_contains "use rulez-tools to cycle reviewer spec docs/superpowers/specs/foo-design.md" "$readme" "README shows Codex reviewer cycle invocation"
  assert_contains "use rulez-tools to cycle fixer PR 34" "$readme" "README shows Codex fixer cycle invocation"
  assert_contains 'Codex cycle syntax omits the Claude `mode` selector' "$readme" "README documents implicit goal mode"
  assert_contains "Reviewer and fixer watchers run in separate Codex tasks." "$readme" "README documents one watcher per task"
  assert_contains "cycle goal watchers" "$readme" "README capability list includes cycle watchers"
}
```

- [ ] **Step 2: Run the Codex suite to verify the README contract fails**

Run:

```bash
bash tests/codex/run-tests.sh
```

Expected: FAIL only in `test_readme_documents_codex_cycle_goal_workflow`; the Task 1 skill and installer tests remain green.

- [ ] **Step 3: Add Codex cycle examples and lifecycle guidance to README**

In the Codex example block at `README.md:54-60`, add:

```text
use rulez-tools to cycle reviewer spec docs/superpowers/specs/foo-design.md
use rulez-tools to cycle fixer PR 34
```

Replace the Codex capability paragraph at `README.md:62-64` with:

```markdown
The Codex adapter covers GitHub workflow, cycle goal watchers, handoff, punts enrich, and punts triage workflows. It reuses the existing `.claude/punts/` queue; Claude slash commands, settings, hooks, and statusline remain Claude-specific.

Codex cycle syntax omits the Claude `mode` selector and always starts a persistent goal in the current task. Reviewer and fixer watchers run in separate Codex tasks. If a task already has an unfinished goal, the launcher refuses instead of replacing it.
```

Replace the supported-workflows paragraph at `README.md:125-127` with:

```markdown
For Codex, use the `rulez-tools` skill instead of Claude slash commands. The supported Codex workflows are start issue, create PR, test PR, push fixes, merge PR, cycle goal watchers, handoff, punts enrich, and punts triage.
```

- [ ] **Step 4: Run syntax and focused verification**

Run:

```bash
bash -n scripts/cycle-prompt.sh bin/setup-codex tests/cycle/run-tests.sh tests/cycle/test-cycle-prompt.sh tests/codex/run-tests.sh tests/codex/test-setup-codex.sh
bash tests/cycle/run-tests.sh
bash tests/codex/run-tests.sh
git diff --check
```

Expected: every command exits `0`; cycle reports `59 tests run, 0 failed`; Codex setup reports `0 failed`; `git diff --check` prints nothing.

- [ ] **Step 5: Inspect the scoped diff**

Run:

```bash
git status --short
git diff --name-only c2b3496
git diff -- adapters/codex/skills/rulez-tools/SKILL.md tests/cycle/test-cycle-prompt.sh tests/codex/test-setup-codex.sh README.md
```

Expected: the current tracked worktree changes are only `README.md` and `tests/codex/test-setup-codex.sh` because Task 1 is already committed. The full name-only diff from the design commit contains the four implementation files plus this plan document, and no edits to `scripts/cycle-prompt.sh`, `commands/rulez/cycle.md`, `VERSION`, or `UPGRADE.md`. The pre-existing untracked files remain untouched.

- [ ] **Step 6: Commit the Codex documentation**

```bash
git add README.md tests/codex/test-setup-codex.sh
git commit -m "docs: explain Codex cycle goal workflow"
```

## Post-Implementation Smoke Verification

This acceptance check must use fresh Codex tasks; do not start a watcher goal inside the implementation task.

1. From the repository root, prepare a disposable target outside the worktree:

   ```bash
   cp docs/superpowers/specs/2026-07-14-codex-cycle-goal-watchers-design.md /tmp/rulez-cycle-smoke-design.md
   ```

2. In a fresh Codex task, enter:

   ```text
   use rulez-tools to cycle reviewer spec /tmp/rulez-cycle-smoke-design.md
   ```

   Expected: one active persisted goal whose objective is the reviewer/spec prompt rendered by `cycle-prompt.sh reviewer goal spec ...`.

3. In a different Codex task that already has an unfinished goal, enter the same invocation.

   Expected: the skill refuses, tells the user to use a fresh task or clear the existing goal, and does not replace that goal.

4. Launch the corresponding fixer in a third task:

   ```text
   use rulez-tools to cycle fixer spec /tmp/rulez-cycle-smoke-design.md
   ```

   Expected: the fixer runs as its own persisted goal, separate from the reviewer task.
