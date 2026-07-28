#!/usr/bin/env bash
#
# handoff-decision-hits.sh - list decision records covering files touched now
#
# Usage: ./scripts/handoff-decision-hits.sh [<ref>] [<dir>]
#          <ref>  defaults to origin/main
#          <dir>  defaults to docs/decisions
#
# Prints one decision path per line (nothing if there are no hits). Used by
# /rulez:handoff to find decisions that a lesson from this session may have
# invalidated.
#
# Searches the ref rather than the working tree: records live on origin/main and
# are cleared locally after publication (see handoff-push-records.sh), so on any
# branch the working tree may hold none of them.
#
# Lives in a script rather than inline in the command doc because the RTK hook
# rewrites top-level `git ...` into `rtk git ...`, and RTK decorates display
# output with a blank line and a "--- Changes ---" banner. Feeding that blank
# line to a `grep -l` pattern makes it empty, and an empty pattern matches every
# file — so every decision would come back as a hit. Script bodies are not
# rewritten, so `git` here is the real one.
set -uo pipefail

REF="${1:-origin/main}"
DIR="${2:-docs/decisions}"

# No store yet (fresh clone, or nothing ever published) is not an error.
git rev-parse --verify -q "$REF" >/dev/null 2>&1 || exit 0

# Tracked modifications plus new untracked files: a decision can be invalidated
# by a file this session created, not only by one it edited.
{
    git diff --name-only HEAD 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
} | sort -u | while IFS= read -r f; do
    [ -n "$f" ] || continue
    # -F: a path is a literal, not a pattern. An unescaped '.' would match any
    # character and pull in near-miss filenames.
    git grep -l -F -e "$f" "$REF" -- "$DIR" 2>/dev/null
done | sed "s#^${REF}:##" | sort -u
