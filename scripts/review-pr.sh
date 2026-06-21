#!/usr/bin/env bash
# review-pr.sh [--fast] [--reviewer <claude|codex>] <pr-number|pr-url>
#
# Standalone PR reviewer. Run from inside a checkout of the PR's repo. Fetches
# the PR head into a throwaway worktree and runs the shared review engine:
# selected reviewer reviews the diff, the opposite model fixes findings, commit
# + push to the PR head branch, repeat up to MAX_FIX_ROUNDS, until clean
# (PRREVIEW DONE) or stuck (PRREVIEW DIRTY). Findings/logs land under
# $SPEC2PR_HOME/<id>/.
set -euo pipefail

source "$(dirname "$0")/lib/spec2pr-runtime.sh"
source "$(dirname "$0")/lib/pr-review-engine.sh"

# Distinct contract surface from spec2pr; engine prose/commit/comment knobs.
CONTRACT_PREFIX="PRREVIEW"
REVIEW_RUN_DESC="an automated PR review"
COMMIT_PREFIX="review-pr"
DONE_COMMENT_HEADER="review-pr automated review complete."
# On a clean review, approve the PR and (if it's a draft) mark it ready.
PR_DONE_APPROVE=1

STAGE="preflight"

usage() {
  halt "usage: review-pr.sh [--fast] [--reviewer <claude|codex>] <pr-number|pr-url>"
}

PR_REVIEWER="claude"
PR_REF=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --fast)
      SPEC2PR_CODEX_FAST=1
      shift
      ;;
    --reviewer)
      [ "$#" -ge 2 ] || usage
      PR_REVIEWER="$2"
      shift 2
      ;;
    --reviewer=*)
      PR_REVIEWER="${1#--reviewer=}"
      shift
      ;;
    --*)
      usage
      ;;
    *)
      [ -z "$PR_REF" ] || usage
      PR_REF="$1"
      shift
      ;;
  esac
done

[ -n "$PR_REF" ] || usage
case "$PR_REVIEWER" in
  claude|codex) ;;
  *) usage ;;
esac

require_codex
require_claude
require_dependency gh
require_dependency jq
require_dependency git

# Must run inside a checkout of the PR's repo (gh infers the repo; the local
# clone is where the throwaway worktree comes from).
if ! HOST_REPO="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  halt "not inside a git repository"
fi
REPO_SLUG="$(sanitize "$(basename "$HOST_REPO")")"
[ -n "$REPO_SLUG" ] || halt "empty repository slug"

# Resolve the PR via gh.
pr_json_file="$(mktemp -t review-pr-prview.XXXXXX)"
if ! gh pr view "$PR_REF" \
    --json number,url,headRefName,headRefOid,baseRefName,isCrossRepository,isDraft \
    > "$pr_json_file" 2>/dev/null; then
  rm -f "$pr_json_file"
  halt "gh pr view failed for $PR_REF"
fi
PR_NUMBER="$(jq -r '.number // empty' "$pr_json_file")"
PR_URL="$(jq -r '.url // empty' "$pr_json_file")"
HEAD_REF="$(jq -r '.headRefName // empty' "$pr_json_file")"
HEAD_OID="$(jq -r '.headRefOid // empty' "$pr_json_file")"
BASE_REF="$(jq -r '.baseRefName // empty' "$pr_json_file")"
IS_FORK="$(jq -r '.isCrossRepository // false' "$pr_json_file")"
PR_IS_DRAFT="$(jq -r '.isDraft // false' "$pr_json_file")"
rm -f "$pr_json_file"

[ -n "$PR_NUMBER" ] || halt "could not resolve PR number for $PR_REF"
[ "$IS_FORK" = "true" ] && halt "fork PRs not supported (cannot push fixes to head)"
[ -n "$HEAD_REF" ] || halt "could not resolve PR head ref"
[ -n "$HEAD_OID" ] || halt "could not resolve PR head sha"
[ -n "$BASE_REF" ] || halt "could not resolve PR base ref"
[ -n "$PR_URL" ] || halt "could not resolve PR url"

ID="$REPO_SLUG-pr-$PR_NUMBER"
# Throwaway local branch in the worktree; pushes land on the PR's head ref.
BRANCH="reviewpr/$(sanitize "$HEAD_REF")-pr-$PR_NUMBER"
PUSH_REFSPEC="HEAD:refs/heads/$HEAD_REF"
WORKTREE="$SPEC2PR_WORKTREES/$ID"
META_DIR="$SPEC2PR_HOME/$ID"
STATUS_PATH="$SPEC2PR_HOME/$ID.status"
WT_SPEC_REL=""
WT_PLAN_REL=""

mkdir -p "$SPEC2PR_HOME" "$SPEC2PR_WORKTREES" "$META_DIR"
acquire_lock "$SPEC2PR_HOME/$ID.lock"

git -C "$HOST_REPO" fetch -q origin "$HEAD_REF" || halt "git fetch origin $HEAD_REF failed"
git -C "$HOST_REPO" fetch -q origin "$BASE_REF" || halt "git fetch origin $BASE_REF failed"

# Fresh worktree at the PR head. The lock guarantees no live run owns an
# existing worktree, so clear a stale one before recreating.
if git -C "$HOST_REPO" worktree list --porcelain 2>/dev/null | grep -Fq "worktree $WORKTREE"; then
  git -C "$HOST_REPO" worktree remove --force "$WORKTREE" 2>/dev/null || true
fi
git -C "$HOST_REPO" worktree prune 2>/dev/null || true
if [ -e "$WORKTREE" ]; then
  rm -rf "$WORKTREE"
fi
git -C "$HOST_REPO" branch -D "$BRANCH" 2>/dev/null || true
git -C "$HOST_REPO" worktree add -q -b "$BRANCH" "$WORKTREE" "$HEAD_OID" \
  || halt "git worktree add failed"

BASE_SHA="$(git -C "$WORKTREE" merge-base "origin/$BASE_REF" HEAD)" \
  || halt "could not compute merge-base with origin/$BASE_REF"

status "OK" "preflight ok pr=$PR_URL"

TMP_DIR="$(mktemp -d -t review-pr.XXXXXX)"
write_schemas

pr_review_engine_run "$PR_REVIEWER"
