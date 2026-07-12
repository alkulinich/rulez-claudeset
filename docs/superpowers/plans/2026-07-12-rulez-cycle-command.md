# /rulez:cycle Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a single `/rulez:cycle` command that assembles one of six verbatim review/fix watcher prompts from three selectors and auto-starts it as a `loop` or `goal`.

**Architecture:** A hermetic prompt-builder shell script (`scripts/cycle-prompt.sh`) holds the six `role×type` body templates plus the two `mode` wrappers, does pure string substitution, and prints the expanded prompt on stdout. A thin command file (`commands/rulez/cycle.md`) runs the builder, captures its stdout, and invokes the `loop`/`goal` skill with that prompt. Offline unit tests (`tests/cycle/`) mirror the `tests/worktree/` harness.

**Tech Stack:** POSIX-ish Bash (must run on macOS system Bash 3.2), the repo's per-directory `run-tests.sh` + `helpers.sh` test convention, `sed` for one path rewrite.

## Global Constraints

- **Bash 3.2 compatible** — no associative arrays, no `${var^^}`, no `mapfile`. `${var//a/b}`, `${var%.md}`, `${var#\#}`, `case`, quoted heredocs are all fine.
- **The six body templates ship verbatim** from the spec's Appendix (`docs/superpowers/specs/2026-07-12-rulez-cycle-command-design.md`). Do not paraphrase, reword, reorder, or "fix" them. Copy the em-dashes (`—`) and arrows (`→`) exactly. The only allowed edits are the `@@TOKEN@@` slots.
- **Hermetic builder** — `cycle-prompt.sh` makes no network calls and runs no `git`/`gh`. Runtime state (SHAs, branch names, round numbers `<N>`, `<date time UTC>`, `git hash-object`) stays as literal instruction text in the output. `sed` for a local string rewrite is allowed.
- **No RTK shim** — the builder runs no display-output commands, so it does not need the `rtk() { ... }` wrapper other scripts use.
- **Stage by exact path only** — never `git add .` / `git add -A`. Never stage these untracked paths: `references/`, `tmp/`, `docs/research-auto-handoff-at-context-threshold.md`, `docs/superpowers/specs/2026-06-29-spec2pr-chain-design.md`, `docs/superpowers/specs/2026-06-30-spec2pr-implementer-switch-design.md`.
- **Commit trailer is one line:** `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. No `Claude-Session` line.
- **Branch:** `feature/rulez-cycle` (already checked out; the spec is already committed at `388fed1`).
- **VERSION / UPGRADE.md untouched** — deferred to a separate release step.

---

### Task 1: `cycle-prompt.sh` builder + offline tests

**Files:**
- Create: `tests/cycle/helpers.sh`
- Create: `tests/cycle/run-tests.sh`
- Create: `tests/cycle/test-cycle-prompt.sh`
- Create: `scripts/cycle-prompt.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `scripts/cycle-prompt.sh <role> <mode> <type> <target...>` — prints the expanded prompt on **stdout**, diagnostics on **stderr**, exit `0` on success and `2` on any validation error (`3` only for an impossible internal template miss). Task 2's command file calls it.

- [ ] **Step 1: Create the test helpers**

Create `tests/cycle/helpers.sh`:

```bash
#!/usr/bin/env bash
# Shared test helpers for tests/cycle/. Source from run-tests.sh.

TESTS_RUN=${TESTS_RUN:-0}
TESTS_FAILED=${TESTS_FAILED:-0}

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
CYCLE_PROMPT="$REPO_ROOT/scripts/cycle-prompt.sh"

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-values not equal}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$expected" = "$actual" ]; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$msg" "$expected" "$actual"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-should contain: $2}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    needle:   %s\n    haystack: %s\n' "$msg" "$needle" "$haystack"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-should not contain: $2}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    unexpected needle present: %s\n' "$msg" "$needle"
  fi
}

# Run the builder; capture stdout (CY_OUT), stderr (CY_ERR), exit code (CY_RC).
run_cycle() {
  local errfile; errfile="$(mktemp)"
  CY_OUT="$(bash "$CYCLE_PROMPT" "$@" 2>"$errfile")"
  CY_RC=$?
  CY_ERR="$(cat "$errfile")"
  rm -f "$errfile"
}
```

