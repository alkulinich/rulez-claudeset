# Standalone spec2pr forecast command

## Context

`spec2pr.sh` already forecasts implementation size after plan review and before
the implementation call. Its Claude-backed forecast estimates likely changed
LOC, converts LOC to bytes with `SPEC2PR_FORECAST_BYTES_PER_LINE`, and compares
the implementation-only estimate with `SPEC2PR_MAX_DIFF`. An over-limit result
stops the pipeline early with `SPEC2PR SPLIT forecast ...`, avoiding an
expensive implementation attempt that the later PR-size gate would reject.

That forecast is available only inside a running `spec2pr` pipeline. An
operator who already has a draft spec or plan cannot ask for the same early
size signal before deciding whether to refine or split the work. Running the
pipeline just to reach its forecast would spend review and planning calls that
the operator may not want.

This change adds a standalone forecast workflow to both Rulez adapters. It uses
one fresh subagent from the current tool rather than launching an external
model process. Codex forecasts therefore use a Codex subagent, while Claude
forecasts use a Claude subagent. Shared shell code owns input discovery,
prompt construction, result validation, arithmetic, reporting, and exit codes
so the two adapters expose the same contract.

## Settled decisions

- Codex invocation:

  ```text
  use rulez-tools to forecast <path>
  ```

- Claude invocation:

  ```text
  /rulez:spec2pr-forecast <path>
  ```

- The command accepts exactly one readable spec or plan path.
- The supplied file is sufficient. A conventional companion spec or plan is
  included automatically when one exists.
- The current working directory selects the target Git repository. The input
  artifact may live outside that repository.
- Each invocation launches exactly one fresh subagent using the current tool's
  default model and quota.
- No external `claude` or `codex` process is launched.
- Forecast results are not cached.
- Shell code, not the subagent, computes the byte estimate, utilization, risk
  band, verdict, and process exit code.
- Estimates below 80% of `SPEC2PR_MAX_DIFF` fit normally. Estimates from 80%
  through 100% emit a near-limit warning but still exit 0. Estimates above the
  limit emit `SPLIT` and exit 2.
- An over-limit response includes an advisory decomposition into two to four
  sequential parts. It does not create or edit any spec or plan.
- The existing automatic forecast in `spec2pr.sh` remains unchanged. It keeps
  its Claude subprocess, cache, and fail-soft pipeline semantics.
- `VERSION` and `UPGRADE.md` remain unchanged. Version bumps are deferred to a
  dedicated release step under the repository convention.

## Public interface

The Codex skill recognizes:

```text
use rulez-tools to forecast docs/superpowers/specs/foo-design.md
use rulez-tools to forecast docs/superpowers/plans/foo-design-plan.md
```

The Claude command recognizes the equivalent forms:

```text
/rulez:spec2pr-forecast docs/superpowers/specs/foo-design.md
/rulez:spec2pr-forecast docs/superpowers/plans/foo-design-plan.md
```

Both surfaces accept one path and no flags. Unknown options, missing paths, or
additional positional arguments are usage errors. Paths containing spaces are
preserved as one argument.

The command forecasts the implementation surface measured by spec2pr's later
PR-size gate. It does not count the supplied spec and plan documents as
implementation bytes. This makes the standalone verdict answer the operational
question: whether the implementation is likely to fit through spec2pr, not the
literal byte size of every documentation commit in a future PR.

## Architecture

### Shared two-phase helper

A new `scripts/spec2pr-forecast.sh` owns the deterministic portions of the
workflow. It has two adapter-facing subcommands:

```text
scripts/spec2pr-forecast.sh prepare <artifact-path> <run-dir>
scripts/spec2pr-forecast.sh evaluate <run-dir>
```

The adapter creates `<run-dir>` with `mktemp` outside the target repository.
`prepare` writes a manifest and `prompt.txt` into that directory. After the
native subagent finishes, the adapter writes its final response to
`result.txt`; `evaluate` reads the manifest and result, validates live state,
and renders the report.

