#!/bin/bash
#
# git-merge-pr.sh - Merge PR and cleanup branches
#
# Usage: ./scripts/git-merge-pr.sh <pr-number> [merge-method]
#
# Arguments:
#   pr-number    - PR number to merge
#   merge-method - Optional: merge (default), squash, or rebase
#
set -e

# Use rtk proxy if available (reduces LLM token usage)
if command -v rtk &>/dev/null; then
  rtk() { command rtk "$@"; }
else
  rtk() { "$@"; }
fi

# Track current command for status line
"$(dirname "$0")/set-current-command.sh" merge-pr

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Parse arguments
PR_NUMBER="$1"
MERGE_METHOD="${2:-merge}"

# Validation
if [[ -z "$PR_NUMBER" ]]; then
    echo -e "${RED}Error: PR number required${NC}"
    echo "Usage: $0 <pr-number> [merge-method]"
    exit 1
fi

# Get PR info
PR_BRANCH=$(gh pr view "$PR_NUMBER" --json headRefName -q '.headRefName')
BASE_BRANCH=$(gh pr view "$PR_NUMBER" --json baseRefName -q '.baseRefName')

# All PRs must target main
if [[ "$BASE_BRANCH" != "main" ]]; then
    echo -e "${RED}Error: PR #${PR_NUMBER} targets '$BASE_BRANCH' instead of 'main'${NC}"
    echo "Change the PR base branch to main on GitHub, then retry."
    exit 1
fi

echo -e "${YELLOW}Merging PR #${PR_NUMBER}: ${PR_BRANCH} → ${BASE_BRANCH}${NC}"
echo ""

# Step 1: Stash any local changes
STASHED=false
if [[ -n $(git status --porcelain) ]]; then
    echo -e "${GREEN}[1/5]${NC} Stashing local changes"
    rtk git stash
    STASHED=true
else
    echo -e "${GREEN}[1/5]${NC} No local changes to stash"
fi

# Step 2: Switch to base branch
echo -e "${GREEN}[2/5]${NC} Switching to $BASE_BRANCH"
rtk git checkout "$BASE_BRANCH"

# Step 3: Merge PR
echo -e "${GREEN}[3/5]${NC} Merging PR #$PR_NUMBER (--$MERGE_METHOD)"
gh pr merge "$PR_NUMBER" "--$MERGE_METHOD"

# Step 4: Pull and cleanup
echo -e "${GREEN}[4/5]${NC} Pulling latest and pruning"
rtk git pull origin "$BASE_BRANCH"
rtk git branch -d "$PR_BRANCH" 2>/dev/null || true
rtk git fetch --prune

# Step 5: Restore stash if needed
if [[ "$STASHED" == true ]]; then
    echo -e "${GREEN}[5/5]${NC} Restoring stashed changes"
    rtk git stash pop
else
    echo -e "${GREEN}[5/5]${NC} No stash to restore"
fi

echo ""
echo -e "${GREEN}Done!${NC} PR #$PR_NUMBER merged and cleaned up"
