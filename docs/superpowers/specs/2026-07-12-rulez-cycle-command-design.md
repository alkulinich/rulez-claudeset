# /rulez:cycle — one command to launch the review/fix watcher loops

## Context

The operator runs six recurring agent prompts often — the cross-product of
`{spec, plan, PR}` artifacts and `{reviewer, fixer}` roles. Each is a ~300-word
prompt, carefully guarded (idempotent round-tracking, priority markers, "never
write idle entries"), handed to a recurring harness primitive (`/loop` for
reviewers, `/goal` for fixers). Hand-writing them each time is exactly where the
subtle guards drift or get dropped.

This adds a single command, `/rulez:cycle`, that assembles the correct prompt
from three explicit selectors and launches the recurring mode. It mirrors the
existing `create-pr` / `add-issue` "generate-then-act" template and the repo's
`command → script` convention.

## Settled decisions

- **Command:** `/rulez:cycle <role> <mode> <type> <target(s)>` — three explicit
  selectors, **no auto-detection**, **no role↔mode coupling**.
  - `role ∈ {reviewer, fixer}` — *what the agent does*.
  - `mode ∈ {loop, goal}` — *how it recurs* (which primitive to launch).
  - `type ∈ {spec, plan, PR}` — *which artifact*.
- **Full cross-product allowed.** All 12 `role×mode×type` combos are legal; the
  natural pairing (`reviewer+loop`, `fixer+goal`) is **not** enforced. The six
  examples all used the natural pairing, but `reviewer+goal` (review-until-clean-
  then-done) and `fixer+loop` are valid.
- **Expansion factors in two pieces:**
  - **body** = f(role, type) → the six substantive templates: *what* to
    review/fix, which channel, which checks.
  - **wrapper** = f(mode) → recurrence cadence + termination phrasing supplied
    through the `{{RECUR}}` / `{{TERMINATE}}` / `{{IDLE}}` slots.
- **Templates are verbatim.** The six bodies are the operator's existing prompts,
  preserved word-for-word with only the parameter slots substituted. Their exact
  wording is load-bearing (tuned) — implementation must **not** paraphrase,
  reorder, or "improve" them. The canonical parameterized text is the Appendix.
  Two intentional, minimal parameterizations are *not* paraphrase: (a) the fixer
  bodies name the edited artifact via `{{ARTIFACT}}` (they *watch* the findings
  file, so the artifact path must be explicit); (b) the goal cadence phrase is
  normalized to one form (`re-read at least every 2 min`) across every render.
- **Auto-start via `Skill(mode, <prompt>)`.** The command invokes the `loop` or
  `goal` skill with the assembled prompt as its task. Per the operator's
  decision, both are assumed invocable; if the harness rejects the mode, that
  surfaces as the Skill call's own error.
- **Approach A: one command `.md` + one prompt-builder script**
  (`scripts/cycle-prompt.sh`). The six templates live as the single source of
  truth inside the script, not as model-regenerated prose.
- **The prompt builder is hermetic** — pure, deterministic string work. **No
  network, no git-state queries.** Anything requiring live state (head SHA,
  branch name, round number `<N>`, `<date time UTC>`, `git hash-object`) stays as
  a **literal instruction in the emitted prompt** for the loop/goal agent to
  resolve each round. This keeps the builder fast and unit-testable offline.
- **Targets per type:**
  - `spec` → `<spec.md>`
  - `plan` → `<plan.md> [<spec.md>]` — the spec is derived from the plan path
    when omitted (`/plans/`↔`/specs/`, drop the `-plan` suffix).
  - `PR` → `<PR#>` (a leading `#` is optional).
- **Findings channel:** spec/plan → `${target%.md}-findings.md` (pure string
  derivation); PR → PR comments.
- **VERSION/UPGRADE.md untouched** — deferred to a release step per CLAUDE.md.

## Affected code

- **Create** `commands/rulez/cycle.md` — the command. Mirrors `add-issue.md` /
  `create-pr.md`: track-command line, usage, run the builder script, invoke the
  mode skill with the captured prompt.
- **Create** `scripts/cycle-prompt.sh` — the hermetic prompt builder.
- **Create** `tests/cycle/run-tests.sh`, `tests/cycle/helpers.sh`,
  `tests/cycle/test-cycle-prompt.sh` — sandbox tests following the
  `tests/worktree/` and `tests/spec2pr/` harness shape.
