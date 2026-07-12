# Cycle — launch a review/fix watcher

Assemble one of the six review/fix watcher prompts and start it as a recurring
`loop` or `goal`. Reviewer and fixer are separate agents — this starts **one**
watcher, not the pair.

## Usage

`/rulez:cycle <reviewer|fixer> <loop|goal> <spec|plan|PR> <target(s)>`

- `spec  <spec.md>`
- `plan  <plan.md> [<spec.md>]`  (spec derived from the plan path if omitted)
- `PR    <#n | n>`

Examples:
- `/rulez:cycle reviewer loop spec docs/superpowers/specs/2026-07-12-foo-design.md`
- `/rulez:cycle fixer goal plan docs/superpowers/plans/2026-07-12-foo-design-plan.md`
- `/rulez:cycle reviewer loop PR 87`

## Instructions

0. **Track command:** `~/.claude/skills/rulez-claudeset/scripts/set-current-command.sh cycle`

1. **Parse** the argument list as `<role> <mode> <type> <target…>`. If there are
   fewer than four words, or `role`/`mode`/`type` are not among the allowed
   values, show the Usage block and stop.

2. **Build the prompt.** Run, capturing stdout:
   `bash ~/.claude/skills/rulez-claudeset/scripts/cycle-prompt.sh <role> <mode> <type> <target…>`
   If the script exits nonzero, show its stderr and stop.

3. **Auto-start the watcher.** Invoke the `<mode>` skill (the literal `loop` or
   `goal` the user passed) via the Skill tool, passing the captured stdout as
   its prompt argument. That turns this agent into the watcher; do **not** also
   run the protocol yourself.

4. Tell the user which watcher started (role / mode / type / target) and that it
   runs until its stop condition. Stop.