- [ ] **Step 2: Create the test runner**

Create `tests/cycle/run-tests.sh` (identical shape to `tests/worktree/run-tests.sh`):

```bash
set -uo pipefail

TESTS_RUN=0
TESTS_FAILED=0

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/helpers.sh"

for f in "$DIR"/test-*.sh; do
  [ -f "$f" ] || continue
  source "$f"
done

for fn in $(declare -F | awk '{print $3}' | grep '^test_' || true); do
  printf '%s\n' "$fn"
  "$fn"
done

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
```

- [ ] **Step 3: Write the failing tests**

Create `tests/cycle/test-cycle-prompt.sh`:

```bash
#!/usr/bin/env bash
# Tests for scripts/cycle-prompt.sh. run_cycle lives in helpers.sh and sets
# CY_OUT / CY_ERR / CY_RC. The builder is hermetic, so these need no git repo.

SPEC_TARGET="docs/superpowers/specs/2026-07-12-foo-design.md"
SPEC_FINDINGS="docs/superpowers/specs/2026-07-12-foo-design-findings.md"
PLAN_TARGET="docs/superpowers/plans/2026-07-12-foo-design-plan.md"
PLAN_FINDINGS="docs/superpowers/plans/2026-07-12-foo-design-plan-findings.md"
DERIVED_SPEC="docs/superpowers/specs/2026-07-12-foo-design.md"

test_cycle_reviewer_spec_loop() {
  run_cycle reviewer loop spec "$SPEC_TARGET"
  assert_eq "0" "$CY_RC" "reviewer/spec/loop: exit 0"
  assert_contains "$CY_OUT" "Watch $SPEC_TARGET for fix cycles." "reviewer/spec/loop: loop RECUR + artifact"
  assert_contains "$CY_OUT" "($SPEC_FINDINGS)" "reviewer/spec/loop: findings path derived"
  assert_contains "$CY_OUT" "stop the loop and notify" "reviewer/spec/loop: loop TERMINATE"
}

test_cycle_fixer_spec_goal() {
  run_cycle fixer goal spec "$SPEC_TARGET"
  assert_eq "0" "$CY_RC" "fixer/spec/goal: exit 0"
  assert_contains "$CY_OUT" "Watch (re-read at least every 2 min) $SPEC_FINDINGS for newly appended" "fixer/spec/goal: goal RECUR watches findings"
  assert_contains "$CY_OUT" "update the spec ($SPEC_TARGET)" "fixer/spec/goal: names the edited spec"
  assert_contains "$CY_OUT" "complete the goal and notify" "fixer/spec/goal: goal TERMINATE"
  assert_contains "$CY_OUT" "wait 2 min without writing anything" "fixer/spec/goal: goal IDLE"
}

test_cycle_reviewer_plan_derives_spec() {
  run_cycle reviewer loop plan "$PLAN_TARGET"
  assert_eq "0" "$CY_RC" "reviewer/plan: exit 0"
  assert_contains "$CY_OUT" "review it against $DERIVED_SPEC" "reviewer/plan: spec derived from plan path"
  assert_contains "$CY_OUT" "$PLAN_FINDINGS" "reviewer/plan: findings path derived"
  assert_contains "$CY_OUT" "the file may not exist yet" "reviewer/plan: first-appearance clause present"
  assert_contains "$CY_OUT" "stop the loop and notify" "reviewer/plan: loop TERMINATE"
}

test_cycle_reviewer_plan_explicit_spec_overrides() {
  run_cycle reviewer loop plan "$PLAN_TARGET" "docs/custom/other-design.md"
  assert_eq "0" "$CY_RC" "reviewer/plan explicit spec: exit 0"
  assert_contains "$CY_OUT" "review it against docs/custom/other-design.md" "reviewer/plan: explicit spec used"
  assert_not_contains "$CY_OUT" "$DERIVED_SPEC" "reviewer/plan: derived spec not used when explicit given"
}

test_cycle_fixer_plan_goal() {
  run_cycle fixer goal plan "$PLAN_TARGET"
  assert_eq "0" "$CY_RC" "fixer/plan: exit 0"
  assert_contains "$CY_OUT" "update the plan ($PLAN_TARGET)" "fixer/plan: names the edited plan"
  assert_contains "$CY_OUT" '`No findings.`' "fixer/plan: backtick-literal No findings clause"
  assert_contains "$CY_OUT" "complete the goal and notify" "fixer/plan: goal TERMINATE"
}

test_cycle_reviewer_pr_hash_and_bare() {
  run_cycle reviewer loop PR "#87"
  assert_eq "0" "$CY_RC" "reviewer/PR #87: exit 0"
  assert_contains "$CY_OUT" "Watch PR #87 for review cycles." "reviewer/PR: #-normalized display"
  assert_contains "$CY_OUT" "run /review 87 against the current head" "reviewer/PR: bare number for /review"
  run_cycle reviewer loop PR 87
  assert_eq "0" "$CY_RC" "reviewer/PR 87: exit 0"
  assert_contains "$CY_OUT" "Watch PR #87 for review cycles." "reviewer/PR bare: same #-display"
}

test_cycle_fixer_pr_worktree_instruction() {
  run_cycle fixer goal PR 87
  assert_eq "0" "$CY_RC" "fixer/PR: exit 0"
  assert_contains "$CY_OUT" "gh pr view 87 --json headRefName" "fixer/PR: branch resolution instruction"
  assert_contains "$CY_OUT" "git-worktree-add.sh <branch>" "fixer/PR: worktree bootstrap instruction"
  assert_contains "$CY_OUT" "complete the goal and notify" "fixer/PR: goal TERMINATE"
}

test_cycle_reviewer_goal_decoupled() {
  run_cycle reviewer goal spec "$SPEC_TARGET"
  assert_eq "0" "$CY_RC" "reviewer+goal: exit 0 (unnatural combo allowed)"
  assert_contains "$CY_OUT" "for fix cycles." "reviewer+goal: reviewer body"
  assert_contains "$CY_OUT" "complete the goal and notify" "reviewer+goal: goal wrapper on reviewer body"
  assert_contains "$CY_OUT" "re-read at least every 2 min" "reviewer+goal: goal cadence applied"
}

test_cycle_rejects_bad_selectors() {
  run_cycle reviwer loop spec "$SPEC_TARGET"
  assert_eq "2" "$CY_RC" "bad role: exit 2"
  assert_contains "$CY_ERR" "usage:" "bad role: usage on stderr"
  run_cycle reviewer looop spec "$SPEC_TARGET"
  assert_eq "2" "$CY_RC" "bad mode: exit 2"
  run_cycle reviewer loop spce "$SPEC_TARGET"
  assert_eq "2" "$CY_RC" "bad type: exit 2"
}

test_cycle_rejects_missing_target() {
  run_cycle reviewer loop spec
  assert_eq "2" "$CY_RC" "missing target: exit 2"
}

test_cycle_plan_underivable_spec_errors() {
  run_cycle reviewer loop plan "docs/superpowers/plans/weird-name.md"
  assert_eq "2" "$CY_RC" "plan without -plan.md and no explicit spec: exit 2"
  assert_contains "$CY_ERR" "end in -plan.md" "plan underivable: explains the error"
}

test_cycle_pr_non_numeric_errors() {
  run_cycle reviewer loop PR abc
  assert_eq "2" "$CY_RC" "non-numeric PR: exit 2"
  assert_contains "$CY_ERR" "PR target must be a number" "non-numeric PR: explains the error"
}
```

