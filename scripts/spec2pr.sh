#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib/spec2pr-runtime.sh"
source "$(dirname "$0")/lib/pr-review-engine.sh"

usage() {
  halt "usage: spec2pr.sh [--fast] <spec-path>"
}

SPEC_INPUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --fast)
      SPEC2PR_CODEX_FAST=1
      shift
      ;;
    --*)
      usage
      ;;
    *)
      [ -z "$SPEC_INPUT" ] || usage
      SPEC_INPUT="$1"
      shift
      ;;
  esac
done

[ -n "$SPEC_INPUT" ] || usage
if [ ! -f "$SPEC_INPUT" ]; then
  halt "spec not found: $SPEC_INPUT"
fi

SPEC_DIR="$(cd "$(dirname "$SPEC_INPUT")" && pwd -P)"
SPEC_BASENAME="$(basename "$SPEC_INPUT")"
SPEC_ABS="$SPEC_DIR/$SPEC_BASENAME"
if ! GIT_ROOT="$(git -C "$SPEC_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  halt "spec is not inside a git repository"
fi
REPO_SLUG="$(sanitize "$(basename "$GIT_ROOT")")"
SPEC_STEM="${SPEC_BASENAME%.*}"
SPEC_SLUG="$(sanitize "$SPEC_STEM")"
[ -n "$SPEC_SLUG" ] || halt "empty slug"
[ -n "$REPO_SLUG" ] || halt "empty repository slug"

ID="$REPO_SLUG-$SPEC_SLUG"
SLUG="$SPEC_SLUG"
BRANCH="spec2pr/$SPEC_SLUG"
WORKTREE="$SPEC2PR_WORKTREES/$ID"
META_DIR="$SPEC2PR_HOME/$ID"
STATUS_PATH="$SPEC2PR_HOME/$ID.status"
WT_SPEC_REL="${SPEC_ABS#"$GIT_ROOT/"}"
WT_PLAN_REL="docs/superpowers/plans/$SPEC_SLUG-plan.md"

