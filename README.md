# rulez-claudeset

Shared Claude Code commands, permissions, and status line for GitHub Flow workflow.

## Install (one line)

Clone-or-update, both adapters, on any machine:

```bash
curl -fsSL https://raw.githubusercontent.com/alkulinich/rulez-claudeset/main/bin/install.sh | bash
```

## Install (claude)

```bash
git clone https://github.com/alkulinich/rulez-claudeset ~/.claude/skills/rulez-claudeset
cd ~/.claude/skills/rulez-claudeset && ./bin/setup
```

This will:
1. Symlink commands to `~/.claude/commands/rulez/` (available as `/rulez:start-issue`, etc.)
2. Merge permissions into `~/.claude/settings.json`
3. Install a SessionStart hook for auto-updates

Auto-updates run in the background on every Claude Code session (1-hour throttle, ff-only pull).

## Install (Codex)

Install the same repository as a Codex skill source, then run the Codex adapter
installer. The repository checkout stays at `~/.codex/skills/rulez-claudeset`;
`setup-codex` symlinks the `rulez-tools` skill into Codex's skill directory.

```bash
mkdir -p ~/.codex/skills
git clone https://github.com/alkulinich/rulez-claudeset ~/.codex/skills/rulez-claudeset
cd ~/.codex/skills/rulez-claudeset && ./bin/setup-codex
```

This symlinks the Codex skill:

```text
~/.codex/skills/rulez-tools -> ~/.codex/skills/rulez-claudeset/adapters/codex/skills/rulez-tools
```

Then ask Codex with phrases like:

```text
use rulez-tools to start issue 123
use rulez-tools to create PR
use rulez-tools to test PR 5
use rulez-tools to enrich punts
use rulez-tools to triage punts
```

The Codex adapter covers GitHub workflow, handoff, punts enrich, and punts
triage workflows. It reuses the existing `.claude/punts/` queue; Claude slash
commands, settings, hooks, and statusline remain Claude-specific.

To update an existing Codex install:

```bash
cd ~/.codex/skills/rulez-claudeset
git pull --ff-only
./bin/setup-codex
```

## Install (per-project)

Add as a submodule and run the per-project installer:

```bash
git submodule add https://github.com/alkulinich/rulez-claudeset rulez-claudeset
./rulez-claudeset/bin/setup-per-project.sh
```

This copies commands into the repo's `.claude/` with paths rewritten for the submodule location.

## Uninstall (Claude)

```bash
~/.claude/skills/rulez-claudeset/bin/uninstall
rm -rf ~/.claude/skills/rulez-claudeset
```

This removes the commands symlink, the SessionStart hook, the rulez permissions, the status line, and the `@RULEZ.md` import. It does not touch `~/.claude/what-have-i-done/` or `.claude/punts/` data in your projects.

## Uninstall (Codex)

```bash
rm -f ~/.codex/skills/rulez-tools
rm -rf ~/.codex/skills/rulez-claudeset
```

This removes the Codex `rulez-tools` skill symlink and the cloned repository
checkout. It does not touch `.claude/punts/` data in your projects.

## Commands

| Command | Description |
|---------|-------------|
| `/rulez:brainstorm` | Brainstorm before coding |
| `/rulez:add-issue` | Create a GitHub issue |
| `/rulez:start-issue 4` | Fetch issue, update main, create feature branch |
| `/rulez:create-pr` | Analyze changes, create commit, push, open PR |
| `/rulez:test-pr 5` | Checkout PR, build Docker, run tests |
| `/rulez:push-fixes` | Add fixes to current branch and push |
| `/rulez:merge-pr 5` | Merge PR and cleanup branches |
| `/rulez:handoff` | Write HANDOFF.md for next agent |
| `/rulez:dispatch-subagent` | Launch a subagent for a task |
| `/rulez:simple-script` | Write a minimal shell script |
| `/rulez:punts-triage` | Walk captured punt evidence and promote worthy items to `.claude/punts/*.md` |
| `/rulez:punts-enrich` | Back-fill structured rows for regex-only punt evidence (batch) |
| `/rulez:what-have-i-done [N]` | Cross-project rollup: last N calendar days (default 3) of HANDOFF.md + commit subjects across every recently-touched Claude project. |
| `/rulez:new-project:*` | New project setup workflow (7 steps) |
| `/rulez:update-claudeset` | Pull latest version and re-run setup |

For Codex, use the `rulez-tools` skill instead of Claude slash commands. The
supported Codex workflows are start issue, create PR, test PR, push fixes,
merge PR, handoff, punts enrich, and punts triage.

## Punts

A "punt" is something you noticed but chose not to fix in the current change — pre-existing, out of scope, or a follow-up. Flag it inline as:

```
[PUNT]: <one-line description of what you saw and where>
```

A Stop hook (`scripts/punts-detect.sh`) screens each session's transcript for these phrases (and a few softer variants like "pre-existing", "out of scope") and writes regex-only evidence to `.claude/punts/raw/*.json` along with a transcript slice in `.claude/punts/state/`. Detection is synchronous and millisecond-cheap — no subagent runs in the hook.

When you're ready, run `/rulez:punts-triage`. It enriches any regex-only rows via parallel subagents, then walks each structured row interactively (APPROVE / REJECT / SKIP / MERGE) and promotes approved ones to `.claude/punts/<slug>.md` (one issue per file, git-tracked). For batch back-fills outside triage, `/rulez:punts-enrich` runs the enrichment alone.

## What Have I Done

`/rulez:what-have-i-done [N]` rolls up the last N calendar days (default 3) across every Claude project you touched. It dispatches one Agent per project in parallel, then a pure renderer formats the rollup grouped by project per day.