The adapter calls `evaluate` even when the native agent tool fails or returns
no final response. In that case `result.txt` is absent, and the evaluator owns
the resulting `SPEC2PR HALT forecast: ...` line. This keeps failure wording and
exit behavior shared instead of duplicating them in the two adapter documents.

The run directory is transient orchestration state, not a cache. The adapter
removes it after every success or failure. Cleanup failure produces a warning
without replacing the forecast exit status.

### Native adapters

`adapters/codex/skills/rulez-tools/SKILL.md` gains a forecast command mapping
and workflow. It resolves `RULEZ_HOME`, creates the temporary run directory,
runs `prepare`, calls `spawn_agent` exactly once with the complete prompt,
saves the final response, and runs `evaluate`. It waits for that one agent and
does not launch fallback, review, or decomposition agents.

`commands/rulez/spec2pr-forecast.md` performs the same sequence with Claude's
native `Agent` tool. It tracks the current command through the existing
`set-current-command.sh` mechanism and launches exactly one general-purpose
agent. It does not call `claude -p`, Codex, or another Rulez command.

The adapters orchestrate tools only. They do not duplicate artifact discovery,
the forecast prompt, JSON validation, arithmetic, risk classification, or
terminal output wording.

## Input and companion discovery

`prepare` requires exactly one path to a readable regular file. It resolves the
path to an absolute path without requiring it to be inside the repository. It
resolves the repository separately with `git rev-parse --show-toplevel` from
the command's current working directory and halts before dispatch if there is
no repository.

The primary file always remains usable, including when its name is
nonstandard. Companion discovery is deterministic and best-effort:

- A primary basename ending in `-plan.md` is treated as a plan. Remove
  `-plan.md` and look for
  `<repo>/docs/superpowers/specs/<remaining-basename>.md`.
- Any other primary basename ending in `.md` is treated as a spec candidate.
  Look for
  `<repo>/docs/superpowers/plans/<basename-without-.md>-plan.md`.
- A non-Markdown primary is treated as a generic artifact and has no automatic
  companion.
- A missing or unreadable companion emits a warning and continues with the
  primary only. It is not a forecast failure.

At most one companion is selected. Explicitly supplying a second path is not
supported; this keeps both public commands at the approved `<path>` interface.

## State snapshot and read-only boundary

Before dispatch, `prepare` records:

- repository root and `HEAD`;
- a fingerprint of the staged diff;
- a fingerprint of the unstaged diff;
- a NUL-safe inventory and content fingerprint of untracked files reported by
  `git ls-files --others --exclude-standard`;
- the primary and companion absolute paths, roles, and SHA-256 hashes.

The temporary run directory must be outside the repository, so orchestration
files do not affect this snapshot.

The subagent prompt permits repository inspection and read-only Git commands.
It forbids editing, creating, deleting, committing, pushing, implementing,
running another agent, or writing anywhere in the repository. Its only task is
to estimate the implementation and return the required JSON as its final
response.

Before trusting the result, `evaluate` recomputes the complete snapshot and all
artifact hashes. A changed `HEAD`, staged or unstaged diff, untracked-file
inventory, or external artifact halts the forecast. The error identifies the
detected category and any paths available from Git status. The helper never
resets, cleans, checks out, or otherwise reverts changes because it cannot know
whether the agent or the user made a concurrent edit.

## Forecast prompt

The generated prompt is self-contained so Codex may dispatch it without
conversation history. It includes:

- repository root and expected `HEAD`;
- primary and optional companion paths, roles, and hashes;
- `SPEC2PR_FORECAST_BYTES_PER_LINE` and `SPEC2PR_MAX_DIFF` values;
- the exact output schema;
- the read-only and one-agent constraints;
- instructions to inspect the relevant code, tests, configuration, migrations,
  and documentation before estimating;
- instructions to enumerate every likely created or modified implementation
  file with rough added or changed LOC;
- instructions not to count the supplied spec or plan files;
- instructions to include two to four ordered advisory parts only when the LOC
  estimate, multiplied by the supplied bytes-per-line value, exceeds the
  supplied diff limit.

The agent estimates scope and LOC. It echoes the context identifiers so the
evaluator can prove that its response applies to the prepared artifacts and
repository revision. It does not own the final arithmetic or verdict.

