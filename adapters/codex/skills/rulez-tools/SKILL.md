---
name: rulez-tools
description: "Use for Rulez shared tooling in Codex: GitHub workflows, cycle goal watchers, standalone spec2pr forecasting, handoffs, and punts backed by this repository's scripts."
---

# Rulez Tools

Use this skill when the user asks Codex to use `rulez-tools`, or asks for Rulez-style GitHub workflow tasks such as starting an issue, creating a PR, testing a PR, pushing fixes, merging a PR, launching a cycle watcher, running standalone spec2pr forecasting, writing a handoff, enriching punts, or triaging punts.

## Repository Layout

This skill is installed as a symlink from:

```text
~/.codex/skills/rulez-tools
```

to:

```text
<rulez-tools-repo>/adapters/codex/skills/rulez-tools
```

Resolve the shared repository root from this skill file before running scripts:

```bash
RULEZ_HOME="$(cd "<directory-containing-this-SKILL.md>/../../../.." && pwd)"
```

When working inside this repository, `RULEZ_HOME` is the repo root. In normal Codex use, infer the same root from the installed skill location.

## Shared Scripts

Prefer the shared scripts over reimplementing workflow logic:

- Start issue: `scripts/git-start-issue.sh <issue-number> [branch-name]`
- Create PR: `scripts/git-create-pr.sh <branch> <base> <title> <body> <files...>`
- Test PR: `scripts/git-test-pr.sh <pr-number>`
- Push fixes: `scripts/git-push-fixes.sh <message> <files...>`
- Merge PR: `scripts/git-merge-pr.sh <pr-number>`
- Handoff: `scripts/git-commit-handoff.sh`
- Cycle prompt: `scripts/cycle-prompt.sh <reviewer|fixer> goal <spec|plan|PR> <target...>`

Run these scripts by absolute path from the target project workspace. The Git workflow scripts operate on the current working directory.

## Codex Workflow Rules

- Inspect `git status --short` before workflows that create commits, push branches, open PRs, or merge PRs.
- Inspect the relevant diff before creating a PR, pushing fixes, or writing a handoff.
- Follow Codex sandbox and approval behavior. Do not assume Claude permissions from `settings.json`.
- Do not rely on Claude-only tool names such as `AskUserQuestion`, `Agent`, `Write`, `TodoWrite`, or `EnterPlanMode`.
- Edit files using Codex-native rules. For manual repo edits, prefer `apply_patch`.
- Use Codex subagents only when the user explicitly asks for subagents, delegation, or parallel agent work.
- Treat `RULEZ.md` as shared behavioral guidance.
- Treat `CLAUDE.md` as Claude-specific unless a rule is clearly tool-agnostic.

## Command Mapping

When the user says `use rulez-tools to start issue 123`:

1. Check the current repo status.
2. From the target project workspace, run `"$RULEZ_HOME/scripts/git-start-issue.sh" 123`.
3. Summarize the issue title, branch, and any warnings or failures.

When the user says `use rulez-tools to create PR`:

1. Check status and diff.
2. Ensure the branch and changes are appropriate for a PR.
3. Gather or derive the branch name, PR title, PR body, and exact file list to stage. Treat `main` as the fixed base branch for the current script.
4. From the target project workspace, run `"$RULEZ_HOME/scripts/git-create-pr.sh" "$branch" main "$title" "$body" "${files[@]}"`.
5. Report the PR URL or the blocking error.

When the user says `use rulez-tools to test PR 5`:

1. From the target project workspace, run `"$RULEZ_HOME/scripts/git-test-pr.sh" 5`.
2. Follow the script output and run any project-specific verification it requests.
3. Report failures first, then passing checks.

When the user says `use rulez-tools to push fixes`:

1. Check status and diff.
2. Confirm the changes belong to the current PR or branch.
3. Gather or derive a focused commit message and exact file list to stage.
4. From the target project workspace, run `"$RULEZ_HOME/scripts/git-push-fixes.sh" "$message" "${files[@]}"`.
5. Report the pushed branch or any blocker.

When the user says `use rulez-tools to merge PR 5`:

1. Check whether the working tree has unrelated local changes.
2. From the target project workspace, run `"$RULEZ_HOME/scripts/git-merge-pr.sh" 5`.
3. Report the merge result and cleanup status.

When the user says `use rulez-tools to write handoff`:

1. Inspect status, recent commits, and relevant context.
2. Create or update `HANDOFF.md` in the target repository root.
3. From the target repository root, run `"$RULEZ_HOME/scripts/git-commit-handoff.sh"`.
4. Report the committed handoff or any missing information needed to finish it.

When the user says `use rulez-tools to cycle <reviewer|fixer> <spec|plan|PR> <target(s)>`:

1. Use the `Cycle Watcher` workflow below.
2. Report the launched role, artifact type, and target, or the blocking error.

When the user says `use rulez-tools to enrich punts`:

1. Use the `Punts Enrich` workflow below.
2. Report `enriched=N failed=M skipped_no_slice=K already_structured=L`.
3. If failures remain, explain that raw files and slice files were preserved for retry.

When the user says `use rulez-tools to triage punts`:

1. Use the `Punts Triage` workflow below.
2. Ask for one decision per evidence row.
3. Do not bulk-approve rows.

## Standalone Forecast

When the user says `use rulez-tools to forecast <path>`:

1. Accept exactly one readable file path. Reject a missing path, an unknown option, or any additional positional argument with usage text and stop before dispatch. A quoted path containing spaces remains one argument.
2. Resolve the current working directory as the repository root with Git. If the current working directory is not inside a Git repository, report the problem and stop before dispatch.
3. Call `spawn_agent` exactly once with `fork_context: false`, using a fresh context with no forked conversation context. The complete task is the forecast prompt below, with the validated path and repository root substituted. Wait for the result and return the subagent's forecast without re-estimating or adding a second estimate.
4. This command authorizes this one forecast subagent only: no retry, reviewer, implementation agent, or split agent. If the subagent fails or has no final response, report that the forecast failed. If its response does not follow the requested format, report that the response was malformed and do not infer a risk label.

Do not run external `claude`, external `codex`, `spec2pr`, or `spec2pr-split` for this workflow.

### Forecast Prompt

Use this prompt as the complete task for the single `spawn_agent` call:

```text
Read <path> and relevant context in <repository-root>. If the supplied artifact
has an obvious conventional companion spec or plan, read that too. Do not
modify anything and do not launch another agent.

Estimate the likelihood that implementing this spec or plan will produce a PR
diff larger than 131072 bytes. Consider implementation code, tests, migrations,
configuration, and documentation. This is an approximate forecast; do not
claim an exact byte count or numeric probability.

Return only:
Risk: LOW, MEDIUM, or HIGH
Expected size: a rough changed-LOC range
Reasons:
- concise reason
- concise reason

For MEDIUM or HIGH, also return:
Suggested split:
- 2-4 sequential, independently implementable parts

For LOW, omit Suggested split.
```

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

## First-Pass Scope

This skill currently covers GitHub workflow, cycle goal watchers, handoff, punts enrich, and punts triage workflows. It does not install or manage Codex hooks, statusline behavior, `what-have-i-done`, `.codex/punts/`, or Claude transcript/session storage.
