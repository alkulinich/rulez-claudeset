#!/usr/bin/env bash
set -euo pipefail

SPEC2PR_MAX_SPEC="${SPEC2PR_MAX_SPEC:-32768}"
SPEC2PR_MAX_PLAN="${SPEC2PR_MAX_PLAN:-65536}"
SPEC2PR_MAX_DIFF="${SPEC2PR_MAX_DIFF:-131072}"
SPEC2PR_CODEX_BIN="${SPEC2PR_CODEX_BIN:-codex}"
SPEC2PR_HOME="${SPEC2PR_HOME:-$HOME/.spec2pr}"
SPEC2PR_WORKTREES="${SPEC2PR_WORKTREES:-$HOME/.worktrees}"
MAX_FIX_ROUNDS="${MAX_FIX_ROUNDS:-3}"

STAGE="preflight"
FINISHED=0
LOCK_DIR=""
LOCK_PATH=""
TMP_DIR=""
STATUS_PATH=""

cleanup_own_paths() {
  if [ -n "$LOCK_DIR" ] && [ -n "$LOCK_PATH" ] && [ -f "$LOCK_PATH" ]; then
    if [ "$(cat "$LOCK_PATH" 2>/dev/null || true)" = "$$" ]; then
      rm -rf "$LOCK_DIR"
    fi
  fi
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}

status() {
  local line="SPEC2PR $1 $STAGE: $2"
  printf '%s\n' "$line"
  if [ -n "$STATUS_PATH" ]; then
    mkdir -p "$(dirname "$STATUS_PATH")"
    printf '%s\n' "$line" >> "$STATUS_PATH"
  fi
}

finish() { # <exit-code> <contract-words...>
  local rc="$1"
  shift
  local line="SPEC2PR $*"
  FINISHED=1
  printf '%s\n' "$line"
  if [ -n "$STATUS_PATH" ]; then
    mkdir -p "$(dirname "$STATUS_PATH")"
    printf '%s\n' "$line" >> "$STATUS_PATH"
  fi
  cleanup_own_paths
  exit "$rc"
}

halt() {
  finish 1 "HALT $STAGE: $*"
}

split() {
  finish 2 "SPLIT $1 size=$2 limit=$3"
}

dirty() {
  finish 3 "DIRTY $1 blockers=$2 majors=$3 log=$4"
}

on_exit() {
  local rc=$?
  if [ "$FINISHED" -ne 1 ]; then
    local line="SPEC2PR HALT $STAGE: unexpected exit (rc=$rc)"
    cleanup_own_paths
    printf '%s\n' "$line"
    if [ -n "$STATUS_PATH" ]; then
      mkdir -p "$(dirname "$STATUS_PATH")"
      printf '%s\n' "$line" >> "$STATUS_PATH"
    fi
    if [ "$rc" -eq 0 ]; then
      exit 1
    fi
    exit "$rc"
  fi
}
trap on_exit EXIT

sanitize() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  value="$(printf '%s' "$value" | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  printf '%s' "$value"
}

sha256_of() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    halt "missing dependency: shasum or sha256sum"
  fi
}

require_dependency() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    halt "missing dependency: $name"
  fi
}

