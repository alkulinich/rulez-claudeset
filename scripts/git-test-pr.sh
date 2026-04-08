#!/bin/bash
#
# git-test-pr.sh - Checkout a PR and prepare for testing
#
# Usage: ./scripts/git-test-pr.sh <pr-number>
#
# What it does:
#   1. Fetches PR details
#   2. Stashes local changes
#   3. Checks out the PR branch
#   4. Runs npm install if package.json changed
#   5. Outputs PR info and changed files
#
set -e

# Use rtk proxy if available (reduces LLM token usage)
if command -v rtk &>/dev/null; then
  rtk() { command rtk "$@"; }
else
  rtk() { "$@"; }
fi

# Track current command for status line
"$(dirname "$0")/set-current-command.sh" test-pr

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Parse arguments
PR_NUMBER="$1"

# Validation
if [[ -z "$PR_NUMBER" ]]; then
    echo -e "${RED}Error: PR number required${NC}"
    echo "Usage: $0 <pr-number>"
    exit 1
fi

# Step 1: Fetch PR details
echo -e "${GREEN}[1/5]${NC} Fetching PR #$PR_NUMBER details"
PR_JSON=$(gh pr view "$PR_NUMBER" --json title,body,headRefName,baseRefName,state,changedFiles)
PR_TITLE=$(echo "$PR_JSON" | jq -r '.title')
PR_BRANCH=$(echo "$PR_JSON" | jq -r '.headRefName')
PR_STATE=$(echo "$PR_JSON" | jq -r '.state')

if [[ "$PR_STATE" != "OPEN" ]]; then
    echo -e "${YELLOW}Warning: PR #$PR_NUMBER is $PR_STATE${NC}"
fi

echo -e "  Title: ${CYAN}$PR_TITLE${NC}"
echo -e "  Branch: ${CYAN}$PR_BRANCH${NC}"

# Step 2: Stash local changes
STASHED=false
if [[ -n $(git status --porcelain) ]]; then
    echo -e "${GREEN}[2/5]${NC} Stashing local changes"
    rtk git stash push -m "test-pr: before testing PR #$PR_NUMBER"
    STASHED=true
else
    echo -e "${GREEN}[2/5]${NC} No local changes to stash"
fi

# Step 3: Checkout PR branch
echo -e "${GREEN}[3/5]${NC} Checking out PR branch"
gh pr checkout "$PR_NUMBER"

# Step 4: Install dependencies if needed
PR_DIFF_FILES=$(gh pr diff "$PR_NUMBER" --name-only 2>/dev/null || true)
if echo "$PR_DIFF_FILES" | grep -q "package.json\|package-lock.json"; then
    echo -e "${GREEN}[4/5]${NC} package.json changed - running npm install"
    npm install
else
    echo -e "${GREEN}[4/5]${NC} No dependency changes"
fi

# Step 5: Output summary
echo -e "${GREEN}[5/5]${NC} Ready for testing"
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}PR #$PR_NUMBER: $PR_TITLE${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${GREEN}Changed files:${NC}"
echo "$PR_DIFF_FILES" | sed 's/^/  /'
echo ""

if [[ "$STASHED" == true ]]; then
    echo -e "${YELLOW}Note: Local changes stashed. Run 'git stash pop' to restore.${NC}"
fi