- [ ] **Step 4: Run the tests and confirm they fail**

Run: `bash tests/cycle/run-tests.sh`
Expected: nonzero exit; every `run_cycle` reports `CY_RC=127` (script file missing), so the summary shows many failures, e.g. `NN tests run, NN failed`. This proves the tests exercise the not-yet-written builder.

- [ ] **Step 5: Implement the builder**

Create `scripts/cycle-prompt.sh`. Copy the templates **verbatim** — the em-dashes and arrows are literal UTF-8:

```bash
#!/usr/bin/env bash
# cycle-prompt.sh — assemble a /rulez:cycle review/fix watcher prompt.
#
# Usage: cycle-prompt.sh <role> <mode> <type> <target...>
#   role   reviewer | fixer
#   mode   loop | goal
#   type   spec | plan | PR
#   target(s):
#     spec  <spec.md>
#     plan  <plan.md> [<spec.md>]   (spec derived from the plan path if omitted)
#     PR    <#n | n>
#
# Prints the fully expanded prompt on stdout. Hermetic: pure string work, no
# network and no git — runtime state (SHAs, branch names, round numbers, dates)
# stays as literal instructions in the emitted prompt for the loop/goal agent.
set -euo pipefail

usage() {
  echo "usage: cycle-prompt.sh <reviewer|fixer> <loop|goal> <spec|plan|PR> <target...>" >&2
}

if [ "$#" -lt 4 ]; then usage; exit 2; fi
ROLE="$1"; MODE="$2"; TYPE="$3"; shift 3

case "$ROLE" in reviewer|fixer) ;; *) usage; exit 2 ;; esac
case "$MODE" in loop|goal)      ;; *) usage; exit 2 ;; esac
case "$TYPE" in spec|plan|PR)   ;; *) usage; exit 2 ;; esac

# Mode wrapper values — the only mode-dependent text.
case "$MODE" in
  loop)
    RECUR="Watch"
    TERMINATE="stop the loop and notify"
    IDLE="do nothing"
    ;;
  goal)
    RECUR="Watch (re-read at least every 2 min)"
    TERMINATE="complete the goal and notify"
    IDLE="wait 2 min without writing anything"
    ;;
esac

# Target binding + channel derivation (pure string ops).
ARTIFACT=""; FINDINGS=""; SPEC=""; PRNUM=""
case "$TYPE" in
  spec)
    ARTIFACT="$1"
    FINDINGS="${ARTIFACT%.md}-findings.md"
    ;;
  plan)
    ARTIFACT="$1"
    FINDINGS="${ARTIFACT%.md}-findings.md"
    if [ "$#" -ge 2 ]; then
      SPEC="$2"
    else
      case "$ARTIFACT" in
        *-plan.md) ;;
        *) echo "error: plan path must end in -plan.md to derive its spec, or pass the spec explicitly" >&2; exit 2 ;;
      esac
      SPEC="$(printf '%s' "$ARTIFACT" | sed -e 's#-plan\.md$#.md#' -e 's#/plans/#/specs/#')"
    fi
    ;;
  PR)
    PRNUM="${1#\#}"
    case "$PRNUM" in
      ''|*[!0-9]*) echo "error: PR target must be a number (optionally #-prefixed)" >&2; exit 2 ;;
    esac
    ARTIFACT="#$PRNUM"
    ;;
esac

# The six body templates, verbatim from the operator's prompts. Quoted heredocs
# keep backticks and <...> literal; @@TOKENS@@ are substituted afterward.
emit_template() {
  case "$ROLE:$TYPE" in
    reviewer:spec) cat <<'EOF'
@@RECUR@@ @@ARTIFACT@@ for fix cycles.
- No findings file (@@FINDINGS@@) exists yet, OR it has no review round from me → review the spec at its current revision against the codebase, mark each finding [P0 — Blocker] / [P1 — High] / [P2 — Medium] with spec line anchors, and append ONE "## Review round <N> — <date time UTC>" section recording the reviewed spec revision (git hash-object, short) and the findings.
- A new "## Fixes — Review round <N>" section was appended after my last review round AND the spec revision differs from the "Spec revision:" I recorded → re-review the new revision the same way (verify each claimed fix, judge each decline). Don't re-raise findings a prior Fixes section declined with recorded reasons, unless the new revision adds new evidence.
- A new Fixes section declines ALL findings (spec deliberately unchanged) → still run a round: assess the recorded reasons; accept them or rebut with new evidence only.
- A Fixes section claims fixes but the spec revision is unchanged since my last round → do nothing (the edit is lagging the note; wait for it).
- Review of the current revision finds nothing (or all declines accepted) → append the round with "Result: No findings." then @@TERMINATE@@.
Never append idle/no-change rounds to the findings file.
EOF
      ;;
    fixer:spec) cat <<'EOF'
@@RECUR@@ @@FINDINGS@@ for newly appended, unhandled review rounds.
Findings → update the spec (@@ARTIFACT@@) where warranted; disagreements are allowed with rationale. Then append ## Fixes — <round> (<date>) describing fixed vs declined.
No new findings. → @@TERMINATE@@.
No file or No new round → @@IDLE@@.
Never process a round twice or append idle/no-change entries.
EOF
      ;;
    reviewer:plan) cat <<'EOF'
@@RECUR@@ @@ARTIFACT@@ for changes (including its first appearance — the file may not exist yet).
- Plan revision is new (differs from the last revision recorded in the findings file) → review it against @@SPEC@@ and the actual codebase (file paths, line refs, commands, spec coverage, placeholder scan, type consistency), then append a "## Review round <N> — <date time UTC>" section to @@FINDINGS@@ recording the plan revision hash and each finding marked [P0 — Blocker] / [P1 — High] / [P2 — Medium] with concrete anchors. Don't re-raise findings a prior "## Fixes" section already declined with recorded reasons, unless the new revision adds new evidence.
- Review of the current revision finds nothing → append the round with "Result: No findings." then @@TERMINATE@@.
- Plan unchanged since the last reviewed revision → do nothing.
Never append idle/no-change entries to the file.
EOF
      ;;
    fixer:plan) cat <<'EOF'
@@RECUR@@ @@FINDINGS@@ for newly appended, unhandled review rounds.
- Findings → update the plan (@@ARTIFACT@@) where warranted; disagreements are allowed with rationale. Then append `## Fixes — <round> (<date>)` describing fixed vs declined.
- `No findings.` → @@TERMINATE@@.
- No new round → @@IDLE@@.
Never process a round twice or append idle/no-change entries.
EOF
      ;;
    reviewer:PR) cat <<'EOF'