require_codex() {
  if [[ "$SPEC2PR_CODEX_BIN" == */* ]]; then
    [ -x "$SPEC2PR_CODEX_BIN" ] || halt "missing dependency: $SPEC2PR_CODEX_BIN"
  else
    require_dependency "$SPEC2PR_CODEX_BIN"
  fi
}

[ "$#" -eq 1 ] || halt "usage: spec2pr.sh <spec-path>"

SPEC_INPUT="$1"
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

SPEC_SIZE="$(wc -c < "$SPEC_ABS" | tr -d ' ')"
if [ "$SPEC_SIZE" -gt "$SPEC2PR_MAX_SPEC" ]; then
  split spec "$SPEC_SIZE" "$SPEC2PR_MAX_SPEC"
fi

require_codex
require_dependency gh
require_dependency jq
require_dependency git

mkdir -p "$SPEC2PR_HOME" "$SPEC2PR_WORKTREES"
LOCK_TARGET="$SPEC2PR_HOME/$ID.lock"
if ! mkdir "$LOCK_TARGET" 2>/dev/null; then
  halt "locked by another spec2pr run"
fi
LOCK_DIR="$LOCK_TARGET"
LOCK_PATH="$LOCK_DIR/pid"
printf '%s\n' "$$" > "$LOCK_PATH"

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

# -- Schemas ---------------------------------------------------------------
TMP_DIR="$(mktemp -d -t spec2pr.XXXXXX)"

cat > "$TMP_DIR/review.json" <<'EOF'
{
  "type": "object",
  "properties": {
    "blockers_found": {"type": "integer"},
    "majors_found": {"type": "integer"},
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "severity": {"type": "string", "enum": ["blocker", "major"]},
          "artifact": {"type": "string"},
          "summary": {"type": "string"},
          "evidence": {"type": "string"}
        },
        "required": ["severity", "artifact", "summary", "evidence"],
        "additionalProperties": false
      }
    },
    "notes": {"type": "string"}
  },
  "required": ["blockers_found", "majors_found", "findings", "notes"],
  "additionalProperties": false
}
EOF

cat > "$TMP_DIR/plan.json" <<'EOF'
{
  "type": "object",
  "properties": {
    "plan_path": {"type": "string"},
    "summary": {"type": "string"}
  },
  "required": ["plan_path", "summary"],
  "additionalProperties": false
}
EOF

cat > "$TMP_DIR/implement.json" <<'EOF'
{
  "type": "object",
  "properties": {
    "status": {"type": "string", "enum": ["done", "blocked"]},
    "summary": {"type": "string"},
    "blocked_reason": {"type": "string"}
  },
  "required": ["status", "summary", "blocked_reason"],
  "additionalProperties": false
}
EOF

codex_call() {
  local role="$1" tag="$2" prompt_file="$3"
  local last="$META_DIR/$tag.json"
  local err="$META_DIR/$tag.stderr"

  if ! "$SPEC2PR_CODEX_BIN" exec --cd "$WORKTREE" \
      --output-schema "$TMP_DIR/$role.json" \
      --output-last-message "$last" \
      < "$prompt_file" > "$META_DIR/$tag.stdout" 2> "$err"; then
    halt "codex $tag failed (stderr: $err)"
  fi
  jq -e . "$last" > /dev/null 2>&1 || halt "codex $tag returned invalid JSON ($last)"
}

changed_paths() {
  git -C "$WORKTREE" status --porcelain --untracked-files=all \
    | awk '{print substr($0, 4)}'
}

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
    cat > "$pf" <<EOF
You are one fresh review round in an automated pipeline. No earlier review
context exists; judge only what you can see now.

Artifact under review: $artifact_desc

1. FIRST, before changing anything, list every blocker and major finding you
   can see right now. Severity mapping: critical->blocker, high->major,
   medium->major. Minor/low/nit observations go into "notes" only, never
   into findings.
2. THEN fix every blocker and major finding by editing files in this
   worktree. Do not push, do not commit, do not create branches or PRs.
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
      return 0
    fi

    status "OK" "$stage r$round blockers=$b majors=$m"
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
Write an implementation plan for the feature spec at $WT_SPEC_REL.

Create exactly one plan file at $WT_PLAN_REL. Do not edit any other files.
Your final message must be exactly the JSON required by the output schema.
EOF
  codex_call plan plan "$pf"
  plan_path="$(jq -r '.plan_path' "$META_DIR/plan.json")"
  [ "$plan_path" = "$WT_PLAN_REL" ] || halt "planner wrote unexpected path"
  [ -f "$WORKTREE/$WT_PLAN_REL" ] || halt "planner did not write plan"
  assert_only_planner_path_changed
  plan_size="$(wc -c < "$WORKTREE/$WT_PLAN_REL" | tr -d ' ')"
  if [ "$plan_size" -gt "$SPEC2PR_MAX_PLAN" ]; then
    split plan "$plan_size" "$SPEC2PR_MAX_PLAN"
  fi
  if [ -n "$(git -C "$WORKTREE" status --porcelain --untracked-files=all)" ]; then
    git -C "$WORKTREE" add "$WT_PLAN_REL"
    git -C "$WORKTREE" commit -q -m "spec2pr: write plan" || halt "git commit plan failed"
  fi
  status "OK" "plan ok $WT_PLAN_REL"
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
Implement the plan at $WT_PLAN_REL for the spec at $WT_SPEC_REL.

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
  if ! pr_create_out="$(cd "$WORKTREE" && gh pr create \
      --title "spec2pr: $SLUG" \
      --body "Automated by spec2pr. Spec: $WT_SPEC_REL -- Plan: $WT_PLAN_REL" \
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

STAGE="pr-review"
diff_size="$(git -C "$WORKTREE" diff "$BASE_SHA...HEAD" | wc -c | tr -d ' ')"
if [ "$diff_size" -gt "$SPEC2PR_MAX_DIFF" ]; then
  split diff "$diff_size" "$SPEC2PR_MAX_DIFF"
fi

review_loop pr-review "the full implementation diff: run \`git diff $BASE_SHA...HEAD\` in this worktree. It implements the plan at $WT_PLAN_REL for the spec at $WT_SPEC_REL. You may run the project's tests."

STAGE="done"
git -C "$WORKTREE" push -q origin "$BRANCH" || halt "final git push failed"
finish 0 "DONE pr=$PR_URL worktree=$WORKTREE"
