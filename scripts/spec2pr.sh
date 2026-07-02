#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib/spec2pr-runtime.sh"
source "$(dirname "$0")/lib/pr-review-engine.sh"

usage() {
  halt "usage: spec2pr.sh [--fast] [--implementer codex|claude|claude:sonnet] [--ignore-plan-limit] [--ignore-pr-limit] [--start-from spec-review|plan|plan-review|implementation] [--base <branch>] [--no-pr] <spec-path>"
}

SPEC_INPUT=""
START_FROM="spec-review"
START_FROM_GIVEN=0
IMPLEMENTER_AGENT="codex"
IMPLEMENTER_MODEL=""
IMPLEMENTER_AGENT_GIVEN=0
BASE_BRANCH="main"
BASE_BRANCH_GIVEN=0
NO_PR=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --fast)
      SPEC2PR_CODEX_FAST=1
      shift
      ;;
    --ignore-plan-limit)
      IGNORE_PLAN_LIMIT=1
      shift
      ;;
    --ignore-pr-limit)
      IGNORE_PR_LIMIT=1
      shift
      ;;
    --start-from)
      shift
      [ "$#" -gt 0 ] || usage
      START_FROM="$1"
      START_FROM_GIVEN=1
      shift
      ;;
    --implementer)
      shift
      [ "$#" -gt 0 ] || usage
      IMPLEMENTER_AGENT="$1"
      IMPLEMENTER_AGENT_GIVEN=1
      shift
      ;;
    --implementer=*)
      IMPLEMENTER_AGENT="${1#--implementer=}"
      IMPLEMENTER_AGENT_GIVEN=1
      shift
      ;;
    --base)
      shift
      [ "$#" -gt 0 ] || usage
      BASE_BRANCH="$1"
      BASE_BRANCH_GIVEN=1
      shift
      ;;
    --base=*)
      BASE_BRANCH="${1#--base=}"
      BASE_BRANCH_GIVEN=1
      shift
      ;;
    --no-pr)
      NO_PR=1
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

case "$IMPLEMENTER_AGENT" in
  codex)
    IMPLEMENTER_MODEL="" ;;
  claude)
    IMPLEMENTER_MODEL="" ;;
  claude:sonnet)
    IMPLEMENTER_AGENT="claude"
    IMPLEMENTER_MODEL="sonnet" ;;
  *)
    halt "invalid --implementer: $IMPLEMENTER_AGENT (want codex|claude|claude:sonnet)" ;;
esac

[ -n "$SPEC_INPUT" ] || usage

stage_index() {
  case "$1" in
    spec-review) printf 1 ;;
    plan)        printf 2 ;;
    plan-review) printf 3 ;;
    implementation) printf 4 ;;
    *) printf 0 ;;
  esac
}
START_INDEX="$(stage_index "$START_FROM")"
[ "$START_INDEX" -ge 1 ] || usage

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

git -C "$GIT_ROOT" fetch -q origin "$BASE_BRANCH" || halt "git fetch origin $BASE_BRANCH failed"
SOURCE_SHA="$(sha256_of "$SPEC_ABS")"

if [ -d "$WORKTREE/.git" ] || git -C "$WORKTREE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  WORKTREE_RESUMED=1
else
  WORKTREE_RESUMED=0
fi

if [ "$START_FROM_GIVEN" -eq 1 ] && [ "$WORKTREE_RESUMED" -eq 0 ]; then
  halt "no worktree to restart; run spec2pr without --start-from first"
fi

