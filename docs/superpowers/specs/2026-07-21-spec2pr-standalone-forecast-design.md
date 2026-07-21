# Lightweight standalone spec2pr forecast

## Context

`spec2pr.sh` already runs a Claude-backed size forecast after plan review and
before implementation. That pipeline forecast estimates implementation LOC,
converts it to bytes, and stops early when it predicts that the later 131072
byte PR-diff gate will reject the implementation.

The operator also needs a cheaper signal before starting spec2pr. Given a draft
spec or plan, they want to know whether the work is probably small enough for
one PR or should be split first. This decision does not need a validated byte
prediction. Model-generated LOC is approximate, and presenting exact arithmetic
would imply precision the forecast does not have.

This change adds a lightweight forecast command to both Rulez adapters. One
fresh subagent from the current tool reads the artifact and relevant repository
context, then reports a qualitative risk of exceeding 131072 bytes.

## Settled decisions

- Codex invocation:

  ```text
  use rulez-tools to forecast <path>
  ```

- Claude invocation:

  ```text
  /rulez:spec2pr-forecast <path>
  ```

- Each invocation launches exactly one native subagent using the current
  tool's default model and quota.
- The subagent receives a short, shared forecast prompt defined verbatim in
  both adapter documents.
- It reads the supplied spec or plan, an obvious conventional companion when
  present, and enough repository context to judge implementation scope.
- It is read-only. It does not edit files, implement the work, run spec2pr,
  create split specs, commit, push, or launch another agent.
- The output uses `LOW`, `MEDIUM`, or `HIGH` risk. It does not claim an exact
  byte estimate or numeric probability.
- The output includes a rough changed-LOC range, main reasons, and an advisory
  split only for `MEDIUM` or `HIGH` risk.
- There is no helper script, JSON schema, cache, state manifest, deterministic
  byte conversion, status token, or process exit-code contract.
- The existing automatic forecast inside `spec2pr.sh` remains unchanged.
- `VERSION` and `UPGRADE.md` remain unchanged under the repository's release
  convention.

## Public interface

Both commands accept exactly one readable file path. The current working
directory is the repository to inspect. The artifact may be outside that
repository.

The adapters reject a missing path or additional arguments before dispatch.
A quoted path containing spaces remains one argument. A missing conventional
companion is normal and does not block forecasting.

The final response has this shape:

```text
Risk: LOW | MEDIUM | HIGH
Expected size: <rough changed-LOC range>
Reasons:
- <reason>
- <reason>
Suggested split:
- <part>
- <part>
```

`Suggested split` is omitted for `LOW`. For `MEDIUM` or `HIGH`, it contains two
to four sequential, independently implementable parts. This is advice only;
the command creates no files.

Risk meanings:

- `LOW`: comfortably unlikely to exceed a 131072 byte PR diff.
- `MEDIUM`: plausibly near or above the limit; splitting should be considered.
- `HIGH`: likely to exceed the limit; split before running spec2pr.

The rough LOC range is supporting evidence, not a value converted into a byte
verdict. The model judges the likelihood directly from scope and repository
context.

## Forecast prompt

Both adapters use this prompt, substituting the path and repository root:

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

The two adapter files intentionally duplicate this small prompt. A shared
builder would add more machinery than the prompt warrants. Static tests keep
the copies aligned on the threshold, risk labels, output headings, one-agent
rule, and read-only constraints.

## Adapter behavior

### Codex

`adapters/codex/skills/rulez-tools/SKILL.md` adds the command mapping and a
short Standalone Forecast workflow. It validates the path, resolves the current
repository root, calls `spawn_agent` exactly once with the forecast prompt,
waits for the result, and returns the subagent's forecast without adding a
second estimate.

The command itself explicitly authorizes this one forecast subagent. It does
not authorize a retry, reviewer, implementation agent, or split agent.

### Claude

`commands/rulez/spec2pr-forecast.md` exposes the slash command, validates the
path, resolves the repository root, and invokes the native `Agent` tool exactly
once with the same prompt. It returns the Agent result directly.

No new shell permission is required because the command does not invoke a new
Rulez script or external model process.

## Error handling

- Missing, unreadable, or extra input: show usage and stop before dispatch.
- No Git repository at the current working directory: report the problem and
  stop before dispatch.
- Native subagent failure or missing final response: report that the forecast
  failed. Do not retry or fall back to another tool.
- Malformed response: report that the agent did not follow the output format.
  Do not attempt to infer or manufacture a risk label.

The read-only boundary is prompt-enforced. The feature does not add repository
fingerprinting or rollback logic. Existing global agent rules still prohibit
unrequested edits, and this forecast does not need transactional machinery.

## Affected files

- Add `commands/rulez/spec2pr-forecast.md` for the Claude command.
- Modify `adapters/codex/skills/rulez-tools/SKILL.md` for the Codex mapping and
  workflow.
- Modify `tests/codex/test-setup-codex.sh` for the Codex static contract.
- Add `tests/spec2pr/test-standalone-forecast.sh` for the Claude command and
  shared prompt-copy contract.
- Modify `README.md` with both invocations and risk meanings.

No script, settings, installer, pipeline, version, or upgrade-guide file
changes.

## Testing

Static tests verify:

- both exact public invocations;
- the `131072` threshold and `LOW`, `MEDIUM`, `HIGH` labels;
- the rough LOC, Reasons, and conditional Suggested split headings;
- exactly one native-agent instruction in each adapter;
- read-only and no-nested-agent language;
- no references to a shared helper, external `claude`, external `codex`, cache,
  JSON, or exact-byte arithmetic;
- README examples and risk descriptions.

Run:

```bash
bash tests/spec2pr/run-tests.sh
bash tests/codex/run-tests.sh
```

A manual Codex smoke uses a small disposable spec and confirms that one
subagent returns the required qualitative format without editing the target
repository. Claude's native Agent orchestration is covered by the command
contract because the shell suite cannot invoke an interactive Claude tool.

## Out of scope

- Predicting an exact PR byte count.
- Converting approximate LOC into a deterministic verdict.
- Machine-readable output or exit codes.
- Caching or comparing forecasts.
- Multiple estimators, consensus, confidence percentages, or retries.
- Automatically splitting specs or plans.
- Changing the automatic forecast in `spec2pr.sh`.
- Adding the command to `mctl` or `spec2pr-chain`.
- Releasing a new Rulez version.
