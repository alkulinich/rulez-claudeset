#!/bin/bash
#
# git-create-pr.sh - Create a feature branch, commit, push, and open PR
#
# Usage: ./scripts/git-create-pr.sh <branch> <base> <title> <body> <files...>
#
# Arguments:
#   branch  - Branch name (e.g., feature/issue-3-error-handler)
#   base    - Base branch to merge into (e.g., main)
#   title   - Commit message and PR title
#   body    - PR body (markdown)
#   files   - Files to stage (remaining arguments)
#
# Handles edge cases:
#   - Branch already exists: checks out existing branch
#   - No changes to commit: skips commit step
#   - Already pushed: skips push step
#   - PR already exists: shows existing PR URL
#
set -e

# Use rtk proxy if available (reduces LLM token usage)
if command -v rtk &>/dev/null; then
  rtk() { command rtk "$@"; }
else
  rtk() { "$@"; }
fi

# Track current command for status line
"$(dirname "$0")/set-current-command.sh" create-pr

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Parse arguments
BRANCH="$1"
BASE="main"  # GitHub Flow: always target main
TITLE="$3"
BODY="$4"
shift 4 2>/dev/null || true
FILES=("$@")

# Validation
if [[ -z "$BRANCH" || -z "$BASE" || -z "$TITLE" ]]; then
    echo -e "${RED}Error: Missing required arguments${NC}"
    echo "Usage: $0 <branch> <base> <title> <body> <files...>"
    exit 1
fi


echo -e "${YELLOW}Creating PR: ${TITLE}${NC}"
echo ""

# Step 1: Create or checkout branch
CURRENT_BRANCH=$(git branch --show-current)
if [[ "$CURRENT_BRANCH" == "$BRANCH" ]]; then
    echo -e "${GREEN}[1/5]${NC} Already on branch: $BRANCH"
elif git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    echo -e "${GREEN}[1/5]${NC} Checking out existing branch: $BRANCH"
    rtk git checkout "$BRANCH"
else
    echo -e "${GREEN}[1/5]${NC} Creating branch: $BRANCH"
    rtk git checkout -b "$BRANCH"
fi

# Step 2: Stage files (if any provided)
if [[ ${#FILES[@]} -gt 0 ]]; then
    echo -e "${GREEN}[2/5]${NC} Staging files: ${FILES[*]}"
    rtk git add "${FILES[@]}"
else
    echo -e "${GREEN}[2/5]${NC} No files specified, skipping staging"
fi

# Step 3: Commit (if there are staged changes)
if git diff --cached --quiet; then
    echo -e "${GREEN}[3/5]${NC} No staged changes, skipping commit"
else
    echo -e "${GREEN}[3/5]${NC} Committing changes"
    rtk git commit -m "$TITLE

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
fi

# Step 4: Push (if there are unpushed commits)
LOCAL_COMMIT=$(git rev-parse HEAD)
REMOTE_COMMIT=$(git rev-parse "origin/$BRANCH" 2>/dev/null || echo "none")

if [[ "$LOCAL_COMMIT" == "$REMOTE_COMMIT" ]]; then
    echo -e "${GREEN}[4/5]${NC} Already pushed, skipping"
else
    echo -e "${GREEN}[4/5]${NC} Pushing to origin"
    rtk git push -u origin "$BRANCH"
fi

# Step 5: Create PR (if it doesn't exist)
EXISTING_PR=$(gh pr list --head "$BRANCH" --json url -q '.[0].url' 2>/dev/null || true)

if [[ -n "$EXISTING_PR" ]]; then
    echo -e "${GREEN}[5/5]${NC} PR already exists"
    echo ""
    echo -e "${GREEN}Done!${NC} Existing PR: $EXISTING_PR"
else
    echo -e "${GREEN}[5/5]${NC} Creating pull request"
    PR_URL=$(gh pr create --base "$BASE" --title "$TITLE" --body "$BODY")
    echo ""
    echo -e "${GREEN}Done!${NC} PR created: $PR_URL"
fi
