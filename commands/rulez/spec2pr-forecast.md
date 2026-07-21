# Standalone Spec2PR Forecast

## Usage

`/rulez:spec2pr-forecast <path>`

Accept exactly one argument: a readable file path. Reject missing, unreadable, or extra input with usage text and stop before dispatch. This includes flags and extra positional arguments. A quoted path containing spaces remains one argument.

Resolve the current working directory as the repository to inspect. Before
dispatch, resolve its Git repository root. If the current working directory is
not in a Git repository, report the problem and stop.

Do not launch external claude, external codex, spec2pr, or spec2pr-split.

## Dispatch

Invoke the native Claude Agent tool exactly once, using its default model and
quota. Substitute the validated path for `<path>` and the resolved repository
root for `<repository-root>` in the prompt below. Do not retry or use a
fallback. If the native subagent fails or has no final response, report that
the forecast failed. If its response does not follow the requested format,
report that the response was malformed and do not infer a risk label.

Return the Agent result directly.

## Agent Prompt

Read <path> and relevant context in <repository-root>. If the supplied artifact has an obvious conventional companion spec or plan, read that too. Do not modify anything and do not launch another agent.

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