@@RECUR@@ PR @@ARTIFACT@@ for review cycles.
- No review comment from me exists yet, OR a new comment containing "fixed" (case-insensitive) was posted after my last review comment AND the head commit differs from the "Head commit:" recorded in that comment → run /review @@PRNUM@@ against the current head, mark each finding [P0 — Blocker] / [P1 — High] / [P2 — Medium] with file:line anchors, and post ONE PR comment titled "## Review round <N> — <date time UTC>" recording the reviewed head commit SHA and the findings. Don't re-raise findings a prior comment already declined with recorded reasons, unless the new head adds new evidence.
- Review of the current head finds nothing → post the round comment with "Result: No findings." then @@TERMINATE@@.
- A "fixed" comment arrived but the head commit is unchanged since the last reviewed SHA → do nothing (the push is lagging the comment; wait for it).
Never post idle/no-change comments.
EOF
      ;;
    fixer:PR) cat <<'EOF'
@@RECUR@@ PR @@ARTIFACT@@ for new, unhandled reviewer-agent comments titled `## Review round <N> — ...`.
Resolve this PR's head branch with `gh pr view @@PRNUM@@ --json headRefName -q .headRefName`; work in `.worktrees/<branch>` on that branch (create it with `~/.claude/skills/rulez-claudeset/scripts/git-worktree-add.sh <branch>` if it doesn't exist).
For each latest unhandled round:
- `Result: No findings.` → @@TERMINATE@@.
- Findings → verify each against the current PR head; fix what is technically warranted in that worktree. Declines are allowed only with recorded technical rationale.
- Run focused tests and typecheck; commit and push the fixes.
- After the push succeeds, verify PR @@ARTIFACT@@ points to the new HEAD, then post ONE comment titled:
  `## Fixed — Review round <N> — <date time UTC>`
  Include the reviewed SHA, new SHA, fixed vs declined findings, and test evidence.
