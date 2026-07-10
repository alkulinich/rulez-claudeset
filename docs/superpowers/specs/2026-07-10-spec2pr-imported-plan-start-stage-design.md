# spec2pr imported-plan start stages

## Context

`scripts/spec2pr.sh` can restart an existing managed worktree with
`--start-from plan-review` or `--start-from implementation`, but it rejects
those forms for a fresh run. It also accepts only a spec path, so a user who
already has an approved implementation plan must still spend model calls on
spec review, plan generation, and plan review before implementation.

Add an optional second positional path that imports a trusted plan into a new
managed worktree. The selected start stage must be a real execution boundary:
stages before it are not invoked and do not perform an "already done" model
decision.

## Settled decisions

- The CLI uses a second positional path, not a new flag.
- A plan path is valid only with an explicit `--start-from plan-review` or
  `--start-from implementation`.
- The plan source may be any readable regular file; it does not need to be
  inside the spec's Git repository.
- The source plan is immutable for the managed run. Its canonical source path
  and SHA-256 are recorded. A missing, moved, or changed source plan halts a
  later run rather than replacing the imported plan.
- A supplied plan is copied to the existing canonical worktree path,
  `docs/superpowers/plans/<spec-slug>-plan.md`.
- Existing one-file runs and legacy worktrees keep their current behavior.
- Forecast, implementation, PR creation, and PR review remain unchanged.

## CLI contract

Existing forms remain valid:

```bash
scripts/spec2pr.sh path/to/spec.md
scripts/spec2pr.sh --start-from implementation path/to/spec.md
```

New forms:

```bash
scripts/spec2pr.sh --start-from plan-review path/to/spec.md path/to/plan.md
scripts/spec2pr.sh --start-from implementation path/to/spec.md path/to/plan.md
```

The usage suffix becomes:

```text
<spec-path> [plan-path]
```

Argument validation happens before worktree creation:

- More than two positional paths is usage failure.
- A second positional path without an explicit `--start-from` is usage
  failure.
- A second positional path with `--start-from spec-review` or
  `--start-from plan` is usage failure.
- A missing, non-regular, or unreadable plan halts in preflight.
- The existing plan size limit applies to imported plans. Oversized plans
  produce the existing `SPLIT plan` result unless `--ignore-plan-limit` is
  supplied.

## Import and metadata flow

The spec remains responsible for locating the Git root and deriving the run
ID, worktree, branch, and canonical plan destination. The plan path is
canonicalized independently with its physical parent directory, so it may live
outside that repository.

For a fresh two-file run:

1. Validate and hash both source artifacts before worktree mutation.
2. Allow the otherwise-prohibited fresh `--start-from` invocation because a
   source plan was supplied.
3. Create the managed worktree using the existing branch and base logic.
4. Import and commit the spec with the existing `spec2pr: import spec`
   subject.
5. Copy the plan to `WT_PLAN_REL` and commit it separately as
   `spec2pr: write plan`. Use an allow-empty commit so this boundary exists
   even when the base branch already contains identical plan content.
6. Write `plan-source-path` and `plan-source-sha256` under `META_DIR`.
7. Write the existing `plan.json` artifact with the canonical worktree path
   and a deterministic imported-plan summary. No model generates this summary.

Keeping the `spec2pr: write plan` subject preserves the existing restart
boundary lookup and PR links without adding a second plan representation.

## Resume rules

Worktrees initialized from a supplied plan validate `plan-source-path` and
`plan-source-sha256` before reset, model calls, or other worktree mutation.
When a plan argument is supplied again, its canonical path and hash must match
the recorded values exactly. When it is omitted, the recorded path is read and
validated directly. A missing metadata file, missing source file, path
mismatch, or hash mismatch halts with a specific preflight error.

Imported-plan metadata is an atomic pair: both files present means an imported
plan; both absent means legacy state. If exactly one file exists, preflight
halts because the managed state is incomplete.

Legacy worktrees have neither imported-plan metadata file:

- A one-file resume retains all current behavior.
- Supplying a plan to a legacy worktree halts instead of adopting or replacing
  its committed plan.

