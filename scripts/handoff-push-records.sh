#!/usr/bin/env bash
#
# handoff-push-records.sh - publish lesson/decision records to origin/<branch>
#
# Usage: ./scripts/handoff-push-records.sh [--prune] [<branch>]
#          --prune   also delete records absent locally (authoritative sync;
#                    use after curating by hand, i.e. from /rulez:lessons-pack)
#          <branch>  defaults to main
#
# Records are branch-independent: origin/main is the store and the working tree
# is scratch. A lesson learned on a branch that never merges must still survive,
# so this builds a commit directly on origin/<branch> and pushes it — without
# switching branches, stashing, or touching the current checkout's index. The
# commit is assembled in a private index file.
#
# It then removes the local copies that are untracked here. That cleanup is not
# tidiness: a file untracked in this working tree but tracked on main makes git
# refuse every future `checkout` of a branch that has it ("untracked working
# tree files would be overwritten"), which would break git-merge-pr.sh, whose
# plain `git stash` leaves untracked files exactly where the checkout trips.
#
# Default mode is additive — it never removes a record from the store. Pruning
# is deliberate and belongs to the curation step, not to an unattended handoff.
#
# Exit codes:
#   0  pushed, or nothing new to push
#   2  not a git repo / no origin remote
#   3  fetch or push refused (protected branch, no permission, offline).
#      Local records are left untouched so nothing is lost.
set -uo pipefail

PRUNE=0
if [ "${1:-}" = "--prune" ]; then
    PRUNE=1
    shift
fi
BRANCH="${1:-main}"

# Parsed output only — never the RTK proxy. See handoff-decision-hits.sh.
git rev-parse --git-dir >/dev/null 2>&1 || { echo "error: not a git repository" >&2; exit 2; }
git remote get-url origin >/dev/null 2>&1 || { echo "error: no 'origin' remote" >&2; exit 2; }

RECORD_DIRS="docs/lessons docs/decisions"
RECORD_FILES="LESSONS.md DECISIONS.md"

# Every record path present in the working tree, one per line.
collect_local() {
    local p
    for p in $RECORD_DIRS; do
        [ -d "$p" ] && find "$p" -type f -name '*.md'
    done
    for p in $RECORD_FILES; do
        [ -f "$p" ] && printf '%s\n' "$p"
    done
    return 0
}

LOCAL_RECORDS="$(collect_local | sort)"
if [ -z "$LOCAL_RECORDS" ]; then
    # Pruning against an empty working tree would delete the entire store. That
    # is what running --prune from a branch where records aren't tracked looks
    # like, and it is never what anyone meant.
    if [ "$PRUNE" -eq 1 ]; then
        echo "error: --prune with no local records would empty the store; refusing" >&2
        echo "hint: curate from a branch that has the records checked out" >&2
        exit 2
    fi
    echo "No records to publish."
    exit 0
fi

SRC_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo detached)"
IDX="$(git rev-parse --git-dir)/handoff-records-index"

# Two attempts: the branch can move between our fetch and our push, and the
# rebuild is cheap. Beyond that, something else is wrong — report and stop.
attempt=0
pushed=0
while [ "$attempt" -lt 2 ]; do
    attempt=$((attempt + 1))

    if ! git fetch -q origin "$BRANCH" 2>/dev/null; then
        echo "error: could not fetch origin/$BRANCH — records left in place" >&2
        exit 3
    fi
    BASE="$(git rev-parse FETCH_HEAD)"

    rm -f "$IDX"
    GIT_INDEX_FILE="$IDX" git read-tree "$BASE"

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        GIT_INDEX_FILE="$IDX" git update-index --add -- "$f"
    done <<EOF
$LOCAL_RECORDS
EOF

    if [ "$PRUNE" -eq 1 ]; then
        # Anything the store has under the record paths but the working tree
        # no longer does was pruned by hand — carry that deletion through.
        while IFS= read -r stored; do
            [ -n "$stored" ] || continue
            [ -e "$stored" ] && continue
            GIT_INDEX_FILE="$IDX" git update-index --force-remove -- "$stored"
        done <<EOF
$(git ls-tree -r --name-only "$BASE" -- $RECORD_DIRS $RECORD_FILES 2>/dev/null)
EOF
    fi

    TREE="$(GIT_INDEX_FILE="$IDX" git write-tree)"
    rm -f "$IDX"

    # Exact, not heuristic: an identical tree means there is nothing to say.
    if [ "$TREE" = "$(git rev-parse "$BASE^{tree}")" ]; then
        echo "No record changes — nothing to publish."
        exit 0
    fi

    NEW="$(git commit-tree "$TREE" -p "$BASE" -m "docs: records from $SRC_BRANCH")"
    if git push -q origin "$NEW:refs/heads/$BRANCH" 2>/dev/null; then
        pushed=1
        break
    fi
done

if [ "$pushed" -ne 1 ]; then
    echo "error: push to origin/$BRANCH refused — records left in place" >&2
    exit 3
fi

echo "Published records to origin/$BRANCH (${NEW:0:7})."

# Drop only the copies untracked *here*. Records inherited from the store are
# tracked on this branch and must stay: LESSONS.md is imported by CLAUDE.md.
removed=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    if git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
        continue
    fi
    rm -f "$f"
    removed=$((removed + 1))
done <<EOF
$LOCAL_RECORDS
EOF

for d in $RECORD_DIRS; do
    [ -d "$d" ] && rmdir "$d" 2>/dev/null
done
rmdir docs 2>/dev/null

[ "$removed" -gt 0 ] && echo "Cleared $removed local scratch record(s); the store has them."
exit 0