- Identify handled rounds by reviewer comment ID plus reviewed SHA; never process one twice.
- No new reviewer round, or waiting for review of the pushed head → @@IDLE@@.
Never post `fixed` before the push reaches PR @@ARTIFACT@@. Never create empty commits, touch unrelated files, or post idle/no-change comments. If every finding is declined and no head change is warranted, post one rationale response without `fixed` and notify me instead of fabricating a change.
EOF
      ;;
    *) echo "error: no template for $ROLE:$TYPE" >&2; exit 3 ;;
  esac
}

# Literal token substitution (pure bash; values never contain @@TOKENS@@).
tpl="$(emit_template)"
tpl="${tpl//@@RECUR@@/$RECUR}"
tpl="${tpl//@@TERMINATE@@/$TERMINATE}"
tpl="${tpl//@@IDLE@@/$IDLE}"
tpl="${tpl//@@ARTIFACT@@/$ARTIFACT}"
tpl="${tpl//@@FINDINGS@@/$FINDINGS}"
tpl="${tpl//@@SPEC@@/$SPEC}"
tpl="${tpl//@@PRNUM@@/$PRNUM}"
printf '%s\n' "$tpl"
```

- [ ] **Step 6: Make it executable**

Run: `chmod +x scripts/cycle-prompt.sh`

- [ ] **Step 7: Run the tests and confirm they pass**

Run: `bash tests/cycle/run-tests.sh`
Expected: exit 0 and a final line `NN tests run, 0 failed`. (The suite needs no git repo — passing offline confirms the builder is hermetic.)

- [ ] **Step 8: Commit**

```bash
git add scripts/cycle-prompt.sh tests/cycle/helpers.sh tests/cycle/run-tests.sh tests/cycle/test-cycle-prompt.sh
git commit -m "feat: cycle-prompt.sh — hermetic review/fix watcher prompt builder + tests" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `/rulez:cycle` command file

