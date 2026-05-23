# Handoff

## Task

Port the first useful slice of this Claude toolset to Codex as a Codex skill,
then extend it with punts support. The user wanted the Claude `/rulez:*`
workflows usable from Codex with phrases like `use rulez-tools to start issue
123`.

## Current State

- Branch: `main`, pushed to `origin/main`.
- `feature/codex-rulez-tools` was fast-forward merged into `main`.
- Working tree: only pre-existing untracked `tmp/`.
- Codex install symlink exists:
  `~/.codex/skills/rulez-tools -> /Users/rulez/Projects/26.03-shared-tools/adapters/codex/skills/rulez-tools`.
- No version bump was made.

Recent relevant commits:

```text
40aa5cc docs: add Codex install uninstall instructions
2ee092c docs: add Codex punts usage
c4203e9 feat: document Codex punts workflows
6346a5c test: cover Codex punts skill docs
a397bfe docs: plan Codex punts support
832e1d4 docs: design Codex punts support
56be2a6 fix: quote rulez-tools skill description
35d9cd4 docs: fix Codex install bootstrap
ce075a0 docs: add Codex rulez-tools install instructions
2fcad96 fix: align rulez-tools PR base guidance
53c6e53 fix: clarify rulez-tools command usage
7111afa feat: add rulez-tools Codex skill
e180dc1 feat: add Codex setup installer
cd3db2c test: isolate Codex setup tests
38d376f test: add Codex setup coverage
01c08db docs: plan Codex rulez-tools skill
7834998 docs: design Codex rulez-tools skill
```

## What Worked

### Codex adapter shape

Kept one shared script core and added a thin Codex adapter:

```text
bin/setup-codex
adapters/codex/skills/rulez-tools/SKILL.md
tests/codex/*
```

The existing Claude layout stayed intact. `bin/setup-codex` symlinks the
Codex skill into `~/.codex/skills/rulez-tools`, replacing existing symlinks
but refusing to overwrite real files or directories.

### Commands now available in Codex

Available through `rulez-tools` phrasing:

```text
use rulez-tools to start issue 123
use rulez-tools to create PR
use rulez-tools to test PR 5
use rulez-tools to push fixes
use rulez-tools to merge PR 5
use rulez-tools to write handoff
use rulez-tools to enrich punts
use rulez-tools to triage punts
```

Codex support is skill-based, not slash-command based. The README documents
install, update, and uninstall flows.

### Punts port

Codex punts support reuses the existing `.claude/punts/` queue. This avoids
splitting Claude-captured punt evidence into a parallel `.codex/punts/`
system.

Important behavior:

- `punts-enrich` in Codex is instruction-only and uses Codex `spawn_agent`.
- It does not run `scripts/punts-enrich.sh`, because that script shells out to
  `claude -p`.
- `punts-triage` remains interactive: `APPROVE / REJECT / SKIP / MERGE`.
- No Codex Stop hook was added.

### Verification

Ran and passed:

```text
tests/codex/run-tests.sh                 # 19 tests run, 0 failed
ruby -ryaml ... SKILL.md frontmatter      # parsed rulez-tools YAML
tests/punts/run-tests.sh                  # 34 tests run, 0 failed
```

Before pushing `main`, also reran:

```text
tests/codex/run-tests.sh                 # 19 tests run, 0 failed
```

Push result:

```text
origin/main updated 61c9952..40aa5cc
```

## What Didn't Work

- Initial `SKILL.md` frontmatter used an unquoted description containing
  `Codex:`. Codex rejected it with:
  `invalid YAML: mapping values are not allowed in this context`.
  Fixed by quoting the description and adding a regression assertion that the
  description line is quoted YAML.
- Review caught that `git-create-pr.sh` and `git-push-fixes.sh` require
  arguments. The initial skill text mapped them as no-arg workflows. Fixed the
  skill to gather/derive args and pass them explicitly.
- Review caught that `git-create-pr.sh` currently hardcodes `main` despite
  accepting a base arg. Fixed the skill wording to treat `main` as fixed for
  now rather than implying custom base branches work.
- One subagent hit a usage limit during the Codex punts implementation. The
  remaining work was completed inline with the same verification gates.

## Next Steps

1. **Smoke-test Codex in a fresh session.**
   - Confirm Codex loads `rulez-tools` without SKILL.md warnings.
   - Try `use rulez-tools to start issue <safe-test-issue>` in a real repo or
     a disposable test repo.
   - Try `use rulez-tools to enrich punts` on a repo with regex-only punt
     evidence.

2. **Consider real helper scripts if the punts skill text feels too heavy.**
   Current approach intentionally avoided new scripts. If Codex triage feels
   brittle, add shared helpers for raw-row removal, slugging, and punt
   frontmatter updates.

3. **Port more commands when there is demand.**
   Still Claude-only:
   - `/rulez:brainstorm`
   - `/rulez:add-issue`
   - `/rulez:dispatch-subagent`
   - `/rulez:simple-script`
   - `/rulez:what-have-i-done`
   - `/rulez:new-project:*`
   - `/rulez:update-claudeset`
   - Claude statusline/hooks/settings behavior

4. **Decide whether Codex needs its own punt capture path.**
   Current Codex support enriches/triages `.claude/punts/` but does not capture
   Codex transcript punts automatically.

5. **Clean up or ignore `tmp/`.**
   It was present throughout this work and intentionally left untouched.

## Key Decisions

- **Skill name is `rulez-tools`, not `rulez`.** Codex usage reads naturally as
  `use rulez-tools to ...`.
- **Shared scripts, adapter instructions.** Do not fork workflow scripts for
  Codex unless behavior truly diverges.
- **Reuse `.claude/punts/`.** The name is Claude-ish, but it preserves one
  backlog and avoids migration/sync complexity.
- **No Codex Stop hook yet.** This pass only ports manual enrich/triage.
- **Quote YAML frontmatter values that contain `:`.** Codex's skill loader
  parses frontmatter strictly.
