# spec2pr split tooling: `git-publish-spec.sh` + `/rulez:spec2pr-split`

Two tools that make recovery from a spec2pr size-gate halt repeatable: a small
script that publishes a spec/plan to `origin/main`, and a command that splits a
too-big spec into two smaller, sequential sub-specs by leaning on
`superpowers:brainstorming`.

## Context

spec2pr enforces three size gates. Each halts the run with
`finish 2 "SPLIT <what> size=N limit=M"` (`scripts/lib/spec2pr-runtime.sh:97-99`):

| Gate | Fires at | Limit (default, `spec2pr-runtime.sh:10-12`) | State when it trips |
|------|----------|------|---------------------|
| `SPLIT spec` (`scripts/spec2pr.sh:124-127`) | preflight, before `require_codex` | `SPEC2PR_MAX_SPEC` = 32 KB | nothing built — no plan, no PR, no pushed branch |
| `SPLIT plan` (`scripts/spec2pr.sh:411-414`) | end of plan stage | `SPEC2PR_MAX_PLAN` = 64 KB | spec+plan commits on a local branch; no PR, no push |
| `SPLIT diff` (`scripts/lib/pr-review-engine.sh:84-86`) | start of pr-review | `SPEC2PR_MAX_DIFF` = 128 KB | PR exists + branch pushed + full implementation |

When a gate trips the run stops, because the spec, plan, or implementation is
too big to carry through. Recovering today is fully manual: hand-split the spec,
hand-author two smaller specs, re-run spec2pr on each, and clean up whatever the
dead run left behind. The motivating case was a `diff` gate in `dc-import-2026`:
spec2pr created PR #98, then `SPLIT diff size=166010 limit=131072` — the
implementation was too large to review, so the spec had to be split into two and
each half run through spec2pr to produce smaller plans and PRs.

This spec adds two tools to make that recovery a repeatable workflow.

## Settled decisions

- **Two independent tools.** A publish script (Tool 1) and a split command
  (Tool 2). Tool 2 does **not** call Tool 1 — it commits its own output.
- **Tool 1 publishes a spec/plan to `origin/main`**, push-and-stop, no PR
  involvement. It is the standalone "get a brainstormed spec onto main so it can
  be picked up" helper.
- **Tool 2 leans on `superpowers:brainstorming`** (prime-and-delegate) rather
  than reimplementing decomposition. The interactive seam-finding — asking
  proper questions when the cut is unclear — is the harness's job.
- **Both sub-specs are written and committed locally in one brainstorming pass.**
- **Sequencing is enforced at the push level.** Both sub-spec commits sit on
  local `main`; publishing one path at a time keeps part-2 off `origin/main`
  until its turn. No force-push, no commit-range surgery.
- **Split the spec, never the plan.** spec2pr re-derives a fresh, internally
  coherent plan per sub-spec.
- **Default two parts** (the model may propose more); strictly sequential with a
  merge between part-1 and part-2.
- **Dead-PR/branch/worktree cleanup is manual.** Tool 2 only prints the
  gate-specific commands; it never closes a PR or deletes anything.
- **The terminal state for these sub-specs is the brainstorming review gate**,
  not `writing-plans`. spec2pr derives the plans and implements each half.

## Affected code

New files only — the size gates and slug derivation are referenced, not changed:

- **new** `scripts/git-publish-spec.sh` — Tool 1, modeled on
  `scripts/git-commit-handoff.sh`.
- **new** `commands/rulez/spec2pr-split.md` — Tool 2, `/rulez:spec2pr-split`.
- **new** `scripts/spec2pr-split-context.sh` — deterministic blob-parsing and
  evidence-gathering helper called by the command.
- **new** `tests/spec2pr/test-publish-spec.sh` — Tool 1 tests.
- **new** `tests/spec2pr/test-spec2pr-split-context.sh` — context-helper tests.

Reference points (unchanged): slug derivation `scripts/spec2pr.sh:57-75`
(`SPEC_SLUG` → `BRANCH=spec2pr/$SPEC_SLUG` → plan at `$SPEC_SLUG-plan.md`); the
three gates listed in Context.

## The change

### Tool 1 — `scripts/git-publish-spec.sh`

