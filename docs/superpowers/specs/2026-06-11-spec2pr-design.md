# spec2pr — Design

## Goal

One bash script that takes a spec produced by `superpowers:brainstorming`
and runs it unattended through codex to a reviewed, open PR:

spec-review → plan → plan-review → implement → PR-review → "PR ready".

The human brainstorms in Claude (where it is strongest) and reviews the
finished PR. Codex does the heavy lifting (faster, equally reliable at
implementation); the PR diff gets fresh-eyes cross-model review from
`claude -p` before the human ever sees it, with the human + Claude
pre-merge read as the final cross-check.

This replaces the abandoned `feat/auto-pipeline` design (18k lines:
Workflow runtime, LLM-interpreted shim, helper layer). Reliability comes
from fresh-context reviews and world-derived resume instead of defensive
code. Target size: script ~250–350 lines, slash command ~40, test ~150.

## Decisions

| # | Decision | Choice |
|---|----------|--------|
| 1 | Orchestrator | Plain bash script. No Workflow, no subagents, no state machine. |
| 2 | Run mode | Fully unattended, spec → PR. No checkpoints in v1. |
| 3 | Loop termination | Severity-marked findings; clean = a fresh round finds 0 blockers/majors *before* fixing anything. Spec/plan loops get counts from codex `--output-schema`; the PR-review loop parses them from a `claude -p` classify reply. |
| 4 | Worktree | Script creates branch + worktree before any codex call. Codex never creates its own. |
| 5 | Auto-merge | None in v1. Pipeline stops at "PR ready"; human merges. |
| 6 | Resume | Derived from the world (worktree / plan file / open PR), no state file. |
| 7 | Size gates | Spec, plan, and PR diff each gated; over limit → halt with "split the spec". |
| 8 | Codex sandbox | User's global codex config (auto-review approvals). No flags in the script. |
| 9 | Name / home | `spec2pr`. Ships in rulez-claudeset: `scripts/spec2pr.sh` + `/rulez:spec2pr`. |
| 10 | Monster fate | `feat/auto-pipeline` left unmerged as a dead branch. Nothing from it is a dependency. |
| 11 | PR-review reviewer | Cross-model: `claude -p` reviews the diff (fresh eyes, no self-assessment), `codex exec` fixes. Spec/plan loops stay codex self-review. Findings travel by file; one best-effort summary PR comment for the human. |

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
           --output-last-message <logdir>/<stage>-r<N>.json
           < rendered prompt (stdin)
        │  PR-review reviewer/classifier only:
        ▼
claude -p --output-format json
           --dangerously-skip-permissions
           < rendered prompt (stdin)