if [ "$WORKTREE_RESUMED" -eq 1 ]; then
  [ -f "$META_DIR/source-path" ] || halt "missing metadata: source-path"
  [ -f "$META_DIR/source-sha256" ] || halt "missing metadata: source-sha256"
  [ -f "$META_DIR/base-sha" ] || halt "missing metadata: base-sha"

  RECORDED_SOURCE_PATH="$(cat "$META_DIR/source-path")"
  RECORDED_SOURCE_SHA="$(cat "$META_DIR/source-sha256")"
  BASE_SHA="$(cat "$META_DIR/base-sha")"
  if [ -f "$META_DIR/base-branch" ]; then
    RECORDED_BASE_BRANCH="$(cat "$META_DIR/base-branch")"
  else
    RECORDED_BASE_BRANCH="main"
    printf '%s\n' "main" > "$META_DIR/base-branch"
  fi
  if [ "$BASE_BRANCH_GIVEN" -eq 1 ]; then
    [ "$BASE_BRANCH" = "$RECORDED_BASE_BRANCH" ] \
      || halt "worktree base is $RECORDED_BASE_BRANCH; rerun with matching --base or omit the flag"
  else
    BASE_BRANCH="$RECORDED_BASE_BRANCH"
  fi

  [ "$RECORDED_SOURCE_PATH" = "$SPEC_ABS" ] || halt "worktree belongs to $RECORDED_SOURCE_PATH"
  [ "$RECORDED_SOURCE_SHA" = "$SOURCE_SHA" ] || halt "source spec changed since import"
  if [ -f "$META_DIR/implementer-agent" ]; then
    RECORDED_AGENT="$(cat "$META_DIR/implementer-agent")"
  else
    RECORDED_AGENT="codex"
    printf '%s\n' "$RECORDED_AGENT" > "$META_DIR/implementer-agent"
  fi
  if [ -f "$META_DIR/implementer-model" ]; then
    RECORDED_MODEL="$(cat "$META_DIR/implementer-model")"
  else
    RECORDED_MODEL=""
    printf '%s\n' "$RECORDED_MODEL" > "$META_DIR/implementer-model"
  fi
  case "$RECORDED_AGENT:$RECORDED_MODEL" in
    codex:|claude:|claude:sonnet) ;;
    *) halt "invalid worktree implementer metadata: $RECORDED_AGENT/$RECORDED_MODEL" ;;
  esac
  recorded_display="$RECORDED_AGENT"
  if [ -n "$RECORDED_MODEL" ]; then
    recorded_display="$RECORDED_AGENT:$RECORDED_MODEL"
  fi
  if [ "$IMPLEMENTER_AGENT_GIVEN" -eq 1 ]; then
    [ "$IMPLEMENTER_AGENT" = "$RECORDED_AGENT" ] && [ "$IMPLEMENTER_MODEL" = "$RECORDED_MODEL" ] \
      || halt "worktree implementer is $recorded_display; rerun with matching --implementer or omit the flag"
  else
    IMPLEMENTER_AGENT="$RECORDED_AGENT"
    IMPLEMENTER_MODEL="$RECORDED_MODEL"
  fi
else
  BASE_SHA="$(git -C "$GIT_ROOT" rev-parse "origin/$BASE_BRANCH")" || halt "git rev-parse origin/$BASE_BRANCH failed"
  if git -C "$GIT_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    halt "branch exists without worktree: $BRANCH"
  fi
  git -C "$GIT_ROOT" worktree add -q -b "$BRANCH" "$WORKTREE" "$BASE_SHA" || halt "git worktree add failed"
  mkdir -p "$META_DIR"
  printf '%s\n' "$SPEC_ABS" > "$META_DIR/source-path"
  printf '%s\n' "$SOURCE_SHA" > "$META_DIR/source-sha256"
  printf '%s\n' "$BASE_SHA" > "$META_DIR/base-sha"
  printf '%s\n' "$BASE_BRANCH" > "$META_DIR/base-branch"
  printf '%s\n' "$IMPLEMENTER_AGENT" > "$META_DIR/implementer-agent"
  printf '%s\n' "$IMPLEMENTER_MODEL" > "$META_DIR/implementer-model"
fi

commit_with_subject() {
  local want="$1" line
  while IFS= read -r line; do
    if [ "${line#* }" = "$want" ]; then
      printf '%s' "${line%% *}"
      return 0
    fi
  done < <(git -C "$WORKTREE" log --format='%H %s' "$BASE_SHA..HEAD")
}

