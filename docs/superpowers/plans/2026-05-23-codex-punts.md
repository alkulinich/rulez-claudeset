# Codex Punts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the Codex `rulez-tools` skill so Codex can enrich and triage the existing Rulez `.claude/punts/` queue.

**Architecture:** Keep the implementation skill-only. Update `SKILL.md` with Codex-native `punts-enrich` and interactive `punts-triage` workflows, add lightweight skill-text assertions to the existing Codex tests, and update README supported-workflow docs. Do not change Claude commands, Claude scripts, storage paths, or installer behavior.

**Tech Stack:** Markdown Codex skill instructions, Bash shell tests, existing `.claude/punts/` storage, existing `scripts/punts-extract-prompt.sh` prompt builder.

---

## File Structure

- Modify `adapters/codex/skills/rulez-tools/SKILL.md` - Add `Punts Enrich` and `Punts Triage` sections, update frontmatter description and first-pass scope.
- Modify `tests/codex/test-setup-codex.sh` - Add assertions that the skill documents the Codex punts workflows and required storage/mechanics.
- Modify `README.md` - Add Codex punts phrases and supported-workflow wording.

## Task 1: Add Failing Skill Text Tests

**Files:**
- Modify: `tests/codex/test-setup-codex.sh`

- [ ] **Step 1: Add a helper assertion for skill body text**

In `tests/codex/test-setup-codex.sh`, after `test_rulez_tools_skill_frontmatter_is_valid`, add this test function:

```bash
test_rulez_tools_skill_documents_punts_workflows() {
  local skill_file skill_body
  skill_file="$REPO_ROOT/adapters/codex/skills/rulez-tools/SKILL.md"
  skill_body="$(cat "$skill_file")"

  assert_contains "use rulez-tools to enrich punts" "$skill_body" "skill documents punts enrich phrasing"
  assert_contains "use rulez-tools to triage punts" "$skill_body" "skill documents punts triage phrasing"
  assert_contains ".claude/punts/raw" "$skill_body" "skill documents shared raw punts storage"
  assert_contains ".claude/punts/state/slice-" "$skill_body" "skill documents punt slice storage"
  assert_contains "spawn_agent" "$skill_body" "skill documents Codex subagent enrichment"
  assert_contains "APPROVE / REJECT / SKIP / MERGE" "$skill_body" "skill documents interactive triage choices"
  assert_contains "scripts/punts-extract-prompt.sh" "$skill_body" "skill documents shared prompt builder"
}
```

- [ ] **Step 2: Run the Codex tests to verify they fail**

Run:

```bash
tests/codex/run-tests.sh
```

Expected: non-zero exit. The new `test_rulez_tools_skill_documents_punts_workflows` should fail because the current skill does not document Codex punts support.

- [ ] **Step 3: Commit the failing tests**

Run:

```bash
git add tests/codex/test-setup-codex.sh
git commit -m "test: cover Codex punts skill docs"
```

## Task 2: Extend `rulez-tools` Skill With Punts Workflows

**Files:**
- Modify: `adapters/codex/skills/rulez-tools/SKILL.md`

- [ ] **Step 1: Update frontmatter description**

Change line 3 from:

```yaml
description: "Use for Rulez shared tooling in Codex: GitHub workflow commands and handoffs backed by this repository's scripts."
```

to:

```yaml
description: "Use for Rulez shared tooling in Codex: GitHub workflow commands, handoffs, and punts backed by this repository's scripts."
```

- [ ] **Step 2: Update the opening use sentence**

Change the paragraph under `# Rulez Tools` to:

```markdown
Use this skill when the user asks Codex to use `rulez-tools`, or asks for Rulez-style GitHub workflow tasks such as starting an issue, creating a PR, testing a PR, pushing fixes, merging a PR, writing a handoff, enriching punts, or triaging punts.
```

- [ ] **Step 3: Add punts phrases to Command Mapping**

At the end of `## Command Mapping`, after the handoff mapping and before `## First-Pass Scope`, add:

````markdown
When the user says `use rulez-tools to enrich punts`:

1. Use the `Punts Enrich` workflow below.
2. Report `enriched=N failed=M skipped_no_slice=K already_structured=L`.
3. If failures remain, explain that raw files and slice files were preserved for retry.

When the user says `use rulez-tools to triage punts`:

1. Use the `Punts Triage` workflow below.
2. Ask for one decision per evidence row.
3. Do not bulk-approve rows.
````

- [ ] **Step 4: Add `Punts Enrich` and `Punts Triage` sections**

Insert this content after `## Command Mapping` and before `## First-Pass Scope`:

````markdown
## Punts Enrich