**Files:**
- Create: `commands/rulez/cycle.md`

**Interfaces:**
- Consumes: `scripts/cycle-prompt.sh <role> <mode> <type> <target...>` from Task 1 (stdout = prompt, nonzero exit = validation error).
- Produces: the `/rulez:cycle` slash command. No downstream consumers.

- [ ] **Step 1: Create the command file**

Create `commands/rulez/cycle.md`:

```markdown
# Cycle — launch a review/fix watcher

Assemble one of the six review/fix watcher prompts and start it as a recurring
`loop` or `goal`. Reviewer and fixer are separate agents — this starts **one**
watcher, not the pair.

## Usage

`/rulez:cycle <reviewer|fixer> <loop|goal> <spec|plan|PR> <target(s)>`

- `spec  <spec.md>`
- `plan  <plan.md> [<spec.md>]`  (spec derived from the plan path if omitted)
- `PR    <#n | n>`

Examples:
- `/rulez:cycle reviewer loop spec docs/superpowers/specs/2026-07-12-foo-design.md`
- `/rulez:cycle fixer goal plan docs/superpowers/plans/2026-07-12-foo-design-plan.md`
- `/rulez:cycle reviewer loop PR 87`

## Instructions

0. **Track command:** `~/.claude/skills/rulez-claudeset/scripts/set-current-command.sh cycle`