newest_commit_with_prefix() {
  local prefix="$1" line subject
  while IFS= read -r line; do
    subject="${line#* }"
    case "$subject" in
      "$prefix"*)
        printf '%s' "${line%% *}"
        return 0
        ;;
    esac
  done < <(git -C "$WORKTREE" log --format='%H %s' "$BASE_SHA..HEAD")
}

if [ "$START_FROM_GIVEN" -eq 1 ]; then
  STAGE="restart"
  if [ "$NO_PR" -eq 1 ]; then
    open_pr=""
  else
    open_pr="$(cd "$WORKTREE" && gh pr list --head "$BRANCH" --state open --json url --jq '.[0].url // empty')" \
      || halt "gh pr list failed"
  fi
  if [ -n "$open_pr" ]; then
    halt "open PR or remote branch exists for $BRANCH; close it and delete the branch, then re-run"
  fi
  set +e
  git -C "$WORKTREE" ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1
  ls_remote_rc=$?
  set -e
  if [ "$ls_remote_rc" -eq 0 ]; then
    halt "open PR or remote branch exists for $BRANCH; close it and delete the branch, then re-run"
  elif [ "$ls_remote_rc" -ne 2 ]; then
    halt "git ls-remote failed"
  fi

  restart_boundary=""
  case "$START_FROM" in
    spec-review)
      restart_boundary="$(commit_with_subject "spec2pr: import spec")"
      ;;
    plan)
      restart_boundary="$(newest_commit_with_prefix "spec2pr: spec-review review fixes ")"
      if [ -z "$restart_boundary" ]; then
        restart_boundary="$(commit_with_subject "spec2pr: import spec")"
      fi
      ;;
    plan-review)
      restart_boundary="$(commit_with_subject "spec2pr: write plan")"
      if [ -z "$restart_boundary" ]; then
        halt "no plan committed; restart from plan instead"
      fi
      ;;
    implementation)
      if [ -s "$META_DIR/implementation-base" ]; then
        restart_boundary="$(cat "$META_DIR/implementation-base")"
      fi
      if [ -z "$restart_boundary" ]; then
        restart_boundary="$(newest_commit_with_prefix "spec2pr: plan-review review fixes ")"
      fi
      if [ -z "$restart_boundary" ]; then
        restart_boundary="$(commit_with_subject "spec2pr: write plan")"
      fi
      if [ -z "$restart_boundary" ]; then
        halt "no reviewed plan boundary; restart from plan-review instead"
      fi
      ;;
  esac
  [ -n "$restart_boundary" ] || halt "could not resolve boundary for $START_FROM"

  reset_worktree_to "$restart_boundary"
  case "$START_FROM" in
    spec-review|plan)
      rm -f "$META_DIR/plan.json" \
        "$META_DIR/implementation-base" \
        "$META_DIR/implementation-head" \
        "$META_DIR/implementation-ok"
      ;;
    plan-review|implementation)
      rm -f "$META_DIR/implementation-base" \
        "$META_DIR/implementation-head" \
        "$META_DIR/implementation-ok"
      ;;
  esac
  case "$START_FROM" in
    spec-review|plan|plan-review)
      rm -f "$META_DIR/forecast.json" \
        "$META_DIR/forecast.claude.json" \
        "$META_DIR/forecast.prompt"
      ;;
  esac
  status "OK" "restart from $START_FROM at $restart_boundary"
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
    if [ "$path" != "$allowed_path" ]; then
      clean_worktree_to "$CALL_START_HEAD"
      halt "$STAGE changed files outside allowed artifact"
    fi
  done < <(changed_paths)
}