Use this workflow when the user says `use rulez-tools to enrich punts`.

Do not run `scripts/punts-enrich.sh` for Codex enrichment. That script is the Claude batch path and shells out to `claude -p`. Codex enrichment uses in-session `spawn_agent` calls and the existing `.claude/punts/` queue.

Storage stays project-local:

```text
.claude/punts/raw/*.json
.claude/punts/state/slice-*.jsonl
.claude/punts/*.md
```

Workflow:

1. From the target project root, find raw files at `.claude/punts/raw/*.json`. If the directory or files are missing, report `enriched=0 failed=0 skipped_no_slice=0 already_structured=0`.
2. For each raw file, read `jq -r '.fallback // empty' "$raw_file"`.
3. Files whose fallback is not `regex-only` are already structured. Count them as `already_structured` and leave them unchanged.
4. For each regex-only raw file, compute the matching slice path: `.claude/punts/state/slice-<raw-basename>.jsonl`, where `<raw-basename>` is the raw file name without `.json`.
5. If the slice is missing, count `skipped_no_slice` and leave the raw file unchanged.
6. Read `session_id` and `regex_hits` from the raw file with `jq -r '.session_id // empty'` and `jq -r '.regex_hits // empty'`. Missing values count as `failed`.
7. Build the extraction prompt with `"$RULEZ_HOME/scripts/punts-extract-prompt.sh" "$slice" "$session_id" "$regex_hits"`.
8. Use Codex `spawn_agent` to enrich regex-only files, up to 8 files per round. Each agent receives exactly one prompt body and must return a single JSON array.
9. For each agent result, extract the JSON array and validate it with `jq -e .`.
10. On valid JSON, overwrite the raw file with the structured array and delete the matching slice file.
11. On invalid JSON, agent failure, missing fields, or parse failure, leave the raw file and slice file untouched for retry.
12. Report `enriched=N failed=M skipped_no_slice=K already_structured=L`.

## Punts Triage

Use this workflow when the user says `use rulez-tools to triage punts`.

Triage is interactive and uses the existing `.claude/punts/` queue. Do not use `.codex/punts/`. Do not bulk-approve evidence rows.

Workflow:

1. Run the `Punts Enrich` workflow first.
2. List raw files with `ls -1t .claude/punts/raw/*.json 2>/dev/null`.
3. If there are no raw files, report `No untriaged punts.` and stop.
4. Process raw files oldest first by mtime.
5. For each structured evidence row, present the claim, evidence quote, files mentioned, source and confidence, session id, branch, and timestamp.
6. Ask the user for one decision: `APPROVE / REJECT / SKIP / MERGE WITH <existing>`.
7. On `APPROVE`, generate a lowercase kebab-case slug from `claim`, at most 64 characters. If the slug exists for a different id, append `-2`, `-3`, and so on. Write `.claude/punts/<slug>.md` using the punt markdown template below, then remove that row from the raw JSON.
8. On `REJECT`, remove that row from the raw JSON.
9. On `SKIP`, leave that row unchanged.
10. On `MERGE WITH <existing>`, append a new evidence block to the existing `.claude/punts/*.md`, update `last_seen`, append the session id to `sessions`, then remove that row from the raw JSON.
11. If a raw file becomes empty, delete it.
12. End with `N approved, M rejected, K skipped, P merged.`

Use this punt markdown template for approved rows:

```markdown
---
id: <row.id>
first_seen: <row.session_ended_at YYYY-MM-DD>
last_seen: <row.session_ended_at YYYY-MM-DD>
branches: [<row.branch>]
sessions: [<row.session_id>]
status: open
source: <row.source>
confidence: <row.subagent_confidence>
---

# <claim as title>

## Evidence

> <row.evidence_quote>

(seen in session `<row.session_id>` on branch `<row.branch>` at <row.session_ended_at>)

## Files

- <each file from row.files_mentioned, one per bullet>

## Suggested next step

Ask the user what they want to do about it and record their answer here, or use your own concise recommendation if they say "you decide".
```
````

- [ ] **Step 5: Update first-pass scope**

Replace:

```markdown
This skill currently covers GitHub workflow and handoff commands only. It does not install or manage Codex hooks, statusline behavior, punts, `what-have-i-done`, or Claude transcript/session storage.
```

with:

```markdown
This skill currently covers GitHub workflow, handoff, punts enrich, and punts triage workflows. It does not install or manage Codex hooks, statusline behavior, `what-have-i-done`, `.codex/punts/`, or Claude transcript/session storage.
```

- [ ] **Step 6: Run Codex tests**

Run:

```bash
tests/codex/run-tests.sh
```

Expected: `19 tests run, 0 failed`.

- [ ] **Step 7: Verify skill frontmatter parses as YAML**

Run:

```bash
ruby -ryaml -e 'path="adapters/codex/skills/rulez-tools/SKILL.md"; lines=File.readlines(path); stop=lines[1..].index("---\n") + 1; data=YAML.safe_load(lines[0..stop].join); abort "bad name" unless data["name"] == "rulez-tools"; abort "missing punts" unless data["description"].include?("punts"); puts data["description"]'
```

Expected output:

```text
Use for Rulez shared tooling in Codex: GitHub workflow commands, handoffs, and punts backed by this repository's scripts.
```

- [ ] **Step 8: Commit the skill update**

Run:

```bash
git add adapters/codex/skills/rulez-tools/SKILL.md
git commit -m "feat: document Codex punts workflows"
```

## Task 3: Update README Codex Workflow Documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add punts phrases to the Codex install section**

In the Codex install section's sample phrase block, change:

```text
use rulez-tools to start issue 123
use rulez-tools to create PR
use rulez-tools to test PR 5
```

to:

```text
use rulez-tools to start issue 123
use rulez-tools to create PR
use rulez-tools to test PR 5
use rulez-tools to enrich punts
use rulez-tools to triage punts
```

- [ ] **Step 2: Update first-adapter scope text**

Change:

```markdown
The first Codex adapter covers GitHub workflow and handoff commands only. The
Claude slash commands, settings, hooks, and statusline remain Claude-specific.
```

to:

```markdown
The Codex adapter covers GitHub workflow, handoff, punts enrich, and punts
triage workflows. It reuses the existing `.claude/punts/` queue; Claude slash
commands, settings, hooks, and statusline remain Claude-specific.
```

- [ ] **Step 3: Update the Commands section Codex note**

Change:

```markdown
For Codex, use the `rulez-tools` skill instead of Claude slash commands. The
first supported Codex workflows are start issue, create PR, test PR, push
fixes, merge PR, and handoff.
```

to:

```markdown
For Codex, use the `rulez-tools` skill instead of Claude slash commands. The
supported Codex workflows are start issue, create PR, test PR, push fixes,
merge PR, handoff, punts enrich, and punts triage.
```

- [ ] **Step 4: Run focused tests**

Run:

```bash
tests/codex/run-tests.sh
```

Expected: `19 tests run, 0 failed`.

- [ ] **Step 5: Commit README update**

Run:

```bash
git add README.md
git commit -m "docs: add Codex punts usage"
```

## Task 4: Final Verification

**Files:**
- Verify: `adapters/codex/skills/rulez-tools/SKILL.md`
- Verify: `tests/codex/test-setup-codex.sh`
- Verify: `README.md`

- [ ] **Step 1: Run focused Codex tests**

Run:

```bash
tests/codex/run-tests.sh
```

Expected: `19 tests run, 0 failed`.

- [ ] **Step 2: Verify skill YAML frontmatter**

Run:

```bash
ruby -ryaml -e 'path="adapters/codex/skills/rulez-tools/SKILL.md"; lines=File.readlines(path); stop=lines[1..].index("---\n") + 1; data=YAML.safe_load(lines[0..stop].join); abort "bad name" unless data["name"] == "rulez-tools"; abort "missing punts" unless data["description"].include?("punts"); puts data.inspect'
```

Expected output includes:

```text
"name"=>"rulez-tools"
```

and:

```text
"description"=>"Use for Rulez shared tooling in Codex: GitHub workflow commands, handoffs, and punts backed by this repository's scripts."
```

- [ ] **Step 3: Run existing punts suite**

Run:

```bash
tests/punts/run-tests.sh
```

Expected: `34 tests run, 0 failed`.

- [ ] **Step 4: Check git state**

Run:

```bash
git status --short
```

Expected: no uncommitted files from this implementation except pre-existing unrelated files such as `tmp/`.

## Self-Review

- Spec coverage: The plan updates `rulez-tools` with `punts-enrich` and `punts-triage`, reuses `.claude/punts/`, uses Codex `spawn_agent` instructions, leaves `scripts/punts-enrich.sh` unchanged, adds tests for required skill text, and updates README.
- Scope check: The plan does not add a Codex Stop hook, `.codex/punts/`, new scripts, Claude command changes, or automatic Codex transcript capture.
- Placeholder scan: No task uses placeholder instructions; each edit has concrete content and commands.
- Type/name consistency: The skill name remains `rulez-tools`; storage remains `.claude/punts/`; the expected Codex test count is 19 after adding seven assertions.