The same markdown is also written to `~/.claude/what-have-i-done/<today>.md`. Re-running on the same day overwrites that file. Projects with no activity on a given date are omitted (today included); date headings disappear entirely when nothing under them has bullets.

## spec2pr & review-pr

Two unattended pipelines that drive `codex` and `claude -p` from spec to merged PR.

**`scripts/spec2pr.sh <spec.md>`** — run from inside a repo, pointed at a feature spec. It works in an isolated worktree (`~/.worktrees/<id>`, branch `spec2pr/<slug>`, logs/state under `~/.spec2pr/<id>/`) and runs: spec-review loop → plan → plan-review loop → implement → push + open a GitHub PR → diff gate → PR-review loop. Each review loop fixes blocker/major findings and repeats up to `MAX_FIX_ROUNDS`. Ends on `SPEC2PR DONE pr=<url> worktree=<path>` (exit 0), or HALT (1) / SPLIT (2, diff too big) / DIRTY (3, findings remain after the cap).

**`scripts/review-pr.sh <pr-number|pr-url>`** — run from inside the PR's repo to review *any* existing PR with the same engine: fetch the PR head into a throwaway worktree, `claude` reviews the diff, `codex` fixes findings, commit + push to the PR head branch, repeat until clean (`PRREVIEW DONE`) or stuck (`PRREVIEW DIRTY`). Fork PRs are unsupported (fixes push to the head branch).

Requires `codex`, `claude`, `gh`, `jq`, `git`; the PR reviewer also uses the **context7** MCP for up-to-date library docs when available. `bin/setup` warns if any of these (or context7) are missing — register context7 once: `claude mcp add --transport http --scope user context7 https://mcp.context7.com/mcp --header 'CONTEXT7_API_KEY: <key>'`.

### Watching progress

Long Codex and Claude steps write their detailed output to run metadata and Claude transcript files. Keep the main pane for the pipeline contract lines, and use a second pane for a live read-only view:

```bash
S=~/.claude/skills/rulez-claudeset/scripts
tmux new-session -d -s spec2pr -c ~/project "SPEC2PR_VERBOSE=1 bash $S/spec2pr.sh docs/superpowers/specs/feature-a.md; read"
tmux split-window  -t spec2pr -c ~/project "bash $S/spec2pr-watch.sh feature-a"
tmux select-layout -t spec2pr even-vertical
tmux attach -t spec2pr
```

For `review-pr.sh`, pass the `pr-N` watcher token:

```bash
S=~/.claude/skills/rulez-claudeset/scripts
tmux new-session -d -s review-pr -c ~/project "SPEC2PR_VERBOSE=1 bash $S/review-pr.sh 7; read"
tmux split-window  -t review-pr -c ~/project "bash $S/spec2pr-watch.sh pr-7"
tmux select-layout -t review-pr even-vertical
tmux attach -t review-pr
```

Use `tmux set -g mouse on` if you want mouse scrolling in the watcher pane.

### Run several at once

State is namespaced per spec as `<repo>-<spec-slug>` — lock, worktree, branch and PR are all distinct — so runs don't collide as long as each spec's filename stem is unique. Example: three at once, one spec for `project1` and two for `project2`, each in its own tmux window:

```bash
S=~/.claude/skills/rulez-claudeset/scripts/spec2pr.sh
tmux new-session -d -s spec2pr -c ~/project1 "bash $S docs/superpowers/specs/feature-a.md; read"
tmux new-window     -t spec2pr -c ~/project2 "bash $S docs/superpowers/specs/feature-b.md; read"
tmux new-window     -t spec2pr -c ~/project2 "bash $S docs/superpowers/specs/feature-c.md; read"
tmux attach -t spec2pr
```

The two `project2` runs are safe because `feature-b` and `feature-c` are different slugs → different worktrees, branches and PRs. Set `SPEC2PR_VERBOSE=1` to print per-round findings.

## Utility Scripts

| Script | Description | Usage |
|--------|-------------|-------|
| `scripts/session-time.sh` | Today's active session time (heartbeat-based) | Called by statusline automatically |
| `scripts/session-stats.sh` | Day-by-day session time history | `bash ~/.claude/skills/rulez-claudeset/scripts/session-stats.sh` |
| `scripts/context-meter.sh` | Context window usage bar (ANSI) | Called by statusline automatically |
| `scripts/statusline.sh` | Status line renderer (PID, model, time, context, branch) | Configured in settings.json |
| `scripts/punts-detect.sh` | Stop hook — regex-screens session transcripts, writes raw punt evidence | Auto-invoked on session Stop |
| `scripts/punts-enrich.sh` | Promotes regex-only raw rows to structured rows via `claude -p` | `bash ~/.claude/skills/rulez-claudeset/scripts/punts-enrich.sh` |
| `scripts/punts-extract-prompt.sh` | Builds the extraction prompt fed to the enrichment subagent | Called by triage / enrich |
| `scripts/what-have-i-done-context.sh` | Prints `TODAY`/`DATES_LIST`/window ISO timestamps so the slash command never hand-rolls bash arithmetic | Called by `/rulez:what-have-i-done` |
| `scripts/what-have-i-done-discover.sh` | Lists recently-touched Claude project dirs, resolved to real cwds | Called by `/rulez:what-have-i-done` |
| `scripts/what-have-i-done-render.sh` | Pure stdin→markdown formatter for the rollup | Called by `/rulez:what-have-i-done` |
| `scripts/what-have-i-done-finalize.sh` | Merges per-project Agent JSONs, renders, writes the dated file, prints to stdout | Called by `/rulez:what-have-i-done` |

## Requirements

- `jq` for settings merge
- `gh` CLI for GitHub operations
