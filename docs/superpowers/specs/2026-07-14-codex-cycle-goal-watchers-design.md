# Codex cycle goal watchers

## Context

PR #34 added `/rulez:cycle` for Claude. It builds one of six tuned watcher
prompts from the cross-product of `{reviewer, fixer}` and `{spec, plan, PR}`,
then launches the prompt with either Claude's `loop` or `goal` primitive.

Codex has persisted goals with automatic continuation, but no corresponding
`loop` primitive. The Codex adapter currently exposes Rulez workflows through
the `rulez-tools` skill and does not expose the cycle watchers.

This change adds a Codex-native cycle workflow. It reuses the existing prompt
builder and always selects its `goal` form. The six prompt templates and their
findings channels remain shared with Claude.

## Settled decisions

- Codex invocation:

  ```text
  use rulez-tools to cycle <reviewer|fixer> <spec|plan|PR> <target(s)>
  ```

- Codex does not accept a `mode` selector. Goal mode is implicit.
- One invocation starts one watcher in the current Codex task. Reviewer and
  fixer watchers run in separate tasks.
- The existing six templates remain verbatim and have one source of truth in
  `scripts/cycle-prompt.sh`.
- The Codex adapter invokes the shared builder as
  `cycle-prompt.sh <role> goal <type> <target(s)>`.
- An unfinished goal already attached to the task blocks launch. The workflow
  does not edit, clear, merge with, or replace that goal.
- A completed prior goal may be replaced by the new watcher goal.
- A rendered objective longer than Codex's 4,000-character limit is rejected
  before launch.
- `VERSION` and `UPGRADE.md` remain unchanged. Version bumps are deferred to a
  dedicated release step under the repository convention.

## Public interface

The Codex skill recognizes these forms:

```text
use rulez-tools to cycle reviewer spec docs/superpowers/specs/foo-design.md
use rulez-tools to cycle fixer plan docs/superpowers/plans/foo-design-plan.md
use rulez-tools to cycle reviewer PR 34
```

The target grammar stays identical to the shared builder after removal of the
mode argument:

- `spec <spec.md>`
- `plan <plan.md> [<spec.md>]`
- `PR <#n|n>`

Plan-to-spec derivation, findings-file derivation, PR-number normalization, and
all selector validation remain the builder's responsibility. The Codex skill
does not duplicate them.

## Architecture

### Shared prompt builder

`scripts/cycle-prompt.sh` remains the only owner of the six watcher templates.
Its existing `goal` wrapper already supplies Codex-compatible recurrence,
termination, and idle wording:

- recurrence: `Watch (re-read at least every 2 min)`
- termination: `complete the goal and notify`
- idle: `wait 2 min without writing anything`

The builder remains hermetic. It performs string validation and substitution
without reading git state, calling GitHub, or launching a goal.

### Codex adapter

`adapters/codex/skills/rulez-tools/SKILL.md` gains a `cycle` command mapping and
a detailed Cycle Watcher workflow. The skill resolves `RULEZ_HOME` through its
existing repository-location rules, calls the shared builder with the literal
mode `goal`, and passes the complete rendered stdout to Codex's `create_goal`
tool.

The skill is the launcher only. It does not review artifacts, process findings,
sleep, poll, or emulate recurrence before the goal starts. Codex automatic
continuation and the rendered template control the running watcher.

No cloned Codex prompt file or wrapper script is introduced.

## Launch flow

1. Parse the invocation as `<role> <type> <target(s)>`. If required arguments
   are missing or the role/type selector is invalid, print the Codex usage and
   stop without changing goal state.
2. Call `get_goal` for the current task.
3. If the task has an unfinished goal, refuse to launch. Tell the user to use a
   fresh task or clear the current goal. Paused and blocked goals count as
   unfinished for this preflight.
