#!/bin/bash
#
# git-push-fixes.sh - Add fixes to current branch and push
#
# Usage: ./scripts/git-push-fixes.sh <message> <files...>
#
# Arguments:
#   message - Commit message
#   files   - Files to stage (remaining arguments)
#
set -e

# Use rtk proxy if available (reduces LLM token usage)
if command -v rtk &>/dev/null; then
  rtk() { command rtk "$@"; }
else
  rtk() { "$@"; }
fi

# Track current command for status line
"$(dirname "$0")/set-current-command.sh" push-fixes

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Parse arguments
MESSAGE="$1"
shift
FILES=("$@")

# Validation
if [[ -z "$MESSAGE" || ${#FILES[@]} -eq 0 ]]; then
    echo -e "${RED}Error: Missing required arguments${NC}"
    echo "Usage: $0 <message> <files...>"
    exit 1
fi

BRANCH=$(git branch --show-current)
echo -e "${YELLOW}Pushing fixes to: ${BRANCH}${NC}"
echo ""

# Step 1: Stage files
echo -e "${GREEN}[1/3]${NC} Staging files: ${FILES[*]}"
rtk git add "${FILES[@]}"

# Step 2: Commit
echo -e "${GREEN}[2/3]${NC} Committing changes"
rtk git commit -m "$MESSAGE

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"

# Step 3: Push
echo -e "${GREEN}[3/3]${NC} Pushing to origin"
rtk git push

echo ""
echo -e "${GREEN}Done!${NC} Fixes pushed to $BRANCH"