assert_only_planner_path_changed() {
  local path
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    if [ "$path" != "$WT_PLAN_REL" ]; then
      clean_worktree_to "$CALL_START_HEAD"
      halt "planner changed unexpected files"
    fi
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
      clean_worktree_to "$CALL_START_HEAD"
      halt "review counts do not match findings ($last)"
    fi

    if [ -n "$allowed_path" ]; then
      assert_only_allowed_path_changed "$allowed_path"
    fi

    if [ "$((b + m))" -eq 0 ]; then
      if [ -n "$(git -C "$WORKTREE" status --porcelain)" ]; then
        clean_worktree_to "$CALL_START_HEAD"
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

if [ 1 -ge "$START_INDEX" ]; then
  review_loop spec-review "the file at $WT_SPEC_REL (a feature spec)" "$WT_SPEC_REL"
fi

if [ 2 -ge "$START_INDEX" ]; then
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
    if [ "$after_plan_head" != "$before_plan_head" ]; then
      clean_worktree_to "$CALL_START_HEAD"
      halt "planner committed changes (contract violation)"
    fi
    if [ ! -f "$WORKTREE/$WT_PLAN_REL" ]; then
      clean_worktree_to "$CALL_START_HEAD"
      halt "planner did not write plan"
    fi
    assert_only_planner_path_changed
    plan_summary="$(jq -r '.result // ""' "$META_DIR/plan.claude.json")"
    jq -n --arg p "$WT_PLAN_REL" --arg s "$plan_summary" \
      '{plan_path:$p, summary:$s}' > "$META_DIR/plan.json"
    plan_size="$(wc -c < "$WORKTREE/$WT_PLAN_REL" | tr -d ' ')"
    if [ "$plan_size" -gt "$SPEC2PR_MAX_PLAN" ]; then
      if [ "${IGNORE_PLAN_LIMIT:-}" = "1" ]; then
        status "OK" "size=$plan_size exceeds limit; overridden"
      else
        split plan "$plan_size" "$SPEC2PR_MAX_PLAN"
      fi
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
fi

if [ 3 -ge "$START_INDEX" ]; then
  review_loop plan-review "the file at $WT_PLAN_REL (an implementation plan for the spec at $WT_SPEC_REL)" "$WT_PLAN_REL"
fi

implementation_ok_record() {
  printf 'base=%s\nhead=%s\n' "$1" "$2"
}

forecast_decide() {
  local f="$1" est
  # Gate on the implementation estimate alone: the PR-review diff gate excludes
  # the committed spec + plan, so the forecast must too (est_bytes, the total
  # including those docs, is kept in the payload as informational only).
  est="$(jq -r '.implementation_est_bytes' "$f")"
  if [ "$est" -le "$SPEC2PR_MAX_DIFF" ]; then
    status "OK" "fits est=$est limit=$SPEC2PR_MAX_DIFF"
    return 0
  fi
  if [ "${IGNORE_PR_LIMIT:-}" = "1" ]; then
    status "OK" "est=$est exceeds limit; overridden"
    return 0
  fi
  jq -r '.summary // empty' "$f"
  split_forecast "$est" "$SPEC2PR_MAX_DIFF"
}

forecast_before_implement() {
  STAGE="forecast"
  local plan_sha spec_sha cur_bytes pf rc
  plan_sha="$(sha256_of "$WORKTREE/$WT_PLAN_REL")"
  spec_sha="$(sha256_of "$WORKTREE/$WT_SPEC_REL")"
  cur_bytes="$(git -C "$WORKTREE" diff "$BASE_SHA...HEAD" | wc -c | tr -d ' ')"

  # Resume/cache: reuse a forecast whose plan AND spec hashes still match the
  # current artifacts AND whose current_diff_bytes still matches the live diff;
  # otherwise discard and regenerate so a re-reviewed plan or changed PR surface
  # never decides on stale size data.
  if [ -f "$META_DIR/forecast.json" ] \
      && forecast_payload_valid "$META_DIR/forecast.json" "$plan_sha" "$spec_sha" "$cur_bytes"; then
    forecast_decide "$META_DIR/forecast.json"
    return 0
  fi
  rm -f "$META_DIR/forecast.json" "$META_DIR/forecast.claude.json"

  pf="$META_DIR/forecast.prompt"
  cat > "$pf" <<EOF
Read the implementation plan at $WT_PLAN_REL and the spec at $WT_SPEC_REL in
this worktree. This is a READ-ONLY estimation task: do not edit, create, or
delete any file; do not run git; do not commit, push, or open a PR.

Estimate the size of the final pull-request diff this plan will produce:
1. List every implementation file you would create or modify, with a rough
   added/changed lines-of-code (loc) count for each.
2. Sum the loc into total_loc.
3. Multiply total_loc by $SPEC2PR_FORECAST_BYTES_PER_LINE bytes/line to get
   implementation_est_bytes.
4. Add the already-present diff bytes ($cur_bytes) to implementation_est_bytes
   to get est_bytes (the estimated total PR diff, including the committed spec
   and plan). This total is informational only.
5. The PR-review diff gate measures the implementation alone; it excludes the
   committed spec and plan. Set verdict to "exceeds" if
   implementation_est_bytes > $SPEC2PR_MAX_DIFF, else "fits".
   When "exceeds", also include a non-empty "parts" array (sequential,
   independently implementable sub-plans) and a one-line "summary" recommending
   the split.

Return ONLY this JSON object as your result (no other prose):
{"plan_sha256":"$plan_sha","spec_sha256":"$spec_sha","current_diff_bytes":$cur_bytes,"files":[{"path":"...","loc":0}],"total_loc":0,"implementation_est_bytes":0,"est_bytes":0,"verdict":"fits"}
EOF

  set +e
  forecast_claude_attempt forecast "$pf" "$META_DIR/forecast.claude.json"
  rc=$?
  set -e
  case "$rc" in
    2) status "WARN" "claude failed; proceeding to implement"; return 0 ;;
    3) status "WARN" "invalid claude JSON; proceeding to implement"; return 0 ;;
    4) status "WARN" "claude modified worktree; proceeding to implement"; return 0 ;;
  esac

  if ! jq -e 'if (.result | type) == "object" then .result
              else (.result | tostring | fromjson?) end
              | select(type == "object")' \
      "$META_DIR/forecast.claude.json" > "$META_DIR/forecast.json" 2>/dev/null; then
    # Fallback: the model may wrap the JSON in prose or a ```json fence. Recover
    # the first balanced object the same way the pr-review classifier does
    # (scripts/lib/pr-review-engine.sh) before giving up.
    jq -r '.result // empty' "$META_DIR/forecast.claude.json" \
      | extract_json_object > "$META_DIR/forecast.json" 2>/dev/null || true
    if [ ! -s "$META_DIR/forecast.json" ]; then
      rm -f "$META_DIR/forecast.json"
      status "WARN" "malformed forecast JSON; proceeding to implement"
      return 0
    fi
  fi
  if ! forecast_payload_valid "$META_DIR/forecast.json" "$plan_sha" "$spec_sha" "$cur_bytes"; then
    rm -f "$META_DIR/forecast.json"
    status "WARN" "malformed forecast JSON; proceeding to implement"
    return 0
  fi

  forecast_decide "$META_DIR/forecast.json"
}