An explicit restart from `spec-review` or `plan` discards the imported plan as
part of the existing rewind. That restart also removes imported-plan metadata,
after which the run follows the legacy generated-plan path. Validation of the
old source plan must not prevent this explicit discard operation.

## Stage execution

The existing `START_INDEX` gates remain the only stage-routing mechanism:

- `--start-from plan-review` sets index 3. The spec-review block and plan
  generation block are not entered. Execution begins with `review_loop
  plan-review`.
- `--start-from implementation` sets index 4. The spec-review, plan generation,
  and plan-review blocks are not entered. Execution continues with forecast
  and implementation.

Skipping means the earlier stages create no prompts, JSON results, review-fix
commits, status entries, Codex calls, or Claude calls. The orchestrator does not
ask a model whether an earlier stage is already complete.

Dependency checks remain part of preflight because later stages still use both
CLIs. Forecast still runs unless `SPEC2PR_FORECAST=0`; PR review still runs
after implementation. Neither is considered one of the skipped stages.

## Error handling and invariants

- Source validation precedes model calls and worktree mutation where possible.
- Imported plan content in the worktree always matches the recorded source
  hash at initialization.
- Every fresh imported-plan run has both standard boundary commits, even when
  either import is identical to a file already on the base branch.
- Resume never silently adopts a different plan or source path.
- Existing open-PR and remote-branch restart protections remain in force.
- Existing implementation backup-tag behavior remains in force when restarting
  implementation in a managed imported-plan worktree.
- The one-file no-flag pipeline remains behaviorally unchanged.

## Affected files

- `scripts/spec2pr.sh`
  - Parse an optional second positional argument.
  - Validate allowed start stages and plan source properties.
  - Permit fresh start-stage runs only when a plan is supplied.
  - Import the plan, write metadata, and create the standard plan commit.
  - Validate or clear imported-plan metadata during resumes.
- `tests/spec2pr/test-preflight.sh`
  - Cover argument grammar, source validation, size handling, and fresh
    worktree import metadata.
- `tests/spec2pr/test-resume-recovery.sh`
  - Cover imported-plan resume identity, changed-source halts, legacy
    compatibility, and explicit discard through earlier restart stages.
- `tests/spec2pr/test-stages.sh`
  - Prove exact model-call and artifact behavior for both new start stages.
- `README.md`
  - Document the two imported-plan invocation forms and their true skip
    semantics.
- `VERSION` and `UPGRADE.md`
  - Record the new backward-compatible CLI capability using the repository's
    normal versioning convention.

## Test contract

The test suite must cover:

- Fresh `implementation spec plan` import reaches implementation with fixtures
  only for forecast, implementation, and PR review.
- Fresh `plan-review spec plan` import invokes plan review first, then the
  unchanged downstream stages.
- Invocation logs contain no hidden model calls for skipped stages.
- Skipped-stage prompt, JSON, status, and review-fix artifacts do not exist.
- The worktree plan content matches the supplied source, and Git history
  contains the standard spec and plan boundary commits.
- Plan source metadata contains the canonical absolute source path and its
  SHA-256.
- Same-path, same-hash resume succeeds.
- Missing, moved, changed, or mismatched plan sources halt before model calls
  or reset.
- Missing, unreadable, and oversized input plans take their specified preflight
  paths; `--ignore-plan-limit` preserves the existing override behavior.
- A plan argument is rejected for absent, `spec-review`, and `plan` start-stage
  selections, and a third positional argument is rejected.
- A plan argument against a legacy worktree is rejected, while an ordinary
  legacy one-file resume is unchanged.
- Explicit restart from `spec-review` or `plan` removes imported-plan metadata
  and returns to generated-plan behavior.
- The full existing `tests/spec2pr/run-tests.sh` suite stays green.

## Out of scope

- Replacing or refreshing an imported plan in an existing managed worktree.
- Inferring a start stage merely because a second positional path is present.
- Skipping forecast or PR review through new CLI flags.
- Changing canonical plan naming or accepting multiple plan files.
- Extending `mctl` or `spec2pr-chain` with the second-file form.
