#!/bin/bash
#
# git-commit-handoff.sh - Commit HANDOFF.md to git history
#
# Usage: ./scripts/git-commit-handoff.sh
#
# Preserves session-handoff notes as durable git history. View past handoffs
# on the current branch with: git log -p HANDOFF.md
#
set -e

# Use rtk proxy if available (reduces LLM token usage)
if command -v rtk &>/dev/null; then
  rtk() { command rtk "$@"; }
else
  rtk() { "$@"; }
fi

# Track current command for status line
"$(dirname "$0")/set-current-command.sh" handoff

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Must be run from repo root (where HANDOFF.md lives)
if [[ ! -f HANDOFF.md ]]; then
    echo -e "${RED}Error: HANDOFF.md not found in current directory${NC}"
    echo "Run this from the repo root, after writing HANDOFF.md."
    exit 1
fi

# No-op if HANDOFF.md has no changes (covers modified + untracked)
if [[ -z "$(git status --porcelain HANDOFF.md)" ]]; then
    echo -e "${YELLOW}No changes to HANDOFF.md — skipping commit${NC}"
    exit 0
fi

# Extract the first non-empty line under "## Task" for the commit subject
TASK=$(awk '/^## Task/{flag=1; next} /^## /{flag=0} flag && NF {print; exit}' HANDOFF.md | head -c 72)
if [[ -z "$TASK" ]]; then
    TASK="update notes"
fi

echo -e "${YELLOW}Committing HANDOFF.md: $TASK${NC}"

rtk git add HANDOFF.md
rtk git commit -m "docs: handoff — $TASK"

echo ""
echo -e "${GREEN}Done!${NC} HANDOFF.md committed."
echo "View past handoffs: git log -p HANDOFF.md"
