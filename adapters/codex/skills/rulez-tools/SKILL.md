---
name: rulez-tools
description: "Use for Rulez shared tooling in Codex: GitHub workflows, cycle heartbeat watchers, standalone spec2pr forecasting, handoffs, and punts backed by this repository's scripts."
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
- Cycle prompt: `scripts/cycle-prompt.sh <reviewer|fixer|verifier> heartbeat <spec|plan|PR> <target...>`

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

When the user says `use rulez-tools to cycle <reviewer|fixer|verifier> <spec|plan|PR> <target(s)>`:

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

Use this workflow when the user says `use rulez-tools to cycle <reviewer|fixer|verifier> <spec|plan|PR> <target(s)>`.

Codex desktop launches durable cycle watchers as Scheduled heartbeats attached to the current task. The public Codex syntax has no `loop|goal` mode selector. One invocation starts one watcher in the current task; start reviewer, verifier, and fixer watchers in separate tasks. A reviewer and verifier may watch the same PR at once; they use separate `## Review round <N>` and `## Verification round <N>` comment channels, and the PR fixer consumes both.

Target forms:

```text
spec <spec.md>
plan <plan.md> [<spec.md>]
PR <#n|n>
```

Workflow:

1. Parse the arguments as `<role> <type> <target(s)>`. Require `role` to be `reviewer`, `fixer`, or `verifier`, `type` to be `spec`, `plan`, or `PR`, and at least one non-empty target. Reject `verifier spec` and `verifier plan` before running the builder, saying that `verifier` is PR-only. On other parse failures, print `use rulez-tools to cycle <reviewer|fixer|verifier> <spec|plan|PR> <target(s)>` and stop without changing automation state. Leave detailed target validation to the shared builder.
2. Require the Codex app `automation_update` capability. If it is unavailable, report `Durable Rulez cycles require Codex desktop Scheduled tasks.` and stop. Do not fall back to a persisted goal, a sleeping shell, or an external scheduler.
3. Resolve `RULEZ_HOME` using the repository-layout rule above. Run `bash "$RULEZ_HOME/scripts/cycle-prompt.sh" <role> heartbeat <type> <target...>`, preserving each target as a separate shell argument and capturing stdout as `PROTOCOL`. If the builder exits nonzero, show its stderr unchanged and stop without changing an automation.
4. Resolve the target project's physical Git root. Use a normalized GitHub `owner/repo` from `origin` as the repository identity when available; otherwise use the physical root. Normalize PR targets to a bare number. Normalize spec and plan targets to absolute lexical paths based on the repository root without requiring the watched file to exist.
5. Build an exact `rulez_cycle_key` from the repository identity, role, type, and normalized targets. Include the key as a machine-readable line in the heartbeat prompt and include a concise role/type/target label in the automation name.
6. Follow the `automation_update` capability's supported existing-automation lookup: inspect `$CODEX_HOME/automations/*/automation.toml` for the exact `rulez_cycle_key` marker. Reuse one exact match, whether active or paused. If more than one exact match exists, report the duplicate state and stop without creating another heartbeat.
7. Initialize `idle_level=0` and `failure_count=0`. Run the first watcher tick immediately. Apply `PROTOCOL` once against the current watched state and classify the result as `activity`, `idle`, `complete`, or `error` using the rules below.
8. A complete first tick creates no heartbeat. A first-tick human-action error creates no active heartbeat and reports the blocker. A transient first-tick read failure creates or updates the heartbeat with `failure_count=1` and a five-minute retry. Activity and idle outcomes create or update the heartbeat with the state and delay selected below.
9. Attach the heartbeat to the current task. Its prompt contains `rulez_cycle_key`, repository root, role, type, normalized targets, the complete `PROTOCOL`, `idle_level`, and `failure_count`. The runtime supplies the heartbeat's id on every scheduled trigger, so creation is one step; do not create a bootstrap automation merely to embed an id in its prompt.
10. Report the role, artifact type, target, whether the heartbeat was created or refreshed, and the next delay. Re-launching the same cycle refreshes the existing heartbeat from the current Rulez version and resets its next delay to five minutes instead of creating a duplicate.

### Heartbeat Tick

Every scheduled tick receives a trigger-provided `<automation_id>`. Validate the prompt metadata, change to the recorded repository root, run the complete watcher protocol once, and update only that same automation. Preserve its full current fields when calling `automation_update`; change only the prompt state, next interval, or status required by the outcome.

Scheduler state is only `idle_level` and `failure_count`. GitHub comments, PR head SHAs, and findings-file revisions remain authoritative for handled work.

- `activity`: after a successful non-terminal review, verification, fix, or rationale response, reset `idle_level` to `0`, clear `failure_count`, and schedule the next tick in five minutes.
- `idle`: write no artifact, commit, PR comment, or task message. Clear `failure_count`; from idle levels `0`, `1`, and `2`, wait 5, 10, then 15 minutes and store levels `1`, `2`, and `2` respectively. Further idle ticks remain at 15 minutes.
- `complete`: delete the heartbeat and notify once. Do not schedule another tick.
- `error`: a transient read failure leaves `idle_level` unchanged. The first and second consecutive failures update the same heartbeat to retry after five and ten minutes. On the third consecutive transient failure, set status `PAUSED` and notify with the last error. Any authentication, approval, malformed-state, or partial-write failure pauses immediately and notifies.

Any successful read clears `failure_count`, including an idle read. Meaningful activity always resets the next wait to five minutes. A PR fixer must still push and verify the new PR head before posting `fixed`. Never create an idle commit or comment, and never process a review or verification round twice.

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

This skill currently covers GitHub workflow, cycle heartbeat watchers, standalone spec2pr forecasting, handoff, punts enrich, and punts triage workflows. It does not install or manage Codex hooks, statusline behavior, `what-have-i-done`, `.codex/punts/`, or Claude transcript/session storage.