```

One runtime file. Prompt templates and JSON schemas are heredocs inside
the script; schemas are written to a private tmp dir at startup (codex
requires schema files on a real path — process substitution fails).

The spec, plan, and implement stages plus their review loops all run on
`codex exec`. The PR-review loop (stage 6) is the one exception: the
reviewer is `claude -p` (cross-model fresh eyes), while `codex exec`
still applies the fixes. See "PR-review loop" below.

Identity: `raw_slug` = spec filename minus `.md`; `raw_repo` = project
dir basename. The script lowercases both values and replaces characters
outside `[a-z0-9_-]` with `-` (dots included — git refs reject `..` and
`.lock`), then trims leading/trailing dashes, producing `slug`, `repo`, and
`id = <repo>-<slug>`. Branch `spec2pr/<slug>`, worktree
`~/.worktrees/<id>/`. The in-worktree spec path is the input spec's path
relative to the source repo root (`wt_spec_rel`); the copied spec is always
reviewed and planned from that same path. The plan path is deterministic:
`wt_plan_rel=docs/superpowers/plans/<slug>-plan.md`. No hashes in the
branch/worktree name — single-user tool. On first import the script writes
identity metadata under `~/.spec2pr/<id>/`: `source-path`, `source-sha256`,
and `base-sha`. These are not committed and are not progress state. On
resume, a path or source-hash mismatch exits cleanly with
`HALT preflight: worktree belongs to <path>` or
`HALT preflight: source spec changed since import`, preventing same-named
specs, slug collisions, or edited source specs from silently reusing a
stale branch/worktree.

### Worktree-first

The branch + worktree are created in preflight from the fetched base
commit `git rev-parse origin/main`, the spec is copied to `wt_spec_rel`
and committed (`spec2pr: import spec`), and every codex/claude call runs
with the worktree as its working directory. The user's main checkout is
never touched — required for parallel runs (one script invocation per
spec, each in its own worktree) and so brainstorming can continue
undisturbed.

## Stages

1. **Preflight** — spec file exists inside a git repository; spec size
   gate; `codex`, `claude`, `gh`, `jq`, and `git` on PATH (with
   `SPEC2PR_CODEX_BIN` / `SPEC2PR_CLAUDE_BIN` env overrides for tests);
   repo has `origin/main` after `git fetch origin main`. Resolve
   `base_sha=$(git rev-parse origin/main)`, create branch + worktree
   from that exact commit, write identity metadata under
   `~/.spec2pr/<id>/`, then copy the spec to `wt_spec_rel` in the
   worktree and commit only the copied spec.
2. **Spec-review loop** — review loop (below) on the in-worktree spec.
   The shared loop commits any fixes per dirty round.
3. **Plan** — codex writes the plan via `$superpowers:writing-plans`,
   creating exactly `wt_plan_rel`, and returns `{plan_path, summary}`.
   Script validates `plan_path == wt_plan_rel`, verifies no other files
   changed, applies the plan size gate, then commits.
4. **Plan-review loop** — same template, pointed at the plan. The shared
   loop commits any fixes per dirty round.
5. **Implement** — codex implements the plan
   (`$superpowers:subagent-driven-development` wording), committing as it
   goes; returns `{status: done|blocked, summary, blocked_reason}`. If
   it returns `done`, the script verifies `git status --porcelain` is
   empty before pushing; dirty worktrees halt as
   `HALT implement: uncommitted changes after done` so the PR cannot omit
   generated work. The script records `implementation-base`,
   `implementation-head`, and an `implementation-ok` checksum record under
   `~/.spec2pr/<id>/` before pushing. Then the **script** pushes the
   branch and runs `gh pr create` (plumbing in script, judgment in codex).
   Title from slug; body links spec + plan.
6. **PR diff size gate**, then **PR-review loop** (cross-model, below).
   The script computes the immutable-base diff as:
   `base_sha=$(cat "$metadir/base-sha"); git diff "$base_sha"...HEAD`.
7. **Done** — post one best-effort summary PR comment, then print
   `DONE pr=<url>` + worktree path. Worktree is kept for pre-merge
   testing; cleanup after merge is manual in v1.

### Review loop (shared by stages 2, 4 — codex self-review)

One prompt template with placeholders. Each round is one fresh-context
`codex exec`: "review this artifact; list every blocker/major finding
you see with severity and evidence; then fix the blockers and majors."
Severity mapping: high → major, medium → major (matches the user's
`/goal` convention). Low findings may appear in notes but do not drive
the loop. Stages 2 (spec) and 4 (plan) run before the PR exists, so they
have no comment channel — codex reviews and fixes its own artifact in
the worktree.

- Schema returns
  `{blockers_found, majors_found, findings, notes}`. Each finding is
  `{severity: "blocker"|"major", artifact, summary, evidence}` and is
  captured before any fixes are applied; counts must equal the finding
  list by severity. The loop exits clean only when a round reports 0
  blocker/major findings — an unbiased fresh-eyes verdict, never
  self-assessment by the context that just fixed the code.
- After every dirty review round, the script commits any worktree changes
  with `spec2pr: <stage> review fixes r<N>`. A dirty worktree after a
  clean round is a contract violation and halts, because a "clean" review
  round must not also make uncommitted changes.
- Cap: 3 review calls per invocation. Rounds 1-2 may be dirty, commit
  fixes, and continue. If round 3 found issues before fixing, commit any
  resulting fixes and exit `DIRTY` with the last pre-fix findings in the
  log; a rerun starts with a fresh clean-check round.

### PR-review loop (stage 6 — cross-model, file channel)

The PR-review loop does not share the codex self-review function. The
reviewer is `claude -p` (fresh eyes, a different model than the one that
wrote the code — the self-assessment bias the spec/plan loops accept in
exchange for simplicity is removed here, where a real PR exists). The
fixer is still `codex exec`. Findings travel model-to-model through a
**file** in the log dir, never through GitHub; the only PR comment is one
best-effort human-facing summary at the end.

Each round (cap 3 review calls per invocation, same `DIRTY` semantics)
runs in the worktree:

1. **Review.** `claude -p` reviews `git diff "$base_sha"...HEAD`, may read
   files and run the project's tests, and must not edit. It runs
   `--dangerously-skip-permissions` so the unattended read/test review
   never prompts (same posture as codex's auto-approval, in a sandboxed
   throwaway worktree). Its prose verdict is captured from
   `--output-format json` (`.result`) into `pr-review-r<N>.review`. The
   script then asserts `git status --porcelain` is empty; a reviewer that
   modified the tree → `HALT pr-review: reviewer modified worktree`.
2. **Classify.** A second `claude -p --output-format json` call is fed the
   `.review` file and returns `{blockers_found, majors_found}`. `claude`
   has no `--output-schema`, so the script extracts the JSON tolerantly
   and validates it with `jq`; a malformed reply is retried once, then
   `HALT pr-review`. This integer is the loop's only termination signal,
   captured before any fix (the fresh-eyes-before-fix invariant).
3. **Clean?** `0/0` → record the round and break to Done. No fix, no
   commit.
4. **Fix.** Otherwise `codex exec` runs with the `.review` file embedded
   in its prompt (codex reads the findings from the prompt, not from
   GitHub), fixes, and returns `{summary}`. The script commits
   `spec2pr: pr-review review fixes r<N>`, writes the summary to
   `pr-review-r<N>.fix`, pushes, and records
   `r<N>: blockers=<b> majors=<m>`.
5. Cap hit → `DIRTY pr-review blockers=<n> majors=<n>` from the last
   classify, fixes committed, log retained.

On the clean exit the script posts a single best-effort PR comment
summarizing the rounds, the final counts, and the log path. A failed
post is recorded in the status file and never changes the outcome — the
run still ends `DONE`.

### Resume = look at the world

Rerunning the same spec: worktree exists and `~/.spec2pr/<id>/source-path`
plus `source-sha256` match the current source spec → reuse; spec
committed → skip import; `wt_plan_rel` exists in worktree → skip plan
stage. Other files under `docs/superpowers/plans/` are ignored for resume.
Review loops have no completion marker — they simply run again; a clean
artifact converges in one cheap round.

Implementation resume is guarded by the implementation marker written
after a successful `done` result. If an open PR for the branch
(`gh pr list --head`) exists, or the remote branch already exists, the
script skips implementation only when the current worktree head is the
recorded `implementation-head` or contains only later `pr-review` fix
commits on top of it. If a rerun's spec-review or plan-review loop commits
new fixes after the recorded implementation, the script halts instead of
reusing a stale PR:
`HALT implement: review changes after implementation; rerun implementation required`.
Unknown commits on top of the recorded implementation halt as
`HALT implement: commits after implementation require manual review`.
No state file drives progress; the marker is a local integrity proof for
whether existing implementation work still matches the reviewed spec and
plan.

`source-sha256` is computed by a small helper that uses `shasum -a 256`
on macOS and falls back to `sha256sum` where available; the test stub
exercises whichever command the host provides.

## Contracts

### Exit contract

Last stdout line is machine-greppable, prefix `SPEC2PR`, mirrored by exit
code. This line is what the background-task notification carries into the
main Claude session.

| Last line | Exit | Meaning |
|---|---|---|
| `SPEC2PR DONE pr=<url> worktree=<path>` | 0 | PR ready for review |
| `SPEC2PR SPLIT <spec\|plan\|diff> size=<n> limit=<n>` | 2 | Too big — split the spec, retry |
| `SPEC2PR DIRTY <stage> blockers=<n> majors=<n> log=<path>` | 3 | Review cap hit; last round found issues before fixes, no clean verification |
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

- review:
  `{blockers_found: int, majors_found: int, findings: array, notes: string}`
  where each finding object has
  `{severity: "blocker"|"major", artifact: string, summary: string, evidence: string}`.
  Counts must match the findings array. The concrete JSON schema marks
  `blockers_found`, `majors_found`, `findings`, and `notes` as required;
  the finding item schema marks all four finding fields as required and
  sets `additionalProperties: false`.
- plan: `{plan_path: string, summary: string}`
- implement: `{status: "done"|"blocked", summary: string, blocked_reason: string}`
- pr-fix (codex, PR-review loop only): `{summary: string}`. The codex
  `review` schema above does not apply to stage 6 — there codex only
  fixes, it does not review.

The PR-review classify step uses `claude -p`, which has **no**
`--output-schema`. The script instead parses `{blockers_found, majors_found}`
out of claude's reply and validates it with `jq` (one retry on malformed,
then `HALT`). This is the only structured value in the pipeline not
enforced by codex's schema coercion.

PR creation needs no schema — the script does it with `gh`.

### Size thresholds

Env-overridable, defaults baked into the script:

- `SPEC2PR_MAX_SPEC=32768` (32 KB ≈ 8k tokens)
- `SPEC2PR_MAX_PLAN=65536`
- `SPEC2PR_MAX_DIFF=131072` (~2–3k changed lines; beyond that, review
  loops stop being meaningful)

### Codex invocation

`codex exec --cd <worktree> --output-schema <tmp>/<role>.json
--output-last-message <logdir>/<stage>-r<N>.json` with the rendered prompt
on **stdin** (no argv limits, no shell escaping), stderr to
`<logdir>/<stage>-r<N>.stderr`, exit status checked directly. No timeout
wrapper in v1 (codex config bounds runs; a hung codex is visible as a
stage that never completes in the status file). No sandbox flags.

### claude invocation (PR-review reviewer only)

`claude -p --output-format json --dangerously-skip-permissions` run with
the worktree as cwd, prompt on **stdin**, stderr captured per round. The
review call's prose verdict is read from the JSON envelope's `.result`;
the classify call's reply is parsed for `{blockers_found, majors_found}`.
Binary is `SPEC2PR_CLAUDE_BIN` (default `claude`), mirroring
`SPEC2PR_CODEX_BIN`, so tests can point at a stub. `claude` is a preflight
dependency alongside `codex`, `gh`, `jq`, and `git`. Non-zero exit →
`HALT pr-review` with the stderr tail path, same as codex.

## Error handling

`set -euo pipefail` plus one EXIT trap: if the script dies without having
printed a `SPEC2PR` line, the trap appends
`SPEC2PR HALT <current-stage>: unexpected exit` to the status file — the
status file always ends in a contract line.

- Codex non-zero → `HALT <stage>` with the stderr tail path. Logs kept.
- Implementer `blocked` → `HALT implement: <blocked_reason>`.
- `gh pr create` fails → `HALT pr-create`; rerun resumes there (commits
  exist, push is idempotent, open-PR check precedes create).
- Concurrency: an atomic `mkdir ~/.spec2pr/<id>.lock` lock at startup,
  with the runner PID written inside. Only the process that created the
  lock installs cleanup, and the EXIT trap removes the lock only when the
  PID file still matches its own PID. A second invocation for the same
  spec exits `HALT: already running` without touching the existing lock.
  Different specs run in parallel freely (own branch/worktree each);
  conflicting PRs are a merge-time human problem.
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

- **Stubbed test** (`tests/spec2pr/`): `SPEC2PR_CODEX_BIN` and
  `SPEC2PR_CLAUDE_BIN` env overrides point at fake codex/claude bins that
  replay canned outputs (codex: schema JSON; claude: a prose review then a
  classify reply). Asserts stage sequencing, clean-round loop exit,
  cap-hit → `DIRTY`, size gates → `SPLIT`, resume skips (plan exists → no
  plan call), exit lines + codes. PR-review specifics: the codex fix
  prompt carries claude's `.review` file, a reviewer that edits the tree
  halts, a malformed classify reply retries once then halts, and the
  best-effort summary comment fires on `DONE` without gating it (stub-gh
  records the `pr comment`). Runs against a scratch git repo with a
  file-based `origin`. No network, no real codex or claude.
- **Manual e2e** (documented in `docs/superpowers/smoke-tests/`): one toy
  spec ("add a --version flag") through real codex and real `claude -p`
  against a scratch GitHub repo, run once before first real use. Verifies
  the codex CLI contract, `$superpowers:*` prompt expansion under
  `codex exec`, the `claude -p` review/classify contract (envelope shape,
  `--dangerously-skip-permissions`, no worktree edits), the summary PR
  comment, and `gh` auth. Non-negotiable: the dry-run-only testing of the
  previous design is exactly how its merge-stage integration bug survived
  to review.

## Out of scope (v1)

- Auto-merge, merge locks, branch-protection checks.
- Checkpoints/gates mid-pipeline.
- Automated Claude review of the spec and plan (stages 2 and 4 stay
  codex self-review; only the PR diff gets cross-model `claude -p`
  review). The human + main-Claude read before merge remains the final
  cross-check on top of the automated PR-review loop.
- Timeout wrappers, nonces, UID/symlink guards, multi-user hardening.
- Non-`main` base branches.
