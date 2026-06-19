# Spec2PR

Run a brainstormed spec unattended through codex to a reviewed, open PR:
spec-review → plan → plan-review → implement → PR-review → "PR ready".

## Usage

- `/rulez:spec2pr <spec-path>` — start (or resume) a run
- `/rulez:spec2pr status` — show the latest state of every run

## Instructions

If the argument is `status`:

1. Run:
   `for f in ~/.rulez-claudeset/spec2pr/*.status; do [ -f "$f" ] && printf '%s -> %s\n' "$(basename "$f" .status)" "$(tail -1 "$f")"; done`
2. Present the result as-is. Stop.

Otherwise the argument is a spec path:

1. If the file does not exist, tell the user and stop.
2. Launch the pipeline as a **background** Bash task (single call,
   `run_in_background: true`):
   `bash ~/.claude/skills/rulez-claudeset/scripts/spec2pr.sh <spec-path>`
3. Tell the user the run has started, that a completion notification will
   arrive in this session, and that `/rulez:spec2pr status` shows progress
   meanwhile. Do not poll.

When the background task completes, read the last `SPEC2PR` line of its
output and react:

- `DONE pr=<url> worktree=<path>` — offer to review the PR and run tests in
  the worktree before merging.
- `SPLIT <what> size=<n> limit=<n>` — recommend splitting the spec into
  smaller specs and rerunning each.
- `DIRTY <stage> ... log=<path>` — review cap hit; show the findings from the
  log file.
- `HALT <stage>: <reason>` — show the reason and point at the log dir
  `~/.rulez-claudeset/spec2pr/<id>/`.