## Agent result schema

The final response is one JSON object:

```json
{
  "repo_head": "0123456789abcdef",
  "artifacts": [
    {
      "role": "primary",
      "path": "/repo/docs/superpowers/specs/foo-design.md",
      "sha256": "abc123"
    },
    {
      "role": "companion",
      "path": "/repo/docs/superpowers/plans/foo-design-plan.md",
      "sha256": "def456"
    }
  ],
  "files": [
    {"path": "src/foo.ts", "loc": 180},
    {"path": "tests/foo.test.ts", "loc": 320}
  ],
  "total_loc": 500,
  "summary": "Add the foo model, integration wiring, and focused tests.",
  "parts": []
}
```

An over-limit result replaces the empty `parts` array with two to four ordered
objects:

```json
{
  "name": "Part 1: foo model",
  "scope": "Add the core data model and unit tests.",
  "files": ["src/foo.ts", "tests/foo.test.ts"],
  "depends_on": []
}
```

`depends_on` contains one-based part numbers and may refer only to earlier
parts. Part names are unique. Part file paths must appear in the top-level
`files` estimate; a path may appear in multiple advisory parts when the split
genuinely requires sequential edits to a shared file.

The evaluator accepts either bare JSON or exactly one fenced `json` block. It
rejects surrounding prose, multiple objects, unexpected properties, mismatched
repository or artifact identifiers, duplicate top-level file paths, empty file
paths, negative or non-integer LOC, a `total_loc` unequal to the sum of
`files[].loc`, an empty or multiline summary, invalid part counts, unknown part
files, and forward or nonexistent dependencies.

For a computed estimate at or below the limit, `parts` must be empty. For a
computed estimate above the limit, `parts` must contain two to four valid
entries. This conditional validation prevents a model-supplied verdict from
overriding deterministic arithmetic.

## Arithmetic and risk classification

The helper uses the existing spec2pr environment names and defaults:

```text
SPEC2PR_FORECAST_BYTES_PER_LINE=40
SPEC2PR_MAX_DIFF=131072
```

Both values must be positive integers. Invalid configuration halts during
`prepare`, before an agent is launched.

The evaluator computes:

```text
implementation_est_bytes = total_loc * SPEC2PR_FORECAST_BYTES_PER_LINE
utilization_percent = floor(implementation_est_bytes * 100 / SPEC2PR_MAX_DIFF)
```

It compares the warning boundary with integer cross-multiplication, so the 80%
classification does not depend on floating-point rounding:

- `estimate * 100 < limit * 80`: fits, exit 0;
- `estimate <= limit` and `estimate * 100 >= limit * 80`: near limit, exit 0;
- `estimate > limit`: split, exit 2.

An estimate exactly equal to the limit is near-limit, not split. This preserves
the existing pipeline rule that only an estimate greater than
`SPEC2PR_MAX_DIFF` is terminal.

## Human report and terminal contract

The evaluator prints a readable report containing:

- primary and discovered companion paths;
- total estimated LOC and implementation bytes;
- integer utilization percentage and risk classification;
- likely files ordered from largest to smallest LOC;
- the agent's one-line summary;
- the ordered advisory decomposition for an over-limit estimate.

The final status uses the established spec2pr forecast vocabulary:

```text
SPEC2PR OK forecast: fits est=<n> limit=<n>
SPEC2PR WARN forecast: near-limit est=<n> limit=<n> utilization=<p>%
SPEC2PR SPLIT forecast est=<n> limit=<n>
SPEC2PR HALT forecast: <reason>
```

The low-risk and near-limit forms exit 0. `SPLIT` is the final output line and
exits 2, so pasted output remains recognizable to existing spec2pr split
tooling. `HALT` exits 1. The report includes conventional
`docs/superpowers/specs/...` and `docs/superpowers/plans/...` paths when they
are available, allowing `spec2pr-split-context.sh` to recover them from a
pasted over-limit report.

## Failure handling

The standalone command is fail-loud because it has no implementation stage to
continue into:

- bad argument count, unreadable primary input, or no Git repository: halt
  before dispatch;
