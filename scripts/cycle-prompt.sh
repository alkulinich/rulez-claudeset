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
