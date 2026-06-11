# spec2pr — Design

## Goal

One bash script that takes a spec produced by `superpowers:brainstorming`
and runs it unattended through codex to a reviewed, open PR:

spec-review → plan → plan-review → implement → PR-review → "PR ready".

The human brainstorms in Claude (where it is strongest) and reviews the
finished PR. Codex does all heavy lifting (faster, equally reliable at
implementation, and cross-model review happens for free when the human +
Claude review the PR at the end).

This replaces the abandoned `feat/auto-pipeline` design (18k lines:
Workflow runtime, LLM-interpreted shim, helper layer). Reliability comes
from fresh-context reviews and world-derived resume instead of defensive
code. Target size: script ~250–350 lines, slash command ~40, test ~150.

## Decisions

| # | Decision | Choice |
|---|----------|--------|
| 1 | Orchestrator | Plain bash script. No Workflow, no subagents, no state machine. |
| 2 | Run mode | Fully unattended, spec → PR. No checkpoints in v1. |
| 3 | Loop termination | `--output-schema` counts; clean = a fresh round finds 0 blockers/majors *before* fixing anything. |
| 4 | Worktree | Script creates branch + worktree before any codex call. Codex never creates its own. |
| 5 | Auto-merge | None in v1. Pipeline stops at "PR ready"; human merges. |
| 6 | Resume | Derived from the world (worktree / plan file / open PR), no state file. |
| 7 | Size gates | Spec, plan, and PR diff each gated; over limit → halt with "split the spec". |
| 8 | Codex sandbox | User's global codex config (auto-review approvals). No flags in the script. |
| 9 | Name / home | `spec2pr`. Ships in rulez-claudeset: `scripts/spec2pr.sh` + `/rulez:spec2pr`. |
| 10 | Monster fate | `feat/auto-pipeline` left unmerged as a dead branch. Nothing from it is a dependency. |

## Architecture

```
/rulez:spec2pr <spec-path>          (thin: launch in background, report)
        │
        ▼
scripts/spec2pr.sh <spec-path>      (all orchestration, sequential)
        │  per stage / review round:
        ▼
codex exec --cd <worktree>
           --output-schema <tmp>/<role>.json
           --output-last-message <logdir>/<stage>-r<N>.md
           < rendered prompt (stdin)
```

One runtime file. Prompt templates and JSON schemas are heredocs inside
the script; schemas are written to a private tmp dir at startup (codex
requires schema files on a real path — process substitution fails).

Identity: `slug` = spec filename minus `.md`; `repo` = project dir
basename; `id = <repo>-<slug>`. Branch `spec2pr/<slug>`, worktree
`~/.worktrees/<id>/`. No hashes — single-user tool; the script refuses
cleanly if an existing worktree was made for a different spec path.

### Worktree-first

The branch + worktree are created in preflight, the spec is copied in and
committed (`spec2pr: import spec`), and every codex call runs
`--cd <worktree>`. The user's main checkout is never touched — required
for parallel runs (one script invocation per spec, each in its own
worktree) and so brainstorming can continue undisturbed.

## Stages

1. **Preflight** — spec file exists; spec size gate; `codex` and `gh` on
   PATH; repo has `origin` and a `main` branch. Create branch + worktree
   from `origin/main`, import spec, commit.
2. **Spec-review loop** — review loop (below) on the in-worktree spec.
   Commit after the loop (`spec2pr: spec reviewed (N rounds)`).
3. **Plan** — codex writes the plan via `$superpowers:writing-plans`,
   returns `{plan_path, summary}`. Script validates the path is inside
   the worktree under `docs/superpowers/plans/`. Plan size gate. Commit.
4. **Plan-review loop** — same template, pointed at the plan. Commit.
5. **Implement** — codex implements the plan
   (`$superpowers:subagent-driven-development` wording), committing as it
   goes; returns `{status: done|blocked, summary, blocked_reason}`.
   Then the **script** pushes the branch and runs `gh pr create`
   (plumbing in script, judgment in codex). Title from slug; body links
   spec + plan.
6. **PR diff size gate**, then **PR-review loop** — fresh codex per round
   reviews `git diff main...HEAD` in the worktree, fixes, commits,
   pushes.
7. **Done** — print `DONE pr=<url>` + worktree path. Worktree is kept for
   pre-merge testing; cleanup after merge is manual in v1.

### Review loop (shared by stages 2, 4, 6)