- **No changes** to the `loop`/`goal` skills, existing scripts, `settings.json`,
  or the auto-update path.

## The change

### `scripts/cycle-prompt.sh` (the builder)

Signature: `cycle-prompt.sh <role> <mode> <type> <target...>`. Emits the fully
expanded prompt on **stdout**; diagnostics/usage on **stderr**; exits nonzero on
any validation failure.

Steps:

1. **Validate selectors.** `role ∈ {reviewer,fixer}`, `mode ∈ {loop,goal}`,
   `type ∈ {spec,plan,PR}`. Any mismatch → usage to stderr, exit 2.
2. **Bind targets & derive the channel** by `type`:
   - `spec`: `ARTIFACT=$4`; `FINDINGS="${ARTIFACT%.md}-findings.md"`.
   - `plan`: `ARTIFACT=$4`; `FINDINGS="${ARTIFACT%.md}-findings.md"`;
     `SPEC=${5:-<derived>}`. Derivation: `/plans/`→`/specs/` and strip the
     trailing `-plan` before `.md`
     (`…/plans/X-design-plan.md` → `…/specs/X-design.md`). If `$4` does not end
     in `-plan.md` **and** no explicit `$5` is given → error (can't derive the
     spec), exit 2.
   - `PR`: `PRNUM=${4#\#}` (strip one leading `#`). If `PRNUM` is not all digits
     → error, exit 2. `ARTIFACT="#$PRNUM"`; `FINDINGS` is unused (channel = PR
     comments, baked into the PR templates).
3. **Do not require the watched file to exist.** Reviewers legitimately watch a
   target before its first appearance (a plan may not exist yet); fixers watch a
   findings file that may not exist yet. Absence is handled *inside* the
   protocol, not by the builder.
4. **Select** `body = TEMPLATE[role][type]` (Appendix) and the mode wrapper
   values (below).
5. **Substitute** the slots and print. No trailing "loop"/"goal" keyword — that
   selector is the Skill name, not part of the task text.

**Mode wrapper values:**

| slot | `loop` | `goal` |
|------|--------|--------|
| `{{RECUR}}` | `Watch` | `Watch (re-read at least every 2 min)` |
| `{{TERMINATE}}` | `stop the loop and notify` | `complete the goal and notify` |
| `{{IDLE}}` | `do nothing` | `wait 2 min without writing anything` |

**Body slots:** `{{ARTIFACT}}` (spec/plan path, or `#<n>` for PR),
`{{FINDINGS}}` (findings file path), `{{SPEC}}` (plan cross-check spec path),
`{{PRNUM}}` (bare PR number for `/review` and `gh`).

**Worked example — `spec` + `reviewer`, rendered for each mode:**

`loop` → prompt begins `Watch <spec.md> for fix cycles.` … and ends the
no-findings bullet with `… "Result: No findings." then stop the loop and notify.`

`goal` → same body, but begins `Watch (re-read at least every 2 min) <spec.md>
for fix cycles.` … and ends `… then complete the goal and notify.`

The other five bodies follow the same factoring; see the Appendix for each.

### `commands/rulez/cycle.md` (the command)

1. **Track command:** `…/scripts/set-current-command.sh cycle`.
2. **Usage** (print and stop if selectors are missing/invalid):
   `/rulez:cycle <reviewer|fixer> <loop|goal> <spec|plan|PR> <target(s)>`.
3. **Build the prompt:** run
   `bash ~/.claude/skills/rulez-claudeset/scripts/cycle-prompt.sh <role> <mode> <type> <target…>`,
   capture stdout as `PROMPT`. If the script exits nonzero, show its stderr and
   stop.
4. **Auto-start:** invoke the **`<mode>` skill** (the literal `loop` or `goal`
   the operator passed) via the Skill tool, passing `PROMPT` as its argument.
   This turns the current agent into the watcher. Reviewer and fixer are run as
   two separate agents (two `/rulez:cycle` invocations) — the command starts one
   watcher, not both.

## Edge cases & invariants

- **Hermetic builder:** never calls `gh`, `git`, or the network. Head SHAs,
  branch names, round numbers, timestamps, and `git hash-object` revisions are
  all resolved by the *loop/goal agent* at run time, not baked at build time.
