# Cycle — launch a review/fix watcher

Assemble one of the seven review/fix watcher prompts and start it as a recurring
`loop` or `goal`. Reviewer, verifier, and fixer are separate agents — this starts
**one** watcher, never a set.

The two reviewing roles ask different questions. `reviewer` is a code review —
*is this correct and well-built?* `verifier` ignores style and checks the PR
against the acceptance criteria stated in its body, then tries to break them; it
halts if the body states no criteria.

## Usage

`/rulez:cycle <reviewer|fixer|verifier> <loop|goal> <spec|plan|PR> <target(s)>`

- `spec  <spec.md>`
- `plan  <plan.md> [<spec.md>]`  (spec derived from the plan path if omitted)
- `PR    <#n | n>`

`verifier` supports **only** `PR` — verifying that criteria hold, and attacking
them, needs running code. `reviewer` and `fixer` support all three types.

Examples:
- `/rulez:cycle reviewer loop spec docs/superpowers/specs/2026-07-12-foo-design.md`
- `/rulez:cycle fixer goal plan docs/superpowers/plans/2026-07-12-foo-design-plan.md`
- `/rulez:cycle reviewer loop PR 87`
- `/rulez:cycle verifier loop PR 40`

A `reviewer` and a `verifier` may watch the same PR at once: they post to
separate channels (`## Review round <N>` and `## Verification round <N>`) and one
`fixer` consumes both.

## Instructions

0. **Track command:** `~/.claude/skills/rulez-claudeset/scripts/set-current-command.sh cycle`

1. **Parse** the argument list as `<role> <mode> <type> <target…>`. If there are
   fewer than four words, or `role`/`mode`/`type` are not among the allowed
   values, show the Usage block and stop. Also stop if `role` is `verifier` and
   `type` is not `PR` — say that `verifier` is PR-only rather than passing the
   combination to the builder.

2. **Build the prompt.** Run, capturing stdout:
   `bash ~/.claude/skills/rulez-claudeset/scripts/cycle-prompt.sh <role> <mode> <type> <target…>`
   If the script exits nonzero, show its stderr and stop.

3. **Auto-start the watcher.** Invoke the `<mode>` skill (the literal `loop` or
   `goal` the user passed) via the Skill tool, passing the captured stdout as
   its prompt argument. That turns this agent into the watcher; do **not** also
   run the protocol yourself.

4. Tell the user which watcher started (role / mode / type / target) and that it
   runs until its stop condition. Stop.
