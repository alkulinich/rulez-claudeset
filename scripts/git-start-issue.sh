#!/bin/bash
#
# git-start-issue.sh - Start working on a GitHub issue
#
# Usage: ./scripts/git-start-issue.sh <issue-number> [branch-name]
#
# Arguments:
#   issue-number - GitHub issue number
#   branch-name  - Optional custom branch name (default: feature/{issue}-{title-slug})
#
# What it does:
#   1. Fetches issue details from GitHub
#   2. Stashes any local changes
#   3. Updates main branch
#   4. Creates feature branch
#   5. Restores stashed changes
#   6. Outputs issue details for context
#
set -e

# Use rtk proxy if available (reduces LLM token usage)
if command -v rtk &>/dev/null; then
  rtk() { command rtk "$@"; }
else
  rtk() { "$@"; }
fi

# Track current command for status line
"$(dirname "$0")/set-current-command.sh" start-issue

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Parse arguments
ISSUE_NUMBER="$1"
CUSTOM_BRANCH="$2"

# Validation
if [[ -z "$ISSUE_NUMBER" ]]; then
    echo -e "${RED}Error: Issue number required${NC}"
    echo "Usage: $0 <issue-number> [branch-name]"
    exit 1
fi

# Step 1: Fetch issue details
echo -e "${GREEN}[1/5]${NC} Fetching issue #$ISSUE_NUMBER"
ISSUE_JSON=$(gh issue view "$ISSUE_NUMBER" --json title,body,labels,state)
ISSUE_TITLE=$(echo "$ISSUE_JSON" | jq -r '.title')
ISSUE_STATE=$(echo "$ISSUE_JSON" | jq -r '.state')
ISSUE_BODY=$(echo "$ISSUE_JSON" | jq -r '.body')

if [[ "$ISSUE_STATE" == "CLOSED" ]]; then
    echo -e "${YELLOW}Warning: Issue #$ISSUE_NUMBER is closed${NC}"
fi

# Generate branch name if not provided
if [[ -z "$CUSTOM_BRANCH" ]]; then
    # Create slug from title: lowercase, replace spaces/special chars with hyphens, truncate
    SLUG=$(echo "$ISSUE_TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/\[.*\]//g' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//' | cut -c1-40)
    BRANCH="feature/${ISSUE_NUMBER}-${SLUG}"
else
    BRANCH="$CUSTOM_BRANCH"
fi

echo -e "  Title: ${CYAN}$ISSUE_TITLE${NC}"
echo -e "  Branch: ${CYAN}$BRANCH${NC}"
echo ""

# Step 2: Stash local changes if any
STASHED=false
if [[ -n $(git status --porcelain) ]]; then
    echo -e "${GREEN}[2/5]${NC} Stashing local changes"
    rtk git stash push -m "start-issue: before issue #$ISSUE_NUMBER"
    STASHED=true
else
    echo -e "${GREEN}[2/5]${NC} No local changes to stash"
fi

# Step 3: Update main
echo -e "${GREEN}[3/5]${NC} Updating main branch"
rtk git checkout main
rtk git pull origin main

# Step 4: Create or checkout feature branch
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    echo -e "${GREEN}[4/5]${NC} Checking out existing branch: $BRANCH"
    rtk git checkout "$BRANCH"
elif git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
    echo -e "${GREEN}[4/5]${NC} Checking out remote branch: $BRANCH"
    rtk git checkout -b "$BRANCH" "origin/$BRANCH"
else
    echo -e "${GREEN}[4/5]${NC} Creating branch: $BRANCH"
    rtk git checkout -b "$BRANCH"
fi

# Step 5: Restore stash if needed
if [[ "$STASHED" == true ]]; then
    echo -e "${GREEN}[5/5]${NC} Restoring stashed changes"
    rtk git stash pop
else
    echo -e "${GREEN}[5/5]${NC} No stash to restore"
fi

echo ""
echo -e "${GREEN}Ready to work on Issue #$ISSUE_NUMBER${NC}"
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}$ISSUE_TITLE${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "$ISSUE_BODY"
