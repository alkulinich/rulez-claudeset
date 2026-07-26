# /rulez:cycle — acceptance-verifier role

## Context

`/rulez:cycle` currently ships two roles, `reviewer` and `fixer`, across three
artifact types (`spec`, `plan`, `PR`) — six verbatim templates in
`scripts/cycle-prompt.sh`.

The `reviewer:PR` template asks a code reviewer's question: *is this correct and
well-built?* It runs `/review <n>` and judges the diff on its merits.

That is not the only question worth asking of a PR. The other one is:

> Don't review style. Verify whether the acceptance criteria are actually
> satisfied. Try to break it.

That is a different prompt against a different source of truth. A code review
judges the diff; an acceptance verification judges the diff *against a stated
contract*, and then attacks it. Running the first when you wanted the second
produces a clean review of code that does not do what the PR promised.

This spec adds that second question as its own role.

## Settled decisions

- **Role name:** `verifier`.
- **Criteria source:** the PR body. The verifier reads
  `gh pr view <n> --json body`. Nothing else — no linked spec, no derived path,
  no issue lookup.
- **No criteria found → halt.** The verifier posts nothing, stops immediately,
  and notifies the operator. It does not fall back to a code review, and it does
  not treat an empty contract as a pass.
- **Type support: `PR` only.** `verifier spec` and `verifier plan` are rejected.
  The role's premise — verify the criteria are *actually satisfied*, try to
  break it — needs running code. A spec *is* the criteria, so verifying one
  against itself is vacuous; a plan has no implementation, and "does the plan
  cover the spec?" is already `reviewer:plan`'s job. The role×type matrix
  therefore stops being a full cross-product.
- **Own comment channel:** `## Verification round <N> — <date time UTC>`,
  distinct from the reviewer's `## Review round <N>`. A code reviewer and a
  verifier can watch the same PR simultaneously without colliding on round
  numbering, and the thread records which question produced each finding.
- **Paired with the existing fixer.** `fixer:PR` is widened to consume both
  round kinds rather than adding a second fixer template.
- **Severity markers unchanged:** `[P0 — Blocker]` / `[P1 — High]` /
  `[P2 — Medium]`, so one fixer consumes both channels uniformly.
- **Both mode wrappers apply.** `verifier loop PR` and `verifier goal PR` are
  both legal; `mode` stays an independent selector.
- **`VERSION` / `UPGRADE.md` untouched** — deferred to a release step.

## Affected code

- `scripts/cycle-prompt.sh` — hermetic builder. Holds the templates as quoted
  heredocs dispatched by `case "$ROLE:$TYPE"`, with `@@TOKEN@@` substitution
  afterward.
- `commands/rulez/cycle.md` — thin command: parses, runs the builder, invokes
  `Skill(mode, prompt)`.
- `tests/cycle/test-cycle-prompt.sh` — 47 offline tests.

Two existing harness facts bind this change:

1. **`test_cycle_codex_goal_variants_fit_objective_limit` caps every goal-mode
   prompt at 4000 characters** (a Codex objective limit). Current sizes:
   `reviewer:PR` 969, `fixer:PR` 1399. There is ample headroom, but the new role
   must be added to that budget test.
2. **No existing assertion reads `fixer:PR`'s first line.** Its tests key on
   `gh pr view 87 --json headRefName`, `git-worktree-add.sh <branch>`, and the
   terminate string. Widening it breaks no existing assertion.

**Hermeticity is preserved.** The builder does no `git`, no `gh`, no network —
that is what makes the suite runnable offline with no repo. The "halt when no
criteria" rule therefore cannot be a build-time check; it is an instruction
*inside* the emitted prompt, resolved by the watcher agent at runtime. This is
the same pattern the existing templates already use for SHAs, branch names,
round numbers, and dates.

## The change

### 1. Role validation

`ROLE` widens to `reviewer|fixer|verifier`. A new combination check rejects the
role outside its supported type:

```bash
case "$ROLE" in reviewer|fixer|verifier) ;; *) usage; exit 2 ;; esac
```

```bash
if [ "$ROLE" = verifier ] && [ "$TYPE" != PR ]; then
  echo "error: verifier supports only type PR" >&2
  exit 2
fi
```

The check runs immediately after the three `case` selector validations and
*before* the existing empty-target check, so `verifier loop spec ""` reports the
role constraint rather than the less useful "target must not be empty". The
existing `plan` branch guards spec derivation with `if [ "$ROLE" = reviewer ]`;
`verifier` exits before reaching that branch, so it needs no change.

The usage string becomes:

```
usage: cycle-prompt.sh <reviewer|fixer|verifier> <loop|goal> <spec|plan|PR> <target...>
```

### 2. New `verifier:PR` template

A new `case` arm, verbatim:

```
@@RECUR@@ PR @@ARTIFACT@@ for acceptance-verification cycles.
Read the acceptance criteria from the PR body (`gh pr view @@PRNUM@@ --json body`). If the body states none, post nothing, stop immediately, and notify me that PR @@ARTIFACT@@ has no acceptance criteria to verify.
- No verification comment from me exists yet, OR a new comment containing "fixed" (case-insensitive) was posted after my last verification comment AND the head commit differs from the "Head commit:" recorded in that comment → verify the current head against those criteria. Do not review style, naming, structure, or code quality — that is the code reviewer's job. For each criterion, exercise the real behavior (run it, drive the actual path, read the actual output) and record satisfied / not satisfied / not verifiable with the evidence you ran. Then try to break it: boundaries, empty and malformed input, failure paths, repeated or concurrent invocation, states the criterion does not mention. Mark each finding [P0 — Blocker] / [P1 — High] / [P2 — Medium] with file:line anchors and a reproduction. Post ONE PR comment titled "## Verification round <N> — <date time UTC>" recording the verified head commit SHA, the per-criterion verdicts, and the findings. Don't re-raise findings a prior comment already declined with recorded reasons, unless the new head adds new evidence.
- Every criterion is satisfied and nothing broke → post the round comment with "Result: No findings." then @@TERMINATE@@.
- A "fixed" comment arrived but the head commit is unchanged since the last verified SHA → do nothing (the push is lagging the comment; wait for it).
Never post idle/no-change comments. A criterion you could not verify is a finding, not a pass.
```