- invalid numeric configuration: halt before dispatch;
- native subagent launch failure, interruption, or missing final response:
  halt without retry;
- bare or fenced result that does not satisfy the schema: halt;
- stale repository revision, changed working state, or changed artifact:
  halt without using the estimate and without reverting;
- temporary-directory cleanup failure: warn without replacing the evaluator's
  exit status.

There is no automatic retry, second opinion, alternate model, cross-tool
fallback, cache lookup, automatic `spec2pr-split` invocation, or partial result
acceptance.

## Affected files

- Add `scripts/spec2pr-forecast.sh`:
  - implement `prepare` and `evaluate`;
  - discover companion context;
  - snapshot and compare read-only state;
  - build the shared prompt and manifest;
  - validate agent JSON;
  - calculate and render the forecast contract.
- Add `commands/rulez/spec2pr-forecast.md`:
  - expose `/rulez:spec2pr-forecast <path>`;
  - run the shared two-phase protocol with one Claude Agent.
- Modify `adapters/codex/skills/rulez-tools/SKILL.md`:
  - add forecasting to its description and trigger list;
  - add the Codex command mapping and one-subagent workflow.
- Modify `settings.json`:
  - allow the installed Claude command to run
    `scripts/spec2pr-forecast.sh`.
- Modify `README.md`:
  - document both command surfaces, outputs, risk band, and the difference from
    the automatic pipeline forecast.
- Add `tests/spec2pr/test-standalone-forecast.sh`:
  - exercise the prepare/evaluate protocol and Claude command contract.
- Modify `tests/codex/test-setup-codex.sh`:
  - verify the installed skill exposes and constrains the Codex workflow.

No installer change is needed. Claude commands are already installed through
the linked `commands/rulez` directory, and Codex consumes the linked
`rulez-tools` skill. The current `spec2pr.sh` forecast implementation and tests
remain unchanged.

## Testing and verification

Automated shell coverage includes:

- primary spec, primary plan, generic artifact, external artifact, and paths
  containing spaces;
- companion discovery in both directions and primary-only fallback;
- manifest hashes, prompt constants, schema, and read-only instructions;
- bare JSON and a single fenced JSON result;
- low-risk, first integer at or above 80%, exact-limit, and first-over-limit
  boundary cases;
- exact terminal lines and exit codes 0, 1, and 2;
- two-to-four-part ordering, file references, and dependency validation;
- malformed JSON, surrounding prose, extra fields, duplicate files,
  inconsistent totals, stale hashes, and missing output;
- changed `HEAD`, staged diff, unstaged diff, untracked files, and external
  artifact content;
- the Codex skill's exact invocation, one `spawn_agent` rule, shared helper
  delegation, and prohibition on external model processes;
- the Claude command's exact invocation, one native `Agent` rule, shared helper
  delegation, and prohibition on external model processes;
- the Claude permission allowlist entry and README examples.

Run:

```bash
bash -n scripts/spec2pr-forecast.sh
bash tests/spec2pr/run-tests.sh
bash tests/codex/run-tests.sh
```

Manual Codex smoke verification uses a disposable repository and one small
spec. Invoke `use rulez-tools to forecast <path>`, confirm that exactly one
subagent runs, and confirm the evaluator reports the expected paths, arithmetic,
and exit class without modifying the repository.

Claude orchestration is contract-tested statically because the Bash test suite
cannot invoke Claude's interactive `Agent` tool. The shared executable protocol
and all forecast decisions still receive direct shell coverage.

## Out of scope

- Changing or replacing the automatic forecast inside `spec2pr.sh`.
- Caching standalone forecasts.
- Running more than one forecast agent or calculating a consensus.
- Selecting a model or quota independently from the current tool.
- Generating, editing, or committing split specs or plans.
- Automatically invoking `/rulez:spec2pr-split`.
- Forecasting an existing PR or measured diff.
- Adding the standalone command to `mctl` or `spec2pr-chain`.
- Changing `SPEC2PR_MAX_DIFF` or `SPEC2PR_FORECAST_BYTES_PER_LINE` defaults.
- Releasing a new Rulez version.