- **PR fixer worktree/branch** is therefore an *instruction*, not a substitution:
  the template tells the agent to resolve the head branch with
  `gh pr view {{PRNUM}} --json headRefName -q .headRefName` and work in
  `.worktrees/<branch>`, creating it with `git-worktree-add.sh <branch>` if
  absent (reusing the repo's worktree-placement wrapper).
- **Idempotency guards live in the templates**, verbatim — the builder never
  re-implements "never process a round twice" / "never write idle entries".
- **No coupling enforcement:** an unusual combo (e.g. `reviewer goal`) is
  assembled and launched without warning; the wrapper simply supplies goal-style
  cadence/termination to the reviewer body.
- **Reviewer targets may be absent** at launch; the protocol's "file may not
  exist yet" / "No file → wait" bullets cover it.
- **Findings-path derivation is purely `${target%.md}-findings.md`** — it does
  not special-case `-design` vs `-plan`; both yield
  `…-design-findings.md` / `…-design-plan-findings.md` respectively.
- **`#` handling:** `#87` and `87` both normalize to `87`; the display form is
  always `#87`.
- The command **never itself reviews or fixes** — it only builds a prompt and
  launches the mode. All substantive work happens inside the launched loop/goal.

## Testing

`tests/cycle/` — sandbox unit tests for the builder, following the
`tests/worktree/` harness (`run-tests.sh` auto-discovers `test_*`, `helpers.sh`
provides `assert_eq` / `assert_contains`). The builder is pure and offline, so
tests need no git repo or network. Cover:

- **Template selection:** for each of the 6 `(role,type)` pairs, the emitted
  prompt contains that template's signature phrase (e.g. reviewer×spec → `for fix
  cycles`; fixer×plan → `update the plan where warranted`; reviewer×PR →
  `run /review`).
- **Mode wrapper:** `loop` → contains `stop the loop and notify` and starts with
  `Watch <…>`; `goal` → contains `complete the goal and notify` and
  `re-read at least every 2 min`.
- **Findings derivation:** spec `X-design.md` → prompt references
  `X-design-findings.md`; plan `X-design-plan.md` → `X-design-plan-findings.md`.
- **Plan→spec derivation:** `…/plans/X-design-plan.md` (no explicit spec) →
  prompt references `…/specs/X-design.md`; an explicit `$5` spec overrides it;
  a plan path not ending `-plan.md` with no explicit spec → nonzero exit.
- **PR normalization:** `#87` and `87` both → prompt says `PR #87` and
  `/review 87`; a non-numeric PR target → nonzero exit.
- **Selector validation:** bad `role`/`mode`/`type` → nonzero exit with usage on
  stderr; missing target → nonzero exit.

The `cycle.md` command itself (Skill invocation) is verified by read-through /
manual dry-run, as with `spec2pr-split.md`.

## Out of scope

- **Launching reviewer + fixer together.** One command starts one watcher; the
  ping-pong pair is two agents by design.
- **Unifying worktree location with spec2pr** (`$HOME/.worktrees/`). The PR fixer
  uses the project-root `.worktrees/` convention via `git-worktree-add.sh`.
- **Changing the `loop`/`goal` skills** or adding a `/goal` fallback — "assume
  both invocable" was chosen.
- **Altering the tuned prompt wording.** The six bodies ship verbatim.
- **VERSION/UPGRADE.md bump** — a separate release step.

---

## Appendix — canonical templates (verbatim, parameterized)

Each is the operator's existing prompt with slots substituted. `<N>`,
`<date time UTC>`, `<date>`, `<round>` and all SHAs/revisions stay literal for
the runtime agent.

### `reviewer × spec`

```
{{RECUR}} {{ARTIFACT}} for fix cycles.
- No findings file ({{FINDINGS}}) exists yet, OR it has no review round from me → review the spec at its current revision against the codebase, mark each finding [P0 — Blocker] / [P1 — High] / [P2 — Medium] with spec line anchors, and append ONE "## Review round <N> — <date time UTC>" section recording the reviewed spec revision (git hash-object, short) and the findings.
- A new "## Fixes — Review round <N>" section was appended after my last review round AND the spec revision differs from the "Spec revision:" I recorded → re-review the new revision the same way (verify each claimed fix, judge each decline). Don't re-raise findings a prior Fixes section declined with recorded reasons, unless the new revision adds new evidence.
- A new Fixes section declines ALL findings (spec deliberately unchanged) → still run a round: assess the recorded reasons; accept them or rebut with new evidence only.
- A Fixes section claims fixes but the spec revision is unchanged since my last round → do nothing (the edit is lagging the note; wait for it).
- Review of the current revision finds nothing (or all declines accepted) → append the round with "Result: No findings." then {{TERMINATE}}.
Never append idle/no-change rounds to the findings file.
```

### `fixer × spec`

```
{{RECUR}} {{FINDINGS}} for newly appended, unhandled review rounds.
Findings → update the spec ({{ARTIFACT}}) where warranted; disagreements are allowed with rationale. Then append ## Fixes — <round> (<date>) describing fixed vs declined.
No new findings. → {{TERMINATE}}.
No file or No new round → {{IDLE}}.
Never process a round twice or append idle/no-change entries.
```

### `reviewer × plan`

```
{{RECUR}} {{ARTIFACT}} for changes (including its first appearance — the file may not exist yet).
- Plan revision is new (differs from the last revision recorded in the findings file) → review it against {{SPEC}} and the actual codebase (file paths, line refs, commands, spec coverage, placeholder scan, type consistency), then append a "## Review round <N> — <date time UTC>" section to {{FINDINGS}} recording the plan revision hash and each finding marked [P0 — Blocker] / [P1 — High] / [P2 — Medium] with concrete anchors. Don't re-raise findings a prior "## Fixes" section already declined with recorded reasons, unless the new revision adds new evidence.
- Review of the current revision finds nothing → append the round with "Result: No findings." then {{TERMINATE}}.
- Plan unchanged since the last reviewed revision → do nothing.
Never append idle/no-change entries to the file.
```

### `fixer × plan`

```
{{RECUR}} {{FINDINGS}} for newly appended, unhandled review rounds.
- Findings → update the plan ({{ARTIFACT}}) where warranted; disagreements are allowed with rationale. Then append `## Fixes — <round> (<date>)` describing fixed vs declined.
- `No findings.` → {{TERMINATE}}.
- No new round → {{IDLE}}.
Never process a round twice or append idle/no-change entries.
```

### `reviewer × PR`

```
{{RECUR}} PR {{ARTIFACT}} for review cycles.
- No review comment from me exists yet, OR a new comment containing "fixed" (case-insensitive) was posted after my last review comment AND the head commit differs from the "Head commit:" recorded in that comment → run /review {{PRNUM}} against the current head, mark each finding [P0 — Blocker] / [P1 — High] / [P2 — Medium] with file:line anchors, and post ONE PR comment titled "## Review round <N> — <date time UTC>" recording the reviewed head commit SHA and the findings. Don't re-raise findings a prior comment already declined with recorded reasons, unless the new head adds new evidence.
- Review of the current head finds nothing → post the round comment with "Result: No findings." then {{TERMINATE}}.
- A "fixed" comment arrived but the head commit is unchanged since the last reviewed SHA → do nothing (the push is lagging the comment; wait for it).
Never post idle/no-change comments.
```

### `fixer × PR`

```
{{RECUR}} PR {{ARTIFACT}} for new, unhandled reviewer-agent comments titled `## Review round <N> — ...`.
Resolve this PR's head branch with `gh pr view {{PRNUM}} --json headRefName -q .headRefName`; work in `.worktrees/<branch>` on that branch (create it with `~/.claude/skills/rulez-claudeset/scripts/git-worktree-add.sh <branch>` if it doesn't exist).
For each latest unhandled round:
- `Result: No findings.` → {{TERMINATE}}.
- Findings → verify each against the current PR head; fix what is technically warranted in that worktree. Declines are allowed only with recorded technical rationale.
- Run focused tests and typecheck; commit and push the fixes.
- After the push succeeds, verify PR {{ARTIFACT}} points to the new HEAD, then post ONE comment titled:
  `## Fixed — Review round <N> — <date time UTC>`
  Include the reviewed SHA, new SHA, fixed vs declined findings, and test evidence.
- Identify handled rounds by reviewer comment ID plus reviewed SHA; never process one twice.
- No new reviewer round, or waiting for review of the pushed head → {{IDLE}}.
Never post `fixed` before the push reaches PR {{ARTIFACT}}. Never create empty commits, touch unrelated files, or post idle/no-change comments. If every finding is declined and no head change is warranted, post one rationale response without `fixed` and notify me instead of fabricating a change.
```