Design notes on the wording, which is now source-of-truth:

- The trigger clause mirrors `reviewer:PR` exactly. The re-trigger mechanism —
  a comment containing "fixed" *plus* a moved head SHA — is title-agnostic and
  already proven, so the verifier reuses it rather than inventing one.
- The style exclusion is stated positively and names the owner ("that is the
  code reviewer's job") so the agent does not drift back into code review.
- Per-criterion verdicts are `satisfied / not satisfied / not verifiable`, with
  the evidence actually run. The verdict list, not just the findings, goes in the
  comment.
- The closing line — *"A criterion you could not verify is a finding, not a
  pass"* — closes the role's main failure mode: marking an un-exercised
  criterion green.

Tokens used: `@@RECUR@@`, `@@ARTIFACT@@`, `@@PRNUM@@`, `@@TERMINATE@@`.
`@@IDLE@@` is deliberately unused — like `reviewer:PR`, the idle branch is the
literal "do nothing" clause, because a verifier that waits silently needs no
cadence instruction beyond the one `@@RECUR@@` already carries.

### 3. `fixer:PR` widening — three edits

```diff
-…comments titled `## Review round <N> — ...`.
+…comments titled `## Review round <N> — ...` or `## Verification round <N> — ...`.
```

```diff
-  `## Fixed — Review round <N> — <date time UTC>`
+  `## Fixed — <Review|Verification> round <N> — <date time UTC>` — mirror the kind of round you handled.
```

```diff
-- `Result: No findings.` → @@TERMINATE@@.
+- `Result: No findings.` and no other unhandled round is pending → @@TERMINATE@@.
```

The third edit exists because pairing one fixer with two reviewer kinds creates
a termination hazard that did not exist before: if the code reviewer reports
clean while the verifier still has open findings, the unqualified clause would
terminate the fixer on the first `No findings.` and abandon the verifier's
round.

The mirrored reply title is what lets each watcher recognize its own round was
answered while both are running.

### 4. Command file

`commands/rulez/cycle.md` updates its usage line, its allowed-values list, and
gains one example:

```
/rulez:cycle verifier loop PR 40
```

It also states that `verifier` is `PR`-only, so the parse step rejects
`verifier spec` / `verifier plan` before invoking the builder rather than
surfacing a raw builder error.

## Edge cases & invariants

- **`verifier` + `spec` / `plan`** → exit 2, message names the constraint.
- **Non-numeric or `#`-prefixed PR target** → unchanged behavior; the existing
  `PR` branch normalizes `#40` → `ARTIFACT=#40`, `PRNUM=40` and rejects
  non-numeric targets before the role is consulted.
- **Empty target** → unchanged; rejected by the existing non-empty check.
- **Both mode wrappers** → `verifier loop PR` terminates with "stop the loop and
  notify"; `verifier goal PR` with "complete the goal and notify" and the
  2-minute re-read cadence.
- **Goal-prompt budget** → `verifier goal PR` must stay ≤ 4000 characters.
- **Hermeticity** → the builder still makes no `git`/`gh`/network call; the full
  suite still runs offline with no repo.
- **Existing six templates** → unchanged except the three `fixer:PR` lines above.
  `reviewer:PR` in particular is untouched, so a code-reviewer cycle behaves
  exactly as before.
- **Both watchers on one PR** → distinct round titles, independent round
  numbering, one shared fixer that mirrors whichever title it answered.

## Testing

Offline unit tests in `tests/cycle/test-cycle-prompt.sh`, following the existing
`run_cycle` / `assert_contains` harness:

- `verifier loop PR 40` emits the `## Verification round` title, the
  `gh pr view 40 --json body` criteria read, the no-criteria halt instruction,
  the style exclusion, and the loop terminate string.
- `verifier goal PR 40` carries the goal wrapper (cadence + "complete the goal
  and notify"), proving mode stays independent.
- `verifier loop PR "#40"` normalizes to `PR #40` display with bare `40` in the
  `gh` command.
- `verifier` + `spec` → exit 2, stderr names the PR-only constraint.
- `verifier` + `plan` → exit 2, same.
- `verifier goal PR` added to `assert_codex_goal_prompt_fits`.
- Widened `fixer:PR` mentions both round titles and the mirrored reply title.
- The reviewer's channel is unpolluted: `reviewer loop PR 40` does **not**
  contain `Verification round`.

All 47 existing assertions must stay green.

## Out of scope

- `verifier:spec` and `verifier:plan` templates.
- A second, verifier-specific fixer template.
- Any change to `reviewer:PR`, `reviewer:spec`, `reviewer:plan`, `fixer:spec`,
  or `fixer:plan`.
- Reading acceptance criteria from anywhere other than the PR body.
- Teaching the command to launch a reviewer/verifier/fixer set together; each
  invocation still starts exactly one watcher.
- A `/goal` fallback — unchanged from the original design, `goal` mode assumes
  the skill is invocable.
- `VERSION` / `UPGRADE.md`.