One prompt template with placeholders. Each round is one fresh-context
`codex exec`: "review this artifact; report the count of blocker/major
findings you see; then fix the blockers and majors." Severity mapping:
high → major, medium → major (matches the user's `/goal` convention).

- Schema returns `{blockers_found, majors_found, notes}` — counts of what
  the fresh review **found before fixing**. The loop exits clean only
  when a round reports 0 found — an unbiased fresh-eyes verdict, never
  self-assessment by the context that just fixed the code.
- Cap: 3 fix rounds (worst case 4 calls: 3 dirty + 1 clean). If round 3
  still found issues → exit `DIRTY` with the last findings in the log.

### Resume = look at the world

Rerunning the same spec: worktree exists → reuse; spec committed → skip
import; plan file exists in worktree → skip plan stage; open PR for the
branch (`gh pr list --head`) → skip implement and push. Review loops
have no completion marker — they simply run again; a clean artifact
converges in one cheap round. No state file, nothing to validate or go
stale.

## Contracts

### Exit contract

Last stdout line is machine-greppable, prefix `SPEC2PR`, mirrored by exit
code. This line is what the background-task notification carries into the
main Claude session.

| Last line | Exit | Meaning |
|---|---|---|
| `SPEC2PR DONE pr=<url> worktree=<path>` | 0 | PR ready for review |
| `SPEC2PR SPLIT <spec\|plan\|diff> size=<n> limit=<n>` | 2 | Too big — split the spec, retry |
| `SPEC2PR DIRTY <stage> blockers=<n> majors=<n> log=<path>` | 3 | Review cap hit, findings remain |
| `SPEC2PR HALT <stage>: <reason>` | 1 | Everything else (codex non-zero, gh failure, blocked implementer) |

### Status file

`~/.spec2pr/<id>.status`, append-only, one line per event:

```
2026-06-11T14:02:11Z preflight ok
2026-06-11T14:02:30Z spec-review r1 blockers=2 majors=3
2026-06-11T14:09:12Z spec-review r2 blockers=0 majors=0 clean
2026-06-11T14:09:40Z plan ok docs/superpowers/plans/2026-06-11-foo.md
2026-06-11T15:31:02Z SPEC2PR DONE pr=https://github.com/... worktree=...
```

`tail -1` = current state. The final line is always the exit-contract
line (guaranteed by the EXIT trap). `cat ~/.spec2pr/*.status` is the
multi-run dashboard. Logs (codex last-message + stderr per stage/round)
go to `~/.spec2pr/<id>/`, kept always, overwritten per round on rerun.

### Schemas

All include `additionalProperties: false` at every object level (OpenAI
structured output rejects schemas without it — spike-proven).

- review: `{blockers_found: int, majors_found: int, notes: string}`
- plan: `{plan_path: string, summary: string}`
- implement: `{status: "done"|"blocked", summary: string, blocked_reason: string}`

PR creation needs no schema — the script does it with `gh`.

### Size thresholds

Env-overridable, defaults baked into the script:

- `SPEC2PR_MAX_SPEC=32768` (32 KB ≈ 8k tokens)
- `SPEC2PR_MAX_PLAN=65536`
- `SPEC2PR_MAX_DIFF=131072` (~2–3k changed lines; beyond that, review
  loops stop being meaningful)

### Codex invocation

`codex exec --cd <worktree> --output-schema <tmp>/<role>.json
--output-last-message <logdir>/<stage>-r<N>.md` with the rendered prompt
on **stdin** (no argv limits, no shell escaping), stderr to
`<logdir>/<stage>-r<N>.stderr`, exit status checked directly. No timeout
wrapper in v1 (codex config bounds runs; a hung codex is visible as a
stage that never completes in the status file). No sandbox flags.

## Error handling

`set -euo pipefail` plus one EXIT trap: if the script dies without having
printed a `SPEC2PR` line, the trap appends
`SPEC2PR HALT <current-stage>: unexpected exit` to the status file — the
status file always ends in a contract line.

- Codex non-zero → `HALT <stage>` with the stderr tail path. Logs kept.
- Implementer `blocked` → `HALT implement: <blocked_reason>`.
- `gh pr create` fails → `HALT pr-create`; rerun resumes there (commits
  exist, push is idempotent, open-PR check precedes create).
- Concurrency: `flock` on the run's own status file at startup; a second
  invocation for the same spec exits `HALT: already running`. Different
  specs run in parallel freely (own branch/worktree each); conflicting
  PRs are a merge-time human problem.
- Killed mid-codex → rerun resumes from world state; worst case one
  review round repeats (idempotent, costs one codex call).

## Slash command

`commands/rulez/spec2pr.md` (~20 lines of instruction):

- `/rulez:spec2pr <spec-path>` — launch the script as a background Bash
  task; report "started; notification arrives on completion".
- `/rulez:spec2pr status` — print `tail -1` of every
  `~/.spec2pr/*.status`.
- On the completion notification, Claude reads the `SPEC2PR` line and
  reacts: `DONE` → offer to review the PR; `SPLIT` → recommend splitting
  the spec; `DIRTY`/`HALT` → show the log path.
- `settings.json` gains one permission entry for the script so background
  launches never prompt.

## Testing

- **Stubbed test** (`tests/spec2pr/`): `SPEC2PR_CODEX_BIN` env override
  points at a fake codex that replays canned schema outputs. Asserts
  stage sequencing, clean-round loop exit, cap-hit → `DIRTY`, size gates
  → `SPLIT`, resume skips (plan exists → no plan call), exit lines +
  codes. Runs against a scratch git repo with a file-based `origin`. No
  network, no real codex.
- **Manual e2e** (documented in `docs/superpowers/smoke-tests/`): one toy
  spec ("add a --version flag") through real codex against a scratch
  GitHub repo, run once before first real use. Verifies the codex CLI
  contract, `$superpowers:*` prompt expansion under `codex exec`, and
  `gh` auth. Non-negotiable: the dry-run-only testing of the previous
  design is exactly how its merge-stage integration bug survived to
  review.

## Out of scope (v1)

- Auto-merge, merge locks, branch-protection checks.
- Checkpoints/gates mid-pipeline.
- Automated Claude review of the PR (the human + main Claude review
  before merge is the cross-model check; automate only if evidence shows
  codex's loop keeps missing things).
- Timeout wrappers, nonces, UID/symlink guards, multi-user hardening.
- Non-`main` base branches.