`git-publish-spec.sh <path> [<path> …]` — one or more paths (a spec, a plan, or
both). Behavior, mirroring `git-commit-handoff.sh` (same RTK wrapper, same
push-from-inside-the-script trick to avoid the harness's *Git Push to Default
Branch* prompt):

1. **Scope guard** — every path must exist, be a file, and live under
   `docs/superpowers/specs/` or `docs/superpowers/plans/`. Anything else → error
   and stop. This is the wall that keeps it from ever staging `tmp/`,
   `references/`, or other WIP.
2. **Branch guard** — must be on `main`; error (naming the current branch)
   otherwise. "Publish to `origin/main`" should be unambiguous.
3. **No-op if clean** — if `git status --porcelain <paths>` is empty, skip.
4. **Stage only the named paths** — never `git add .`.
5. **Commit** — conventional `docs:` subject from the spec stem:
   `docs: spec — <stem>`, `docs: plan — <stem>`, or `docs: spec+plan — <stem>`.
6. **Push** — `git push` to `origin/main` from inside the script; on failure,
   report "committed locally, push manually" and exit non-zero.

No `Co-Authored-By` trailer (matches `git-commit-handoff.sh`).

### Tool 2 — `commands/rulez/spec2pr-split.md`

`/rulez:spec2pr-split <free-text blob>` — you paste roughly what spec2pr printed
(the reviewed spec path, the plan path if any, and the `SPLIT …`/halt line). The
command is pure orchestration:

1. **Gather context** by calling `spec2pr-split-context.sh` (below), which
   returns the spec path, optional plan path, the gate (`spec`|`plan`|`diff`),
   the PR number if present, and — when a PR exists — the changed-files list.
2. **Invoke `superpowers:brainstorming`** via the Skill tool, primed with that
   evidence plus override directives:
   - **Framing:** "spec2pr's `<gate>` gate rejected this spec (size N > limit M).
     Decompose it into N (default 2) sequential, independently-implementable
     sub-specs that minimize shared files."
   - **Write both files, one pass:** `<stem-without-design>-part-1-design.md` and
     `…-part-2-design.md`, inserting `-part-N` before the `-design` suffix so
     each slug → branch → plan path stays distinct.
   - **Each sub-spec:** house style (Context / Settled decisions / Affected code /
     The change / Edge cases & invariants / Testing / Out of scope), **under
     32 KB** so it clears spec2pr's own spec gate on first run.
   - **Coverage map:** every requirement in the original → exactly one part (no
     gaps), and the parts' file sets are disjoint (cross-checked against the
     changed-files list when available — no overlap).
   - **Sequential constraint in part-2's prose:** "part-1 is already merged into
     `main`; build on it, do not re-specify its changes."
   - **Commit both** sub-specs locally; do **not** push.
   - **Terminal state = the review gate.** Stop after writing+committing; do
     **not** chain to `writing-plans`.
3. **On return**, surface the two paths + the coverage map, and print a manual
   next-steps reminder keyed to the gate (executing nothing destructive):
   - `diff` → "dead PR #N: `gh pr close N --delete-branch`, then remove the stale
     worktree/meta for slug `<old-slug>`."
   - `spec`/`plan` → "no PR; remove the local worktree/meta for `<old-slug>` if a
     run started."
   - then: `git-publish-spec.sh …-part-1-design.md` → run spec2pr → merge →
     `git-publish-spec.sh …-part-2-design.md` → run → merge.

The "write both files in one pass instead of one" is the only deviation the
command asks of the harness, driven entirely by the priming prompt.

### Helper — `scripts/spec2pr-split-context.sh`

`spec2pr-split-context.sh <blob-file>` — the deterministic front-half, extracted
so it is unit-testable and the command stays thin. It parses the pasted blob and
emits the parsed fields:

- **spec path** (required) — the `docs/superpowers/specs/…-design.md` path.
- **plan path** (optional) — the `docs/superpowers/plans/…-plan.md` path.
- **gate** — the `SPLIT <what>` token: `spec` | `plan` | `diff`.
- **pr number** — parsed from a PR URL or `#N`, when present.
- **changed files** — when a PR number was found, the output of
  `gh pr diff <n> --name-only` (the richest seam evidence).