STAGE="implement"
if [ "$NO_PR" -eq 1 ]; then
  PR_URL=""
elif ! PR_URL="$(cd "$WORKTREE" && gh pr list --head "$BRANCH" --state open --json url --jq '.[0].url // empty')"; then
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
      if [ "$SPEC2PR_FORECAST" != "0" ]; then
        forecast_before_implement
        STAGE="implement"
      fi
      before_impl_head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
      if [ "$IMPLEMENTER_AGENT" = "claude" ]; then
        cpf="$META_DIR/implement.claude.prompt"
        cat > "$cpf" <<EOF
Use \$superpowers:subagent-driven-development to implement the plan at
$WT_PLAN_REL for the spec at $WT_SPEC_REL.

Make the necessary code, test, and documentation changes in this worktree.
Commit the implementation changes on the current branch. Do not create,
switch, or rename git branches. Do not push, do not create a PR.

Wait for every dispatched subagent to fully complete before continuing. Do
not report interim, partial, or "waiting for completion" status.
Do not invoke finishing-a-development-branch — spec2pr owns the branch and PR
lifecycle.
Your final message must be ONLY the JSON result object, nothing else. Use one
of these valid result shapes:
{"status":"done","summary":"...","blocked_reason":""}
{"status":"blocked","summary":"...","blocked_reason":"..."}
EOF
        CALL_START_HEAD="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
        run_claude_json implement "$cpf" "$META_DIR/implement.envelope.json" \
          "$IMPLEMENTER_MODEL" "$SPEC2PR_IMPLEMENT_TIMEOUT" implement
        jq -e '.result | select(type == "object")' \
          "$META_DIR/implement.envelope.json" > "$META_DIR/implement.json" 2>/dev/null \
          || true
        if ! implement_json_valid "$META_DIR/implement.json"; then
          clean_worktree_to "$CALL_START_HEAD"
          halt "claude implement returned invalid result"
        fi
      else
        pf="$META_DIR/implement.prompt"
        cat > "$pf" <<EOF
