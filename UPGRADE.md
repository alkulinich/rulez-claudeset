# Upgrade Guide

User-facing notes per release. Each section: **Action** (what you must
do) + **Caveat** (what changed that you'll notice). Internal change
descriptions and motivation prose live in the commit messages, not
here. The legacy v1.0.0 migration sections at the bottom are kept
verbatim — anyone arriving from a pre-1.0 install needs them.

## To v1.11.0 - from v1.10.1

**Action:** None.

**Caveat:** spec2pr accepts `--implementer codex|claude` (default `codex`,
identical to before). `claude` implements with the Claude CLI and flips the
pr-review reviewer to codex. Not available via mctl or spec2pr-chain.

## To v1.10.1 - from v1.10.0

**Action:** None.

**Caveat:** a `/rulez:spec2pr-chain` merge that hits a genuine conflict is now
auto-resolved by a model call (surfaced as `CHAIN OK resolved-conflict`, with the
diff kept in the run's meta dir) instead of halting; a `BEHIND` branch is brought
up to date automatically; and the new `--admin` flag opts into merging past branch
protection (off by default).

## To v1.10.0 - from v1.9.0

**Action:** None.

**Caveat:** new `/rulez:spec2pr-chain <spec…>` processes specs in order,
auto-merging each PR (squash, delete branch) before the next so each builds on
its predecessors; it stops at the first spec that does not reach DONE or whose
PR does not merge cleanly, and re-running resumes past the specs already
merged.

## To v1.9.0 - from v1.8.2

**Action:** None.

**Caveat:** on any non-DONE halt (HALT/SPLIT/DIRTY) spec2pr now publishes the
worktree's spec & plan to main via git-publish-spec.sh (commits + pushes
origin/main), so you no longer dig into the worktree to recover them. Requires
the repo on main; on failure it WARNs and leaves them for manual publish. Set
SPEC2PR_PUBLISH_ON_HALT=0 to disable.

## To v1.8.2 - from v1.8.1

**Action:** None.

**Caveat:** the co-author trailer on commits made by /rulez:create-pr and
/rulez:push-fixes now reads "Claude Opus 4.8 (1M context)" (was a stale "4.6").

## To v1.8.1 - from v1.8.0

**Action:** None.

**Caveat:** spec2pr's budget forecast now recovers its JSON when the model wraps
it in prose or a ```json fence (previously it warned "malformed forecast JSON"
and skipped the budget check for that run). review-pr.sh is unaffected.

## To v1.8.0 - from v1.7.2

**Action:** None.

**Caveat:** spec2pr now spends one extra claude call per run, after
plan-review, to forecast the final PR diff size. If the forecast
exceeds the diff limit it stops early (SPEC2PR SPLIT forecast) and prints a
recommended split instead of running implement. New flags --ignore-plan-limit
and --ignore-pr-limit force a run past the respective size limit;
--ignore-pr-limit also applies to review-pr. The /rulez:spec2pr command and
mctl add spec2pr forward the spec2pr override flags; mctl add review-pr forwards
--ignore-pr-limit. Set SPEC2PR_FORECAST=0 to disable the forecast step.

## To v1.7.2 - from v1.7.1

**Action:** None.

**Caveat:** spec2pr's PR-review diff-size gate (and the diff sent to the
reviewer) now measures only the implementation, excluding the committed spec and
plan files. Runs whose spec+plan previously pushed an otherwise-reasonable
implementation over the 128 KB limit now pass. `review-pr.sh` is unaffected.

## To v1.7.1 - from v1.7.0

**Action:** None.

**Caveat:** `git-publish-spec.sh` now also accepts spec/plan paths that live in
a worktree and copies them into the current repo before committing. Run it from
the repo root on `main`, as before.

## To v1.7.0 - from v1.6.2

**Action:** None. Two new spec2pr split-recovery tools ship automatically:
the `/rulez:spec2pr-split` command and the `git-publish-spec.sh` helper.

## To v1.6.2 - from v1.6.1

**Action:** None. `bin/setup` migrates the default `spec2pr` state dir
automatically when it is safe.

**Caveat:** `/rulez:spec2pr` state now defaults to
`~/.rulez-claudeset/spec2pr/`; worktrees stay at `~/.worktrees/`.
On normal same-filesystem installs, existing `~/.spec2pr/` is moved there
and the old path becomes a deletable symlink after no local scripts still
reference it. With a cross-filesystem custom `RULEZ_CLAUDESET_HOME`, or
while a legacy run is locked, the new default may be a symlink back to the
old path until setup is rerun after the lock clears, or until you manually
migrate the state.

## To v1.6.1 — from v1.6.0

**Action:** None.

**Caveat:** New `bin/install.sh` — a standalone clone-or-force-update
for remote machines, installable in one line:
`curl -fsSL https://raw.githubusercontent.com/alkulinich/rulez-claudeset/main/bin/install.sh | bash`.
It refreshes both adapters (`bin/setup` always; `bin/setup-codex` only when
`~/.codex` exists). Unlike the background `auto-update.sh`, it can clone a
missing install and is run by hand or cron.

## To v1.6.0 — from v1.5.x

**Action:** None. `/rulez:spec2pr` is available after auto-update.

**Caveat:** `/rulez:spec2pr` requires the `codex` CLI and `gh` to be
installed and authenticated. Runs write state to `~/.spec2pr/` and
worktrees to `~/.worktrees/`.

## To v1.5.1 — from v1.5.0

**Action:** None.

**Caveat:** `/rulez:what-have-i-done` now surfaces handoffs from
feature branches you haven't merged back to main yet — previously it
only saw the currently checked-out branch's history. Expect richer
rollups on workflows where you handoff mid-branch.

## To v1.5.0 — from v1.4.5

**Action:** Re-run `bin/setup-per-project.sh` for any per-project
installs (the changes are inside `commands/rulez/*.md`, which the
per-project installer copies into the repo's `.claude/`). Global
installs are picked up by the auto-update hook.

**Caveat:** `/rulez:test-pr` no longer streams live test progress into
the main thread — you see a final pass/fail table with the first ~20
lines of stderr+stdout for any failing step. If a step fails opaquely,
re-run the failing command manually to see full output.

## To v1.4.5 — from v1.4.4

**Action:** None.

**Caveat:** `/rulez:what-have-i-done` no longer renders empty projects
under any date heading (today included). The `(no git activity in
window)` marker is gone — date headings disappear entirely when
nothing under them has bullets.

## To v1.4.4 — from v1.4.3

**Action:** None.

**Caveat:** `/rulez:what-have-i-done` bullets drop PR numbers, commit
SHAs, file paths, and semicolon-enumerations. The inline parenthetical
now carries *signal* (a metric, symptom, or trigger), not artifacts.
If you need PR numbers or file paths, use `git log` or open
`HANDOFF.md`.

## To v1.4.3 — from v1.4.2

**Action:** None.

**Caveat:** `/rulez:what-have-i-done` bullets are flat — no nested
sub-items. Concrete artifacts go inline as a parenthetical.

## To v1.4.2 — from v1.4.1

**Action:** None.

**Caveat:** `/rulez:what-have-i-done` projects are now grouped by
GitHub repo name (e.g. `dc-import-2026` instead of
`26.03-dc-import-2026`). Projects with long-lived JSONL sessions that
were silently skipped before now appear correctly.

## To v1.4.1 — from v1.4.0

**Action:** None — auto-update + setup re-run picks up the new
permission entries.

**Caveat:** `/rulez:what-have-i-done` runs silently now (v1.4.0
prompted on every invocation). Per-project bullets are 1–3 narrative
lines per day instead of one-per-commit, and empty prior-day headings
are suppressed.

## To v1.4.0 — from v1.3.3

**Action:** None.

**Caveat:** New command — `/rulez:what-have-i-done [N]`. Cross-project
rollup of the last N calendar days (default 3) of HANDOFF.md +
commit subjects across every Claude project you've touched. Output
also written to `~/.claude/what-have-i-done/<today>.md`.

## To v1.3.3 — from v1.3.2

**Action:** None.

**Caveat:** `/rulez:handoff` now pushes the handoff commit to the
remote automatically (deliberate scoped bypass of the harness's
"Git Push to Default Branch" prompt; only ever stages
`HANDOFF.md`). If you don't want the push, edit
`scripts/git-commit-handoff.sh` or skip the script and commit
manually.

## To v1.3.2 — from v1.3.1

**Action:** None.

**Caveat:** `/rulez:handoff` ends with a literal "Run `/compact`
now" line so you can free context for the next task. `/compact` is
client-side; the assistant cannot invoke it itself.

## To v1.3.1 — from v1.3.0

**Action:** None — pull, re-run setup. Existing raw + slice files work
under either v1.3.0 or v1.3.1 paths.

**Caveat:** `/rulez:punts-triage` enriches in-session via the Agent
tool (parallel, shared prompt cache) instead of looping `claude -p`.
`scripts/punts-enrich.sh` and `/rulez:punts-enrich` still exist for
batch / non-interactive back-fills.

## To v1.3.0 — from v1.2.5

**Action:** None for the punt pipeline. If slice files accumulate at
`.claude/punts/state/` between Stop and triage and you want to prune
old ones:
```bash
find .claude/punts/state -name 'slice-*' -mtime +14 -delete
```

**Caveat:** The Stop hook is now sync-only (millisecond return);
subagent enrichment moved to `/rulez:punts-triage` (auto-invoked) or
`scripts/punts-enrich.sh`. Slice files persist on disk until
enrichment consumes them. Pre-v1.3.0 raw files with claude-wrapper
output are skipped by enrich (they're already structured).

## To v1.2.5 — from v1.2.4

**Action:** None.

**Caveat:** Stop hook fix — long sessions (>64 KB transcripts) no
longer crash with SIGPIPE. Symptom under v1.2.2–v1.2.4 was *"Stop
hook error: Failed with non-blocking status code"*; offset state
still advanced, so subsequent fires re-failed on the next chunk
window. Fixed by `|| true` on the `tail | head` slice pipelines.

## To v1.2.4 — from v1.2.3

**Action:** None.

**Caveat:** Subagent JSON output is now validated via `jq -e .` before
replacing the regex-only fallback. Bad output (truncated JSON on >5 MB
transcripts) keeps the synchronous regex-only artifact instead of
overwriting with garbage. Triage now has a guarantee: every
`raw/*.json` file is parseable JSON.

## To v1.2.3 — from v1.2.2

**Action:** None.

**Caveat:** Internal subagent prompt clarity fix — no behavior change.

## To v1.2.2 — from v1.2.1

**Action:** None — defaults are tuned. Override only if you want
different chunking:
- `PUNT_MAX_CHUNK` — max bytes per chunk (default 262144 / 256 KB).
- `PUNT_LOOKBACK` — pre-chunk context bytes per slice (default 4096 / 4 KB).

**Caveat:** Punt subagent handles long sessions via per-chunk slicing;
oversized windows fan out to multiple `claude -p` invocations. Output
filenames changed to `raw/<session_id>-<chunk_end>-<pid>.json` (one
per chunk that contains hits — typically still one per Stop fire).
Slice files live at `.claude/punts/state/slice-*.jsonl`.

## To v1.2.1 — from v1.2.0

**Action:** If your project gitignores `.claude/punts/raw/`, also
ignore `.claude/punts/state/` — state files are transient
bookkeeping.

**Caveat:** Stop hook is incremental now (per-session byte offset at
`.claude/punts/state/<session_id>.offset`); only screens bytes added
since the last run. Output filenames changed to
`raw/<session_id>-<offset>-<pid>.json` (one per Stop run with hits).

## To v1.2.0 — from v1.1.4

**Action:** Decide your `.claude/` gitignore stance for the new punt
artifacts. Most projects already ignore `.claude/` wholesale; if you
want to track the curated `<slug>.md` files in git:
```
.claude/*
!.claude/punts/
.claude/punts/raw/
```
To disable the punt Stop hook entirely, remove its entry from
`~/.claude/settings.json`. `bin/setup` will not re-add it as long as
some hook with that command path exists.

**Caveat:** New punt detection — Stop hook regex-screens transcripts
for "pre-existing", "out of scope", "[PUNT]:" etc. New
`/rulez:punts-triage` walks the accumulated raw evidence and promotes
approved items to `.claude/punts/<slug>.md`. New `## Punts` section
in `RULEZ.md`.

## To v1.1.4 — from v1.1.3

**Action:** None.

**Caveat:** Statusline context meter now reflects auto-compact
proximity (400k threshold on 1M-context models), not full-window
proximity. The number now matches `/context`. Previously a session
at 149k / 400k showed as 15% (full window) instead of 37%
(auto-compact).

## To v1.1.3 — from v1.1.2

**Action:** To see the `/effort` chip in the statusline, set effort
via one of: `/effort <level>` mid-session (with arg, not the
interactive picker — that one still can't be captured), or
`CLAUDE_CODE_EFFORT_LEVEL` env var, or `effortLevel` in
`.claude/settings.json` / `~/.claude/settings.json`.

**Caveat:** `/effort` chip now actually renders (was always empty
before). Picker-form selections (`/effort` + arrow keys) remain
invisible until upstream exposes effort in the statusline JSON.

## To v1.1.2 — from v1.1.1

**Action:** None — but the first auto-update after v1.1.2 will do a
one-time full-history fetch (small, a few hundred KB) for users on
v1.1.0 or earlier. Subsequent fetches are incremental.

**Caveat:** Completes the shallow-clone fix from v1.1.1 — pre-existing
shallow clones from v1.0.0 are now properly unshallowed.

## To v1.1.1 — from v1.1.0

Superseded by v1.1.2 — the fix was incomplete. See v1.1.2.

## To v1.1.0 — from v1.0.0

**Action:** None — `bin/setup` is idempotent and the SessionStart
auto-update picks up new symlinks/settings additively. If you have
documentation pointing at `./install.sh`, update to
`bin/setup-per-project.sh` (renamed; the global setup entry point at
`bin/setup` is unchanged).

**Caveat:** New features:
- `/rulez:todo` — manage `TODO.txt` in todo.txt format.
- HANDOFF.md history in git — `/rulez:handoff` now commits the file;
  view past handoffs with `git log -p HANDOFF.md`.
- `/effort` level chip in the statusline (see v1.1.3 for caveats).
- `RULEZ.md` symlinked into `~/.claude/` and `@RULEZ.md` appended to
  `~/.claude/CLAUDE.md` so global rules are always in context.

---

## To v1.0.0 — from shared-tools (GitHub Flow, no develop branch)

If you used the `shared-tools/claude-example/` submodule with GitHub Flow (`main`-only) and unprefixed commands like `/start-issue`.

### What changed

| Before | After |
|--------|-------|
| `shared-tools/` git submodule per repo | Global install at `~/.claude/skills/rulez-claudeset/` |
| `shared-tools/claude-example/scripts/install.sh` | `./bin/setup` (one-time) |
| `/start-issue`, `/create-pr`, etc. | `/rulez:start-issue`, `/rulez:create-pr`, etc. |
| `./shared-tools/claude-example/scripts/*.sh` | `~/.claude/skills/rulez-claudeset/scripts/*.sh` |
| Manual `git submodule update` | Auto-updates on session start |

### Migration steps

1. **Install globally:**
   ```bash
   git clone git@github.com:alkulinich/rulez-claudeset.git ~/.claude/skills/rulez-claudeset
   cd ~/.claude/skills/rulez-claudeset && ./bin/setup
   ```

2. **Remove old submodule** from each project repo:
   ```bash
   git submodule deinit -f shared-tools
   git rm -f shared-tools
   rm -rf .git/modules/shared-tools
   git commit -m "chore: remove shared-tools submodule (migrated to global install)"
   ```

3. **Remove old commands** that were copied by `install.sh`:
   ```bash
   rm -f .claude/commands/start-issue.md
   rm -f .claude/commands/create-pr.md
   rm -f .claude/commands/test-pr.md
   rm -f .claude/commands/push-fixes.md
   rm -f .claude/commands/merge-pr.md
   rm -f .claude/commands/add-issue.md
   rm -f .claude/commands/brainstorm.md
   rm -f .claude/commands/simple-script.md
   rm -f .claude/commands/dispatch-subagent.md
   rm -f .claude/commands/handoff.md
   rm -rf .claude/commands/new-project/
   ```

4. **Clean up old permission paths** in your repo's `.claude/settings.json`:
   Remove all entries matching these patterns:
   ```
   Bash(./shared-tools/claude-example/scripts/...)
   Bash(shared-tools/claude-example/scripts/...)
   Bash(bash shared-tools/claude-example/scripts/...)
   Skill(start-issue)
   Skill(create-pr)
   Skill(test-pr)
   Skill(push-fixes)
   ```
   The global `~/.claude/settings.json` now has the correct paths and `Skill(rulez:*)` entries.

5. **Update statusLine** in your repo's `.claude/settings.json`:
   Remove the old statusLine that references `shared-tools/claude-example/scripts/session-time.sh` — the global settings now handle this.

6. **Update git-workflow.md** if your repo has one:
   Replace `/start-issue` → `/rulez:start-issue` (and other commands).

7. **Update CLAUDE.md** references if any point to `shared-tools/claude-example/scripts/` or old command names.

---

## To v1.0.0 — from legacy (shared submodule with develop branch)

If you previously used the `shared/` submodule approach with `setup-commands.sh` / `sync-config.sh`, follow these steps.

### What changed

| Before | After |
|--------|-------|
| `shared/` or `shared-tools/` git submodule per repo | Global install at `~/.claude/skills/rulez-claudeset/` |
| `shared/scripts/setup-commands.sh` | `./bin/setup` (one-time) |
| `shared/scripts/sync-config.sh` | Automatic via SessionStart hook |
| `develop` → `main` branching (GitFlow) | `main`-only (GitHub Flow) |
| `/start-issue`, `/create-pr`, etc. | `/rulez:start-issue`, `/rulez:create-pr`, etc. |
| `./shared/scripts/git-start-issue.sh` | `~/.claude/skills/rulez-claudeset/scripts/git-start-issue.sh` |
| Manual `cd shared && git pull` | Auto-updates on session start |

### Migration steps

1. **Install globally:**
   ```bash
   git clone https://github.com/alkulinich/rulez-claudeset ~/.claude/skills/rulez-claudeset
   cd ~/.claude/skills/rulez-claudeset && ./bin/setup
   ```

2. **Remove old submodule** from each project repo:
   ```bash
   git submodule deinit -f shared
   git rm -f shared
   rm -rf .git/modules/shared
   git commit -m "chore: remove legacy shared submodule"
   ```
   (Replace `shared` with `shared-tools` or `shared-tools/claude-example` if that was your submodule path.)

3. **Remove old commands** that were copied by `setup-commands.sh`:
   ```bash
   rm -f .claude/commands/start-issue.md
   rm -f .claude/commands/create-pr.md
   rm -f .claude/commands/test-pr.md
   rm -f .claude/commands/push-fixes.md
   rm -f .claude/commands/merge-pr.md
   rm -f .claude/commands/add-issue.md
   rm -rf .claude/commands/new-project/
   ```
   The new commands live at `~/.claude/commands/rulez/` (symlinked) and use the `/rulez:` prefix.

4. **Clean up old permission paths** in your repo's `.claude/settings.json`:
   Remove entries like:
   ```
   Bash(./shared-tools/claude-example/scripts/...)
   Bash(shared/scripts/...)
   ```
   The global `~/.claude/settings.json` now has the correct paths. Per-project settings only need project-specific permissions.

5. **Update git-workflow.md** if your repo has one:
   - Replace `/start-issue` → `/rulez:start-issue` (and other commands)
   - If you were using `develop` as integration branch, decide whether to switch to GitHub Flow (`main`-only)

6. **Update CLAUDE.md** references if any point to `shared/scripts/` or old command names.

### Branch strategy change (optional)

The legacy setup used GitFlow (`main` + `develop` + `feature/*`). The new default is GitHub Flow (`main` + `feature/*`). If you want to keep `develop`, the commands still work — they default to `main` as base branch, but you can pass a custom base to `/rulez:create-pr`.
