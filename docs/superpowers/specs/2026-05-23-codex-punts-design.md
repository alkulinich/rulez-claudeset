# Codex Punts in `rulez-tools` - Design

## Goal

Extend the Codex `rulez-tools` skill with support for the existing Rulez punts
workflows:

```text
use rulez-tools to enrich punts
use rulez-tools to triage punts
```

The Codex implementation should reuse the existing project-local punt queue and
curated punt files, while replacing Claude-only enrichment mechanics with
Codex-native subagents.

## Non-goals

- Do not add a Codex Stop hook.
- Do not capture new Codex transcript punts automatically.
- Do not create `.codex/punts/`.
- Do not change Claude slash commands.
- Do not rewrite `scripts/punts-enrich.sh`; it remains the Claude batch path
  that shells out to `claude -p`.
- Do not bulk-approve punt evidence during triage.

## Storage

Codex uses the existing project-local `.claude/punts/` storage:

```text
.claude/punts/raw/*.json
.claude/punts/state/slice-*.jsonl
.claude/punts/*.md
```

This keeps one backlog shared between Claude and Codex. Punt evidence captured
by the Claude Stop hook can be enriched and triaged from Codex, and approved
punts remain in the existing git-tracked `.claude/punts/*.md` files.

## Skill Changes

Update:

```text
adapters/codex/skills/rulez-tools/SKILL.md
```

Add two sections:

- `Punts Enrich`
- `Punts Triage`

The skill should continue to cover the existing GitHub workflow and handoff
commands. The frontmatter description should be updated to mention punts while
remaining valid YAML.

## `punts-enrich` Workflow

Codex enrichment is an instruction workflow inside the `rulez-tools` skill. It
does not run `scripts/punts-enrich.sh`, because that script requires `claude`
on `PATH`.

Flow:

1. Find raw files:

   ```bash
   .claude/punts/raw/*.json
   ```

2. For each raw file, read:

   ```bash
   jq -r '.fallback // empty' "$raw_file"
   ```

   Files with `fallback == "regex-only"` need enrichment. Other files count as
   `already_structured`.

3. For each regex-only file, compute the matching slice:

   ```text
   .claude/punts/state/slice-<raw-basename>.jsonl
   ```

   where `<raw-basename>` is the raw file name without `.json`.

4. If the slice is missing, leave the raw file untouched and count
   `skipped_no_slice`.

5. Read `session_id` and `regex_hits` from the raw file:

   ```bash
   jq -r '.session_id // empty' "$raw_file"
   jq -r '.regex_hits // empty' "$raw_file"
   ```

6. Build the extraction prompt with the existing helper:

   ```bash
   "$RULEZ_HOME/scripts/punts-extract-prompt.sh" "$slice" "$session_id" "$regex_hits"
   ```

7. Use Codex `spawn_agent` for enrichment. Batch up to 8 raw files per round.
   Each agent receives one prompt body and must return a single JSON array.

8. Parse each agent final response by extracting the JSON array and validating
   it with `jq -e .`.

9. On valid JSON:

   - overwrite the raw file with the structured array
   - delete the matching slice file
   - count `enriched`

10. On invalid JSON, agent failure, missing fields, or parse failure:

    - leave raw and slice files untouched
    - count `failed`

11. Report:

    ```text
    enriched=N failed=M skipped_no_slice=K already_structured=L
    ```

## `punts-triage` Workflow

Codex triage is interactive in chat and walks existing raw evidence.

Flow:

1. Run the Codex-native `punts-enrich` workflow first.
2. List raw files:

   ```bash
   ls -1t .claude/punts/raw/*.json
   ```

3. If there are no raw files, report:

   ```text
   No untriaged punts.
   ```

4. Process raw files oldest first by mtime.
5. For each structured evidence row, present:

   - claim
   - evidence quote
   - files mentioned
   - source and confidence
   - session id, branch, and timestamp

6. Ask the user for one decision:

   ```text
   APPROVE / REJECT / SKIP / MERGE WITH <existing>
   ```

7. `APPROVE`:

   - generate a kebab-case slug from `claim`
   - keep it lowercase, hyphen-only, and no more than 64 characters
   - if the slug already exists for a different id, append `-2`, `-3`, etc.
   - write `.claude/punts/<slug>.md` with the existing Claude punt template
   - remove the row from the raw JSON

8. `REJECT`:

   - remove the row from the raw JSON

9. `SKIP`:

   - leave the row unchanged

10. `MERGE WITH <existing>`:

    - append the new evidence block to the existing `.claude/punts/*.md`
    - update `last_seen`
    - append the session id to `sessions`
    - remove the row from the raw JSON

11. If a raw file becomes empty, delete it.

12. End with:

    ```text
    N approved, M rejected, K skipped, P merged
    ```

Codex must not bulk-approve rows. Skipped rows must survive for the next triage
pass.

## Punt Markdown Template

Approved Codex punts use the existing template:

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

<ask the user what they want to do about it; record their answer here, or use
your own concise recommendation if they say "you decide">
```

## Tests

Update:

```text
tests/codex/test-setup-codex.sh
```

Add lightweight assertions that `SKILL.md` documents:

- `use rulez-tools to enrich punts`
- `use rulez-tools to triage punts`
- `.claude/punts/raw`
- `.claude/punts/state/slice-`
- `spawn_agent`
- `APPROVE / REJECT / SKIP / MERGE`
- `scripts/punts-extract-prompt.sh`

Keep `tests/codex/run-tests.sh` passing.

## Documentation

Update `README.md` so the Codex supported workflows include:

```text
punts enrich and punts triage
```

The documentation should still state that Claude slash commands, settings,
hooks, and statusline remain Claude-specific. It should also make clear that
Codex punts support uses the existing `.claude/punts/` queue and does not add a
Codex Stop hook.