Use \$superpowers:subagent-driven-development to implement the plan at
$WT_PLAN_REL for the spec at $WT_SPEC_REL.

Make the necessary code, test, and documentation changes in this worktree.
Commit the implementation changes on the current branch. Do not create,
switch, or rename git branches. Do not push, do not create a PR.
Your final message must be exactly the JSON required by the output schema.
EOF
        codex_call implement implement "$pf"
      fi
      impl_status="$(jq -r '.status' "$META_DIR/implement.json")"
      case "$impl_status" in
        blocked)
          blocked_reason="$(jq -r '.blocked_reason' "$META_DIR/implement.json")"
          clean_worktree_to "$CALL_START_HEAD"
          halt "$blocked_reason"
          ;;
        done)
          if [ -n "$(git -C "$WORKTREE" status --porcelain --untracked-files=all)" ]; then
            clean_worktree_to "$CALL_START_HEAD"
            halt "uncommitted changes after done"
          fi
          after_impl_head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
          if [ "$after_impl_head" = "$before_impl_head" ]; then
            clean_worktree_to "$CALL_START_HEAD"
            halt "no implementation commit after done"
          fi
          # The implement agent (codex or claude) runs git inside the worktree
          # and may create or switch branches (codex's `git checkout -b
          # fix/<slug>` habit). That leaves HEAD carrying the implementation
          # while $BRANCH still points at the spec+plan commit. pr-create pushes
          # the *named* $BRANCH and pr-review diffs *HEAD*, so a divergence would
          # silently ship a code-free PR that still reviews clean. Reattach
          # $BRANCH to the real implementation HEAD so the pushed PR and the
          # reviewed diff are one commit. before/after_impl_head are SHAs, so
          # they stay correct.
          impl_branch="$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD || echo "")"
          if [ "$impl_branch" != "$BRANCH" ]; then
            status "WARN" "reattached $BRANCH; implementer left worktree on ${impl_branch:-detached HEAD}"
            git -C "$WORKTREE" checkout -q -B "$BRANCH" HEAD \
              || halt "could not reattach $BRANCH to implementation HEAD"
          fi
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

  if [ "$NO_PR" -ne 1 ]; then
    STAGE="pr-create"
    git -C "$WORKTREE" push -q -u origin "$BRANCH" || halt "git push failed"
    pr_head_sha="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
    pr_body="$(build_pr_body "$pr_head_sha")"
    if ! pr_create_out="$(cd "$WORKTREE" && gh pr create \
        --title "spec2pr: $SLUG" \
        --base "$BASE_BRANCH" \
        --body "$pr_body" \
        --head "$BRANCH")"; then
      halt "gh pr create failed"
    fi
    # Real `gh pr create` can print advisory lines to stdout alongside the URL;
    # extract just the PR URL so the DONE contract line stays machine-parseable.
    PR_URL="$(printf '%s\n' "$pr_create_out" | grep -Eo 'https://[^[:space:]]+' | tail -n1 || true)"
    [ -n "$PR_URL" ] || halt "gh pr create did not return URL"
    status "OK" "pr ok $PR_URL"
  fi
fi

# pr-review -> done: claude reviews the diff, codex fixes, loop until clean
# (DONE) or stuck (DIRTY). Engine lives in lib/pr-review-engine.sh.
if [ "$IMPLEMENTER_AGENT" = "claude" ]; then
  pr_review_engine_run codex      # codex reviews, claude fixes
else
  pr_review_engine_run            # default: claude reviews, codex fixes
fi
