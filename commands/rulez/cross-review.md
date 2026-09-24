# Cross-review — Claude watcher + Codex CLI one-shot peer

Run a PR review/fix cycle across two models when the peer is **Codex CLI**, which
cannot run a durable watcher. Claude runs its role as a normal `/rulez:cycle`
watcher; Codex runs the complementary role as one round per launch, detached in
tmux session `codex-<N>`. Comment channels are unchanged, so the PR record looks
like a normal two-watcher cycle.

## Usage

`/rulez:cross-review <reviewer|fixer|verifier> <loop|goal> PR <#n | n> [peer-role]`

The first word is **Claude's** role. The peer role defaults to the complement:
Claude `fixer` → Codex `verifier`; Claude `reviewer`/`verifier` → Codex `fixer`.
Pass `peer-role` to override (e.g. Claude `fixer`, Codex `reviewer`).

Project guards (env to source, forbidden commands, owner decisions not to
re-raise) go in `.claude/cross-review-guards.md`; they are appended to every
peer prompt. Requires `tmux` and `codex` on PATH.

Codex **desktop** can run durable watchers — use `/rulez:cycle` on both sides there.

## Instructions

0. **Track command:** `~/.claude/skills/rulez-claudeset/scripts/set-current-command.sh cross-review`

1. **Parse** `<role> <mode> PR <n> [peer-role]`. Show Usage and stop if the
   third word is not `PR`, `role`/`peer-role` is not reviewer|fixer|verifier,
   `mode` is not loop|goal, or role equals peer-role. Default `peer-role` as above.

2. **Build Claude's prompt:**
   `bash ~/.claude/skills/rulez-claudeset/scripts/cycle-prompt.sh <role> <mode> PR <n>`
   If it exits nonzero, show stderr and stop. Append this paragraph to the output:

   > Cross-review peer: after you post a round comment of your own
   > (`## Review round`, `## Verification round`, or `## Fixed — …`) that does
   > not say `Result: No findings.`, relaunch the Codex peer with
   > `~/.claude/skills/rulez-claudeset/scripts/cross-review.sh <peer-role> <n>`
   > (it replaces the previous `codex-<n>` session). Never relaunch after an idle tick.

3. **Launch the peer now if it acts first** — i.e. `peer-role` is `reviewer` or
   `verifier`: run `~/.claude/skills/rulez-claudeset/scripts/cross-review.sh <peer-role> <n>`.
   If it fails, show the error and stop. A `fixer` peer waits for Claude's first round.

4. **Auto-start the watcher.** Invoke the `<mode>` skill via the Skill tool with
   the prompt from step 2. That turns this agent into the watcher; do not also
   run the protocol yourself.

5. Tell the user: Claude's role/mode, the peer role, whether the peer was
   launched, and `tmux attach -t codex-<n>` to watch it. Stop.