Output is a simple key/value block the command reads. If the spec path is
missing or does not exist → exit non-zero. If the gate token is absent → default
to `spec` and warn (the evidence-poorest case). If `gh pr diff` fails → emit the
other fields, omit changed-files, and warn (degraded seam).

### Publishing & sequencing model

Once Tool 2 has committed both sub-specs to local `main`, the operator drives:

1. `git-publish-spec.sh …-part-1-design.md` — pushes part-1's spec to
   `origin/main`.
2. Run spec2pr on part-1 → review → **merge** its implementation PR.
3. `git-publish-spec.sh …-part-2-design.md` — only now does part-2 reach
   `origin/main`.
4. Run spec2pr on part-2 → review → merge.

Because `git-publish-spec.sh` stages only the path it is handed, publishing
part-1 leaves part-2's commit on local `main`, unpushed. That per-path staging
*is* the "merge between" mechanism at the push level.

## Edge cases & invariants

- **Per-path staging is the sequencing mechanism.** `origin/main` only ever sees
  the path explicitly published; part-2's local commit is a staged draft until
  its turn.
- **Scope + branch guards** on Tool 1: only `docs/superpowers/{specs,plans}`
  paths; must be on `main`. Protects against staging WIP or publishing from the
  wrong branch.
- **No-op when unchanged** — re-running Tool 1 on an already-published path makes
  no empty commit.
- **Gate token unparseable** → treat as `spec`-level (coarsest, no PR/diff
  evidence) and warn.
- **PR present but `gh pr diff` fails** → proceed without the changed-files list,
  warn that seam quality is degraded.
- **Each sub-spec < 32 KB**, in house style — or it trips spec2pr's own spec gate
  on the first run.
- **Slug distinctness** — `-part-N` inserted before `-design` yields distinct
  slugs, hence distinct `spec2pr/<slug>` branches and `<slug>-plan.md` paths; the
  second run cannot clobber the first.
- **Coverage map** — no gaps (every requirement maps to exactly one part) and no
  overlap (disjoint file sets, cross-checked against the changed-files list when
  a PR exists).
- **Watcher caveat** — the tools do not prevent a manual wholesale `git push` of
  `main`. On a repo where the spec2pr watcher auto-runs, pushing both commits at
  once starts both runs simultaneously, competing for the same model limits —
  the failure mode this workflow exists to avoid. `git-publish-spec.sh` is the
  path that keeps publishing safe.

## Testing

Both deterministic scripts use the existing `tests/spec2pr/` harness
(`run-tests.sh` sources `helpers.sh` + every `test-*.sh`; `make_sandbox` builds a
`project` repo on `main` with an `origin` bare remote and the
`docs/superpowers/{specs,plans}` dirs).

**`tests/spec2pr/test-publish-spec.sh`** (Tool 1):
- publishes a spec → only that path staged; subject `docs: spec — <stem>`;
  `origin/main` advanced (assert via `git -C "$ORIGIN" log`).
- spec + plan → subject `docs: spec+plan — <stem>`; both staged.
- no-op when unchanged → second run exits 0, no new commit.
- refuses an out-of-scope path (`README.md`) → non-zero, names the path, nothing
  committed.
- refuses a non-`main` branch → non-zero, names the branch.
- a stray dirty file is not swept into the commit.

**`tests/spec2pr/test-spec2pr-split-context.sh`** (helper):
- gate token extracted from a messy paste (`spec`/`plan`/`diff`).
- PR number pulled from a PR URL and from `#N`.
- plan-absent vs plan-present.
- changed-files fetched through the existing `gh` stub for a `diff` gate.
- missing/nonexistent spec path → non-zero.
- `gh pr diff` failure → other fields emitted, changed-files omitted, warning.

The interactive brainstorming hand-off in `spec2pr-split.md` is verified by
manual dry-run, not unit-tested.

## Out of scope

- **Recursion** — re-splitting a half that is still too big. One split has
  sufficed.
- **Automatic cleanup** of the dead PR / branch / worktree — Tool 2 only prints
  the commands.
- **Automatic publishing or sequencing** — driven by the operator with
  `git-publish-spec.sh`, one path at a time.
- **N>2 as a built feature** — the model proposes the count (default 2); no
  special handling beyond that.
- **Splitting the plan** — always split the spec and re-derive plans.
- **A `/rulez:` command wrapper for Tool 1.**