github_repo_slug_from_origin_url() {
  local url="$1"
  local repo=""
  case "$url" in
    https://github.com/*)
      repo="${url#https://github.com/}"
      ;;
    http://github.com/*)
      repo="${url#http://github.com/}"
      ;;
    git@github.com:*)
      repo="${url#git@github.com:}"
      ;;
    ssh://git@github.com/*)
      repo="${url#ssh://git@github.com/}"
      ;;
    *)
      return 1
      ;;
  esac
  repo="${repo%.git}"
  case "$repo" in
    */*)
      printf '%s\n' "$repo"
      ;;
    *)
      return 1
      ;;
  esac
}

build_pr_body() {
  local head_sha="$1"
  local origin_url repo spec_href plan_href
  origin_url="$(git -C "$WORKTREE" config --get remote.origin.url || true)"
  if repo="$(github_repo_slug_from_origin_url "$origin_url")"; then
    spec_href="https://github.com/$repo/blob/$head_sha/$WT_SPEC_REL"
    plan_href="https://github.com/$repo/blob/$head_sha/$WT_PLAN_REL"
  else
    spec_href="$WT_SPEC_REL"
    plan_href="$WT_PLAN_REL"
  fi

  printf 'Automated by spec2pr.\n\n- Spec: [%s](%s)\n- Plan: [%s](%s)' \
    "$WT_SPEC_REL" "$spec_href" "$WT_PLAN_REL" "$plan_href"
}

SPEC_SIZE="$(wc -c < "$SPEC_ABS" | tr -d ' ')"
if [ "$SPEC_SIZE" -gt "$SPEC2PR_MAX_SPEC" ]; then
  split spec "$SPEC_SIZE" "$SPEC2PR_MAX_SPEC"
fi

require_codex
require_claude
require_dependency gh
require_dependency jq
require_dependency git

mkdir -p "$SPEC2PR_HOME" "$SPEC2PR_WORKTREES"
acquire_lock "$SPEC2PR_HOME/$ID.lock"

git -C "$GIT_ROOT" fetch -q origin main || halt "git fetch origin main failed"
SOURCE_SHA="$(sha256_of "$SPEC_ABS")"

if [ -d "$WORKTREE/.git" ] || git -C "$WORKTREE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  [ -f "$META_DIR/source-path" ] || halt "missing metadata: source-path"
  [ -f "$META_DIR/source-sha256" ] || halt "missing metadata: source-sha256"
  [ -f "$META_DIR/base-sha" ] || halt "missing metadata: base-sha"

  RECORDED_SOURCE_PATH="$(cat "$META_DIR/source-path")"
  RECORDED_SOURCE_SHA="$(cat "$META_DIR/source-sha256")"
  BASE_SHA="$(cat "$META_DIR/base-sha")"

  [ "$RECORDED_SOURCE_PATH" = "$SPEC_ABS" ] || halt "worktree belongs to $RECORDED_SOURCE_PATH"
  [ "$RECORDED_SOURCE_SHA" = "$SOURCE_SHA" ] || halt "source spec changed since import"
else
  BASE_SHA="$(git -C "$GIT_ROOT" rev-parse origin/main)" || halt "git rev-parse origin/main failed"
  if git -C "$GIT_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    halt "branch exists without worktree: $BRANCH"
  fi
  git -C "$GIT_ROOT" worktree add -q -b "$BRANCH" "$WORKTREE" "$BASE_SHA" || halt "git worktree add failed"
  mkdir -p "$META_DIR"
  printf '%s\n' "$SPEC_ABS" > "$META_DIR/source-path"
  printf '%s\n' "$SOURCE_SHA" > "$META_DIR/source-sha256"
  printf '%s\n' "$BASE_SHA" > "$META_DIR/base-sha"
fi

if ! git -C "$WORKTREE" log --format=%s "$BASE_SHA..HEAD" | grep -Fqx "spec2pr: import spec"; then
  mkdir -p "$WORKTREE/$(dirname "$WT_SPEC_REL")"
  cp "$SPEC_ABS" "$WORKTREE/$WT_SPEC_REL"
  git -C "$WORKTREE" add "$WT_SPEC_REL"
  git -C "$WORKTREE" commit -q --allow-empty -m "spec2pr: import spec" || halt "git commit import spec failed"
fi

status "OK" "preflight ok"

TMP_DIR="$(mktemp -d -t spec2pr.XXXXXX)"
write_schemas

assert_only_allowed_path_changed() {
  local allowed_path="$1"
  local path
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    [ "$path" = "$allowed_path" ] || halt "$STAGE changed files outside allowed artifact"
  done < <(changed_paths)
}

assert_only_planner_path_changed() {
  local path
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    [ "$path" = "$WT_PLAN_REL" ] || halt "planner changed unexpected files"
  done < <(changed_paths)
}

review_loop() {
  local stage="$1" artifact_desc="$2"
  local allowed_path="${3:-}"
  local round b m fb fm last pf

  for round in $(seq 1 "$MAX_FIX_ROUNDS"); do
    STAGE="$stage"
    if [ -n "$(git -C "$WORKTREE" status --porcelain --untracked-files=all)" ]; then
      halt "dirty worktree before $stage review round"
    fi
    pf="$META_DIR/$stage-r$round.prompt"
    local scope_clause=""
    if [ -n "$allowed_path" ]; then
      scope_clause="You may edit ONLY this file: $allowed_path
Every other file is read-only reference context. If you spot a problem in any
other file, it is OUT OF SCOPE for this round: record it in \"notes\" only,
never edit it, and never count it as a blocker or major finding. A finding is
in scope only if editing $allowed_path alone fully fixes it.

"
    fi
    cat > "$pf" <<EOF
You are one fresh review round in an automated pipeline. No earlier review
context exists; judge only what you can see now.

Artifact under review: $artifact_desc

${scope_clause}1. FIRST, before changing anything, list every in-scope blocker and major
   finding you can see right now. Severity mapping: critical->blocker,
   high->major, medium->major. Minor/low/nit observations go into "notes"
   only, never into findings.
2. THEN fix every blocker and major finding by editing the allowed file
   only. Do not edit, create, or delete any other file. Do not push, do not
   commit, do not create branches or PRs.
3. Your final message must be exactly the JSON required by the output
   schema. blockers_found and majors_found are the counts from step 1
   (before your fixes) and must equal the findings array by severity.
   If step 1 found nothing, change no files and return zeros with an empty
   findings array.
EOF

    codex_call review "$stage-r$round" "$pf"
    last="$META_DIR/$stage-r$round.json"
    b="$(jq -r '.blockers_found' "$last")"
    m="$(jq -r '.majors_found' "$last")"
    fb="$(jq '[.findings[] | select(.severity=="blocker")] | length' "$last")"
    fm="$(jq '[.findings[] | select(.severity=="major")] | length' "$last")"
    if [ "$b" != "$fb" ] || [ "$m" != "$fm" ]; then
      halt "review counts do not match findings ($last)"
    fi

    if [ -n "$allowed_path" ]; then
      assert_only_allowed_path_changed "$allowed_path"
    fi

    if [ "$((b + m))" -eq 0 ]; then
      if [ -n "$(git -C "$WORKTREE" status --porcelain)" ]; then
        halt "clean review round left uncommitted changes (contract violation)"
      fi
      status "OK" "$stage r$round blockers=0 majors=0 clean"
      show_findings "$last"
      return 0
    fi

    status "OK" "$stage r$round blockers=$b majors=$m"
    show_findings "$last"
    if [ -n "$(git -C "$WORKTREE" status --porcelain)" ]; then
      git -C "$WORKTREE" add -A
      git -C "$WORKTREE" commit -q -m "spec2pr: $stage review fixes r$round"
      if [ "$stage" = "pr-review" ]; then
        git -C "$WORKTREE" push -q origin "$BRANCH" || halt "git push failed"
      fi
    fi
  done

  dirty "$stage" "$b" "$m" "$META_DIR/$stage-r$MAX_FIX_ROUNDS.json"
}

review_loop spec-review "the file at $WT_SPEC_REL (a feature spec)" "$WT_SPEC_REL"

STAGE="plan"
if [ ! -f "$WORKTREE/$WT_PLAN_REL" ]; then
  pf="$META_DIR/plan.prompt"
  cat > "$pf" <<EOF
Use \$superpowers:writing-plans to write an implementation plan for the
feature spec at $WT_SPEC_REL.

Create exactly one plan file at $WT_PLAN_REL. Do not edit any other files.
Do not commit, push, or create branches or PRs. Your final message should briefly
summarize the plan.
EOF
  before_plan_head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
  run_claude_json plan "$pf" "$META_DIR/plan.claude.json"
  after_plan_head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
  [ "$after_plan_head" = "$before_plan_head" ] || halt "planner committed changes (contract violation)"
  [ -f "$WORKTREE/$WT_PLAN_REL" ] || halt "planner did not write plan"
  assert_only_planner_path_changed
  plan_summary="$(jq -r '.result // ""' "$META_DIR/plan.claude.json")"
  jq -n --arg p "$WT_PLAN_REL" --arg s "$plan_summary" \
    '{plan_path:$p, summary:$s}' > "$META_DIR/plan.json"
  plan_size="$(wc -c < "$WORKTREE/$WT_PLAN_REL" | tr -d ' ')"
  if [ "$plan_size" -gt "$SPEC2PR_MAX_PLAN" ]; then
    split plan "$plan_size" "$SPEC2PR_MAX_PLAN"
  fi
  if [ -n "$(git -C "$WORKTREE" status --porcelain --untracked-files=all)" ]; then
    git -C "$WORKTREE" add "$WT_PLAN_REL"
    git -C "$WORKTREE" commit -q -m "spec2pr: write plan" || halt "git commit plan failed"
  fi
  status "OK" "plan ok $WT_PLAN_REL"
  show_summary "$META_DIR/plan.json"
else
  status "OK" "plan exists $WT_PLAN_REL"
fi

review_loop plan-review "the file at $WT_PLAN_REL (an implementation plan for the spec at $WT_SPEC_REL)" "$WT_PLAN_REL"

implementation_ok_record() {
  printf 'base=%s\nhead=%s\n' "$1" "$2"
}

STAGE="implement"
if ! PR_URL="$(cd "$WORKTREE" && gh pr list --head "$BRANCH" --state open --json url --jq '.[0].url // empty')"; then
  halt "gh pr list failed"
fi

local_impl_head=""
current_impl_head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
recorded_impl_base=""
recorded_impl_head=""
recorded_impl_marker_valid=0
pre_implementation_reviews_after_implementation=0
unknown_commits_after_implementation=0
if [ -f "$META_DIR/implementation-base" ] \
    && [ -f "$META_DIR/implementation-head" ] \
    && [ -f "$META_DIR/implementation-ok" ] \
    && [ -z "$(git -C "$WORKTREE" status --porcelain --untracked-files=all)" ]; then
  recorded_impl_base="$(cat "$META_DIR/implementation-base")"
  recorded_impl_head="$(cat "$META_DIR/implementation-head")"
  expected_impl_ok="$(implementation_ok_record "$recorded_impl_base" "$recorded_impl_head")"
  recorded_impl_ok="$(cat "$META_DIR/implementation-ok")"
  if [ "$recorded_impl_head" = "$current_impl_head" ] \
      && [ "$recorded_impl_head" != "$recorded_impl_base" ] \
      && git -C "$WORKTREE" merge-base --is-ancestor "$recorded_impl_base" "$recorded_impl_head" \
      && [ "$recorded_impl_ok" = "$expected_impl_ok" ]; then
    local_impl_head="$recorded_impl_head"
    recorded_impl_marker_valid=1
  elif [ "$recorded_impl_head" != "$recorded_impl_base" ] \
      && git -C "$WORKTREE" merge-base --is-ancestor "$recorded_impl_base" "$recorded_impl_head" \
      && [ "$recorded_impl_ok" = "$expected_impl_ok" ] \
      && [ -n "$recorded_impl_head" ] \
      && [ "$recorded_impl_head" != "$current_impl_head" ] \
      && git -C "$WORKTREE" merge-base --is-ancestor "$recorded_impl_head" "$current_impl_head"; then
    while IFS= read -r subject; do
      case "$subject" in
        "spec2pr: spec-review review fixes "*|"spec2pr: plan-review review fixes "*)
          pre_implementation_reviews_after_implementation=1
          break
          ;;
        "spec2pr: pr-review review fixes "*)
          ;;
        *)
          unknown_commits_after_implementation=1
          break
          ;;
      esac
    done < <(git -C "$WORKTREE" log --format=%s "$recorded_impl_head..$current_impl_head")
    if [ "$pre_implementation_reviews_after_implementation" -eq 0 ] \
        && [ "$unknown_commits_after_implementation" -eq 0 ]; then
      local_impl_head="$recorded_impl_head"
      recorded_impl_marker_valid=1
    fi
  fi
fi

if [ "$pre_implementation_reviews_after_implementation" -eq 1 ]; then
  halt "review changes after implementation; rerun implementation required"
fi
if [ "$unknown_commits_after_implementation" -eq 1 ]; then
  halt "commits after implementation require manual review"
fi

if [ -n "$PR_URL" ]; then
  if [ "$recorded_impl_marker_valid" -ne 1 ]; then
    halt "open PR exists without current implementation marker"
  fi
  status "OK" "pr exists $PR_URL"
else
  set +e
  git -C "$WORKTREE" ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1
  ls_remote_rc=$?
  set -e
  if [ "$ls_remote_rc" -eq 0 ]; then
    if [ "$recorded_impl_marker_valid" -ne 1 ]; then
      halt "remote branch exists without current implementation marker"
    fi
    status "OK" "implement exists $BRANCH"
  elif [ "$ls_remote_rc" -eq 2 ]; then
    if [ -n "$local_impl_head" ]; then
      status "OK" "implement exists local $local_impl_head"
    else
      before_impl_head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
      pf="$META_DIR/implement.prompt"
      cat > "$pf" <<EOF
Use \$superpowers:subagent-driven-development to implement the plan at
$WT_PLAN_REL for the spec at $WT_SPEC_REL.

Make the necessary code, test, and documentation changes in this worktree.
Commit the implementation changes. Do not push, do not create a PR.
Your final message must be exactly the JSON required by the output schema.
EOF
      codex_call implement implement "$pf"
      impl_status="$(jq -r '.status' "$META_DIR/implement.json")"
      case "$impl_status" in
        blocked)
          blocked_reason="$(jq -r '.blocked_reason' "$META_DIR/implement.json")"
          halt "$blocked_reason"
          ;;
        done)
          if [ -n "$(git -C "$WORKTREE" status --porcelain --untracked-files=all)" ]; then
            halt "uncommitted changes after done"
          fi
          after_impl_head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
          [ "$after_impl_head" != "$before_impl_head" ] || halt "no implementation commit after done"
          printf '%s\n' "$before_impl_head" > "$META_DIR/implementation-base"
          printf '%s\n' "$after_impl_head" > "$META_DIR/implementation-head"
          implementation_ok_record "$before_impl_head" "$after_impl_head" > "$META_DIR/implementation-ok"
          status "OK" "implement ok $BRANCH"
          show_summary "$META_DIR/implement.json"
          ;;
        *)
          halt "unexpected implement status: $impl_status"
          ;;
      esac
    fi
  else
    halt "git ls-remote failed"
  fi

  STAGE="pr-create"
  git -C "$WORKTREE" push -q -u origin "$BRANCH" || halt "git push failed"
  pr_head_sha="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
  pr_body="$(build_pr_body "$pr_head_sha")"
  if ! pr_create_out="$(cd "$WORKTREE" && gh pr create \
      --title "spec2pr: $SLUG" \
      --body "$pr_body" \
      --base main \
      --head "$BRANCH")"; then
    halt "gh pr create failed"
  fi
  # Real `gh pr create` can print advisory lines to stdout alongside the URL;
  # extract just the PR URL so the DONE contract line stays machine-parseable.
  PR_URL="$(printf '%s\n' "$pr_create_out" | grep -Eo 'https://[^[:space:]]+' | tail -n1 || true)"
  [ -n "$PR_URL" ] || halt "gh pr create did not return URL"
  status "OK" "pr ok $PR_URL"
fi

# pr-review -> done: claude reviews the diff, codex fixes, loop until clean
# (DONE) or stuck (DIRTY). Engine lives in lib/pr-review-engine.sh.
pr_review_engine_run
