# Spec2PR

Run a brainstormed spec unattended through codex to a reviewed, open PR:
spec-review → plan → plan-review → implement → PR-review → "PR ready".

## Usage

- `/rulez:spec2pr <spec-path>` — start (or resume) a run
- `/rulez:spec2pr --ignore-plan-limit <spec-path>` — proceed even if the plan
  file exceeds the size limit
- `/rulez:spec2pr --ignore-pr-limit <spec-path>` — proceed even if the
  forecast (or the final diff) exceeds the PR diff limit
- `/rulez:spec2pr status` — show the latest state of every run

## Instructions

If the argument is `status`:

1. Run:
   `RULEZ_CLAUDESET_HOME="${RULEZ_CLAUDESET_HOME:-$HOME/.rulez-claudeset}"; SPEC2PR_HOME="${SPEC2PR_HOME:-$RULEZ_CLAUDESET_HOME/spec2pr}"; for f in "$SPEC2PR_HOME"/*.status; do [ -f "$f" ] && printf '%s -> %s\n' "$(basename "$f" .status)" "$(tail -1 "$f")"; done`
2. Present the result as-is. Stop.

Otherwise parse optional leading flags from the argument list:

1. Accepted flags are `--ignore-plan-limit` and `--ignore-pr-limit`.
2. Require exactly one remaining value, the spec path.
3. If any other flag is present, or the remaining values are anything other
   than exactly one spec path, show the Usage forms and stop.
4. Preserve the accepted flags in their original order as `SPEC2PR_FLAGS`.
5. If the file does not exist, tell the user and stop.
6. `SPEC2PR_FORECAST=0` disables the pre-implement forecast step.
7. Launch the pipeline as a **background** Bash task (single call,
   `run_in_background: true`):
   `bash ~/.claude/skills/rulez-claudeset/scripts/spec2pr.sh ${SPEC2PR_FLAGS} <spec-path>`
   If no flags were supplied, launch with only `<spec-path>` as before.
8. Tell the user the run has started, that a completion notification will
   arrive in this session, and that `/rulez:spec2pr status` shows progress
   meanwhile. Do not poll.

When the background task completes, read the last `SPEC2PR` line of its
output and react:

- `DONE pr=<url> worktree=<path>` — offer to review the PR and run tests in
  the worktree before merging.
- `SPLIT forecast est=<n> limit=<n>` — the pre-implement forecast predicts the
  PR diff will exceed the limit; no implement call was spent. Recommended split
  parts are printed just above the SPLIT line. Run `/rulez:spec2pr-split` with
  the output, or re-run with `--ignore-pr-limit` to force the run through.
- `SPLIT <what> size=<n> limit=<n>` — recommend splitting the spec into
  smaller specs and rerunning each.
- `DIRTY <stage> ... log=<path>` — review cap hit; show the findings from the
  log file.
- `HALT <stage>: <reason>` — show the reason and point at the log dir
  `$SPEC2PR_HOME/<id>/` (default `~/.rulez-claudeset/spec2pr/<id>/`).