1. **Parse** the argument list as `<role> <mode> <type> <target…>`. If there are
   fewer than four words, or `role`/`mode`/`type` are not among the allowed
   values, show the Usage block and stop.

2. **Build the prompt.** Run, capturing stdout:
   `bash ~/.claude/skills/rulez-claudeset/scripts/cycle-prompt.sh <role> <mode> <type> <target…>`
   If the script exits nonzero, show its stderr and stop.

3. **Auto-start the watcher.** Invoke the `<mode>` skill (the literal `loop` or
   `goal` the user passed) via the Skill tool, passing the captured stdout as
   its prompt argument. That turns this agent into the watcher; do **not** also
   run the protocol yourself.

4. Tell the user which watcher started (role / mode / type / target) and that it
   runs until its stop condition. Stop.
```

- [ ] **Step 2: Verify the documented invocation works**

The command file is prose (no unit test), so verify its script call is correct by running the exact invocation it documents and confirming a well-formed first line:

Run: `bash ~/.claude/skills/rulez-claudeset/scripts/cycle-prompt.sh reviewer loop spec docs/superpowers/specs/2026-07-12-foo-design.md | head -1`
Expected: `Watch docs/superpowers/specs/2026-07-12-foo-design.md for fix cycles.`

Note: this uses the installed path (`~/.claude/skills/rulez-claudeset/...`). If the global install hasn't pulled this branch yet, run the same check against the working copy instead: `bash scripts/cycle-prompt.sh reviewer loop spec docs/superpowers/specs/2026-07-12-foo-design.md | head -1` (same expected output).

- [ ] **Step 3: Commit**

```bash
git add commands/rulez/cycle.md
git commit -m "feat: /rulez:cycle command — launch review/fix watchers" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage:**
- Command shape `<role> <mode> <type> <target(s)>`, no coupling → Task 2 command + Task 1 validation (`test_cycle_reviewer_goal_decoupled` proves decoupling). ✓
- Approach A (command + builder script + tests) → Tasks 1 & 2. ✓
- `body = f(role,type)` + `wrapper = f(mode)` via slots → Task 1 `emit_template` + wrapper `case`. ✓
- Six verbatim templates → Task 1 Step 5, flagged verbatim in Global Constraints. ✓
- Auto-start `Skill(mode, prompt)` → Task 2 Step 3. ✓
- Hermetic builder → Task 1 code (no git/gh/network); offline tests confirm. ✓
- Targets/derivations (findings `${t%.md}-findings.md`; plan→spec; PR `#` strip) → Task 1 code + tests `derives_spec`, `explicit_spec_overrides`, `pr_hash_and_bare`, `plan_underivable`, `pr_non_numeric`. ✓
- PR fixer worktree/branch as instruction (not baked) → `fixer:PR` template + `test_cycle_fixer_pr_worktree_instruction`. ✓
- VERSION/UPGRADE.md untouched → Global Constraints, no task edits them. ✓

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code; both run steps give exact expected output. ✓

**3. Type consistency:** `CY_OUT`/`CY_ERR`/`CY_RC` set by `run_cycle` (helpers) and read by every test. `CYCLE_PROMPT` defined in helpers, used by `run_cycle`. Builder var names (`ROLE/MODE/TYPE/ARTIFACT/FINDINGS/SPEC/PRNUM/RECUR/TERMINATE/IDLE`) consistent between binding and substitution. Token names (`@@RECUR@@` …) match between templates and the substitution block. ✓

## Execution Handoff

Two tasks, TDD, one file + tests then one thin command. Recommend **Inline Execution** (executing-plans) with a checkpoint after Task 1's tests go green — proportional to a 2-task shell change, consistent with how `git-worktree-add` was executed.