4. Resolve `RULEZ_HOME` and run:

   ```text
   bash "$RULEZ_HOME/scripts/cycle-prompt.sh" <role> goal <type> <target(s)>
   ```

   Preserve every target as a separate shell argument.
5. If the builder exits nonzero, surface its stderr and stop. Do not call
   `create_goal`.
6. Count the rendered objective's characters. If it exceeds 4,000 characters,
   report the limit error and stop without creating a goal.
7. Call `create_goal` once with the complete rendered prompt as `objective`.
   Do not fall back to an ordinary one-turn prompt if the tool is missing or
   rejects the request.
8. Report the launched role, artifact type, and target. State that the watcher
   runs as the current task's persistent goal until its template stop condition
   is met.

## Goal lifecycle

The workflow uses Codex's existing task-level goal state:

- no current goal: create the watcher goal;
- completed current goal: replace it with the watcher goal;
- active, paused, or blocked unfinished goal: refuse without mutation;
- goal-tool error: report launch failure and leave the current state as returned
  by Codex.

The watcher template decides when the work is complete. The launcher must not
mark the goal complete itself. It must not retry `create_goal`, clear another
goal, or combine watcher instructions with an existing objective.

## Error handling

- Invalid Codex syntax prints the shorter Codex usage, which omits
  `loop|goal`.
- Builder validation errors remain authoritative and are relayed without
  paraphrasing.
- An occupied task produces a distinct refusal before the builder runs.
- An oversized prompt reports its actual character count and the 4,000-character
  maximum.
- An unavailable or failed goal tool is a hard launch failure. The skill does
  not claim that a watcher started.
- All pre-launch failures leave artifacts, findings channels, and goal state
  unchanged.

## Affected files

- Modify `adapters/codex/skills/rulez-tools/SKILL.md`:
  - add cycle to its description and trigger list;
  - add the public Codex invocation to Command Mapping;
  - add the Cycle Watcher workflow with preflight, builder, size, launch, and
    reporting rules.
- Modify `README.md`:
  - add Codex cycle examples;
  - add cycle watchers to the Codex adapter capability list;
  - document implicit goal mode and one watcher per task.
- Modify `tests/codex/test-setup-codex.sh`:
  - verify the installed skill documents the shorter syntax;
  - verify it checks `get_goal`, delegates with literal `goal`, and calls
    `create_goal`;
  - verify occupied-goal, builder-error, and objective-size behavior is part of
    the skill contract.
- Modify `tests/cycle/test-cycle-prompt.sh`:
  - render all six role/artifact pairs in goal mode using representative paths;
  - verify every render succeeds and stays within 4,000 characters.

`scripts/cycle-prompt.sh`, `commands/rulez/cycle.md`, installer behavior,
`VERSION`, and `UPGRADE.md` are unchanged.

## Testing and verification

Run:

```bash
bash -n scripts/cycle-prompt.sh bin/setup-codex
bash tests/cycle/run-tests.sh
bash tests/codex/run-tests.sh
```

The cycle suite proves the existing shared builder can render every Codex goal
variant within the product limit for normal targets. The Codex suite treats the
skill text as the adapter contract and verifies that installation still exposes
the updated skill. Existing Claude cycle tests prove its launcher and loop forms
remain unchanged.

Manual smoke verification uses a fresh Codex task:

1. Invoke a reviewer cycle with a test spec path.
2. Confirm the task displays one active goal whose objective is the rendered
   reviewer/spec goal prompt.
3. In a different task with an active goal, invoke the same cycle and confirm it
   refuses without replacing the goal.

## Out of scope

- Launching reviewer and fixer together.
- Adding a Codex `loop` emulation.
- Copying or retuning any watcher template for Codex.
- Changing findings files, PR-comment protocols, polling cadence, or
  idempotency guards.
- Automatically opening a new Codex task.
- Clearing, editing, or merging with an unfinished goal.
- Changing the Claude `/rulez:cycle` interface.
- Releasing a new Rulez version.
