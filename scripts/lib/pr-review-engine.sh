#!/usr/bin/env bash
# PR-review engine: fresh-eyes review -> opposite-model fix -> commit/push ->
# repeat, up to MAX_FIX_ROUNDS, then DONE (clean) or DIRTY (stuck). Default is
# claude reviews/classifies and codex fixes; callers may select codex reviewer.
#
# Sourced after spec2pr-runtime.sh. Reads these globals (set by the caller):
#   WORKTREE BASE_SHA BRANCH META_DIR PR_URL TMP_DIR STATUS_PATH
#   MAX_FIX_ROUNDS SPEC2PR_MAX_DIFF (+ runtime helpers)
# Optional, with behavior-preserving defaults:
#   WT_SPEC_REL / WT_PLAN_REL  — when both set, the review prompt names them
#   REVIEW_RUN_DESC            — prose descriptor of the run
#   COMMIT_PREFIX              — fix-commit subject prefix
#   DONE_COMMENT_HEADER        — first line of the PR summary comment
# Sets STAGE internally and ends by calling finish 0 (DONE) / dirty (cap) /
# halt / split. Does not return on a completed review.
pr_review_engine_fix_history_preamble() {
  if [ "$#" -ne 2 ]; then
    halt "usage: pr_review_engine_fix_history_preamble <round> <meta-dir>"
  fi
  local current_round="$1" meta_dir="$2"
  local prior_round review_file fix_file wrote_any=0

  if [ "$current_round" -le 1 ]; then
    return 0
  fi

  for prior_round in $(seq 1 "$((current_round - 1))"); do
    review_file="$meta_dir/pr-review-r$prior_round.review"
    fix_file="$meta_dir/pr-review-r$prior_round.fix"
    if [ ! -s "$review_file" ] || [ ! -s "$fix_file" ]; then
      continue
    fi
    if [ "$wrote_any" -eq 0 ]; then
      cat <<'EOF'
The earlier rounds below already attempted fixes on this PR. Shown oldest
first: what the reviewer flagged, and what was changed in response. Do not
undo a prior fix unless the current findings require it. If a finding keeps
recurring, try a different approach than the ones already attempted.

EOF
      wrote_any=1
    fi
    printf '=== Round %s ===\n' "$prior_round"
    printf 'Reviewer findings:\n'
    cat "$review_file"
    printf '\nFix attempt:\n'
    cat "$fix_file"
    printf '\n\n'
  done
}

# pr_review_engine_write_diff <out-file>
# Writes the BASE_SHA..HEAD review diff to <out-file>, excluding the committed
# spec and plan artifacts when spec2pr set them (review-pr.sh leaves both empty,
# so the diff is byte-for-byte unchanged there). The size gate and the reviewer
# prompt then see implementation-only bytes, not the spec/plan docs that ride
# along in the branch.
pr_review_engine_write_diff() {
  local out="$1"
  local -a args=("$BASE_SHA...HEAD")
  if [ -n "${WT_SPEC_REL:-}" ] && [ -n "${WT_PLAN_REL:-}" ]; then
    args+=(-- . ":(exclude)$WT_SPEC_REL" ":(exclude)$WT_PLAN_REL")
  fi
  git -C "$WORKTREE" diff "${args[@]}" > "$out"
}

pr_review_engine_run() {
  if [ "$#" -gt 1 ]; then
    halt "usage: pr_review_engine_run [claude|codex]"
  fi
  local pr_reviewer="claude"
  if [ "$#" -gt 0 ]; then
    pr_reviewer="$1"
  fi
  case "$pr_reviewer" in
    claude|codex) ;;
    *) halt "invalid pr reviewer: $pr_reviewer" ;;
  esac
  local pr_fixer="codex"
  if [ "$pr_reviewer" = "codex" ]; then
    pr_fixer="claude"
  fi
  local review_run_desc="${REVIEW_RUN_DESC:-an unattended spec2pr run}"
  local commit_prefix="${COMMIT_PREFIX:-spec2pr}"
  local done_comment_header="${DONE_COMMENT_HEADER:-spec2pr PR review complete.}"
  local push_refspec="${PUSH_REFSPEC:-$BRANCH}"
  local pr_done_approve="${PR_DONE_APPROVE:-}"   # review-pr sets =1; spec2pr never (self-approval is rejected)
  local pr_is_draft="${PR_IS_DRAFT:-}"           # "true" when the reviewed PR is a draft

  local spec_plan_line=""
  if [ -n "${WT_SPEC_REL:-}" ] && [ -n "${WT_PLAN_REL:-}" ]; then
    spec_plan_line=" The spec is $WT_SPEC_REL and the plan is $WT_PLAN_REL."
  fi

  STAGE="pr-review"
  local diff_file="$META_DIR/pr-review.diff"
  pr_review_engine_write_diff "$diff_file"
  local diff_size
  diff_size="$(wc -c < "$diff_file" | tr -d ' ')"
  if [ "$diff_size" -gt "$SPEC2PR_MAX_DIFF" ]; then
    split diff "$diff_size" "$SPEC2PR_MAX_DIFF"
  fi

  local round review_prompt review_json review_file review_blockers review_majors status_reviewer
  local classify_prompt classify_json classify_result classify_tmp
  local malformed attempt classify_rc b m fix_prompt fix_history_preamble after_model_head before_fix_head after_fix_head

  for round in $(seq 1 "$MAX_FIX_ROUNDS"); do
    if [ -n "$(git -C "$WORKTREE" status --porcelain --untracked-files=all)" ]; then
      halt "dirty worktree before pr-review round"
    fi

    review_prompt="$META_DIR/pr-review-r$round.prompt"
    review_file="$META_DIR/pr-review-r$round.review"
    if [ "$pr_reviewer" = "claude" ]; then
      review_json="$META_DIR/pr-review-r$round.claude.json"
      cat > "$review_prompt" <<EOF
You are a fresh-eyes PR reviewer for $review_run_desc.

Review only the implementation diff below, produced from immutable base
$BASE_SHA to HEAD.${spec_plan_line}
You may inspect files and run tests in this worktree, but do not edit files,
commit, push, or comment on GitHub. If the diff relies on a third-party library
or API whose current behavior you are unsure of, consult the context7 MCP for
up-to-date docs before forming a finding.

Return your review as prose in the JSON envelope's result field.

Diff:
$(cat "$diff_file")
EOF
      run_claude_json "pr-review-r$round" "$review_prompt" "$review_json"
      if ! jq -er '.result' "$review_json" > "$review_file"; then
        clean_worktree_to "$CALL_START_HEAD"
        halt "reviewer response missing result ($review_json)"
      fi
      after_model_head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
      if [ "$after_model_head" != "$CALL_START_HEAD" ] \
          || [ -n "$(git -C "$WORKTREE" status --porcelain --untracked-files=all)" ]; then
        clean_worktree_to "$CALL_START_HEAD"
        halt "reviewer modified worktree"
      fi

      classify_prompt="$META_DIR/pr-review-r$round.classify.prompt"
      classify_json="$META_DIR/pr-review-r$round.classify.json"
      classify_result="$META_DIR/pr-review-r$round.classify.result.json"
      classify_tmp="$META_DIR/pr-review-r$round.classify.tmp"
      malformed=0
      for attempt in 1 2; do
        cat > "$classify_prompt" <<EOF
Classify the review below. Return only JSON with integer keys
blockers_found and majors_found. Blockers are release-blocking correctness,
safety, data-loss, security, or contract failures. Majors are high or medium
severity regressions that should be fixed before human review.

Review:
$(cat "$review_file")
EOF
        set +e
        claude_json_attempt "pr-review-r$round.classify-a$attempt" "$classify_prompt" "$classify_json"
        classify_rc=$?
        set -e
        after_model_head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
        if [ "$after_model_head" != "$CALL_START_HEAD" ] \
            || [ -n "$(git -C "$WORKTREE" status --porcelain --untracked-files=all)" ]; then
          clean_worktree_to "$CALL_START_HEAD"
          halt "classifier modified worktree"
        fi
        if [ "$classify_rc" -eq 2 ]; then
          halt "claude pr-review-r$round.classify-a$attempt failed (stderr: $META_DIR/pr-review-r$round.classify-a$attempt.stderr)"
        fi
        if [ "$classify_rc" -ne 0 ]; then
          malformed=1
          continue
        fi
        if jq -e 'if (.result | type) == "object" then .result else (.result | tostring | fromjson?) end
          | select(type=="object")
          | {blockers_found, majors_found}
          | select((.blockers_found|type)=="number" and .blockers_found == (.blockers_found | floor) and .blockers_found >= 0)
          | select((.majors_found|type)=="number" and .majors_found == (.majors_found | floor) and .majors_found >= 0)' \
            "$classify_json" > "$classify_result" 2>/dev/null; then
          malformed=0
          break
        fi
        jq -r '.result // empty' "$classify_json" | extract_json_object > "$classify_tmp" 2>/dev/null || true
        if [ -s "$classify_tmp" ] && jq -e '{blockers_found, majors_found}
            | select((.blockers_found|type)=="number" and .blockers_found == (.blockers_found | floor) and .blockers_found >= 0)
            | select((.majors_found|type)=="number" and .majors_found == (.majors_found | floor) and .majors_found >= 0)' \
            "$classify_tmp" > "$classify_result" 2>/dev/null; then
          malformed=0
          break
        fi
        malformed=1
      done
      if [ "$malformed" -ne 0 ]; then
        halt "classifier returned malformed JSON"
      fi
      b="$(jq -r '.blockers_found' "$classify_result")"
      m="$(jq -r '.majors_found' "$classify_result")"
    else
      review_json="$META_DIR/pr-review-r$round.json"
      cat > "$review_prompt" <<EOF
You are a fresh-eyes PR reviewer for $review_run_desc.

Review only the implementation diff below, produced from immutable base
$BASE_SHA to HEAD.${spec_plan_line}
You may inspect files and run tests in this worktree, but do not edit files,
commit, push, or comment on GitHub. If the diff relies on a third-party library
or API whose current behavior you are unsure of, consult the context7 MCP for
up-to-date docs before forming a finding.

Return JSON matching the output schema.

Severity contract:
- Blockers are release-blocking correctness, safety, data-loss, security, or contract failures.
- Majors are high or medium severity regressions that should be fixed before human review.
- Minor, low, or nit issues belong in notes only and must not appear in findings or counts.

Diff:
$(cat "$diff_file")
EOF
      codex_call review "pr-review-r$round" "$review_prompt"
      after_model_head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
      if [ "$after_model_head" != "$CALL_START_HEAD" ] \
          || [ -n "$(git -C "$WORKTREE" status --porcelain --untracked-files=all)" ]; then
        clean_worktree_to "$CALL_START_HEAD"
        halt "reviewer modified worktree"
      fi
      b="$(jq -r '.blockers_found' "$review_json")"
      m="$(jq -r '.majors_found' "$review_json")"
      review_blockers="$(jq '[.findings[]? | select(.severity == "blocker")] | length' "$review_json")"
      review_majors="$(jq '[.findings[]? | select(.severity == "major")] | length' "$review_json")"
      if [ "$b" -ne "$review_blockers" ] || [ "$m" -ne "$review_majors" ]; then
        clean_worktree_to "$CALL_START_HEAD"
        halt "review counts do not match findings ($review_json)"
      fi
      jq -r '
        [
          (.findings[]? | "\(.severity | ascii_upcase): \(.summary)\nArtifact: \(.artifact)\nEvidence: \(.evidence)"),
          (.notes | select(. != ""))
        ] | join("\n\n")
      ' "$review_json" > "$review_file"
    fi
    if [ "$((b + m))" -eq 0 ]; then
      status_reviewer=""
      if [ "$pr_reviewer" != "claude" ]; then
        status_reviewer=" reviewer=$pr_reviewer"
      fi
      status "OK" "pr-review r$round${status_reviewer} blockers=0 majors=0 clean"
      show_review "$review_file"
      break
    fi

    status_reviewer=""
    if [ "$pr_reviewer" != "claude" ]; then
      status_reviewer=" reviewer=$pr_reviewer"
    fi
    status "OK" "pr-review r$round${status_reviewer} blockers=$b majors=$m"
    show_review "$review_file"
    fix_prompt="$META_DIR/pr-review-r$round.fix.prompt"
    fix_history_preamble="$(pr_review_engine_fix_history_preamble "$round" "$META_DIR")"
    if [ -n "$fix_history_preamble" ]; then
      fix_history_preamble="${fix_history_preamble}"$'\n\n'
    fi
    if [ "$pr_fixer" = "codex" ]; then
      cat > "$fix_prompt" <<EOF
${fix_history_preamble}Fix the blocker and major findings from this fresh-eyes PR review.

Review findings:
$(cat "$review_file")

Make the necessary code, test, and documentation changes in this worktree.
Do not push, do not create a PR. Your final message must be exactly the JSON
required by the output schema.
EOF
      before_fix_head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
      codex_call pr-fix "pr-review-r$round.fix" "$fix_prompt"
      after_fix_head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
      if [ "$after_fix_head" != "$before_fix_head" ]; then
        clean_worktree_to "$CALL_START_HEAD"
        halt "pr-review fixer committed changes (contract violation)"
      fi
      jq -r '.summary' "$META_DIR/pr-review-r$round.fix.json" > "$META_DIR/pr-review-r$round.fix"
    else
      cat > "$fix_prompt" <<EOF
${fix_history_preamble}Fix the blocker and major findings from this fresh-eyes PR review.

Review findings:
$(cat "$review_file")

Make the necessary code, test, and documentation changes in this worktree.
Do not push, do not create a PR.
EOF
      before_fix_head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
      run_claude_json "pr-review-r$round.fix" "$fix_prompt" "$META_DIR/pr-review-r$round.fix.json"
      after_fix_head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
      if [ "$after_fix_head" != "$before_fix_head" ]; then
        clean_worktree_to "$CALL_START_HEAD"
        halt "pr-review fixer committed changes (contract violation)"
      fi
      if ! jq -er '.result' "$META_DIR/pr-review-r$round.fix.json" > "$META_DIR/pr-review-r$round.fix"; then
        clean_worktree_to "$CALL_START_HEAD"
        halt "fixer response missing result ($META_DIR/pr-review-r$round.fix.json)"
      fi
    fi
    if [ -n "$(git -C "$WORKTREE" status --porcelain --untracked-files=all)" ]; then
      git -C "$WORKTREE" add -A
      git -C "$WORKTREE" commit -q -m "$commit_prefix: pr-review review fixes r$round"
      git -C "$WORKTREE" push -q origin "$push_refspec" || halt "git push failed"
      pr_review_engine_write_diff "$diff_file"
    fi

    if [ "$round" -eq "$MAX_FIX_ROUNDS" ]; then
      dirty pr-review "$b" "$m" "$review_file"
    fi
  done

  STAGE="done"
  git -C "$WORKTREE" push -q origin "$push_refspec" || halt "final git push failed"
  local comment_body="$META_DIR/pr-review-comment.md"
  {
    printf '%s\n\n' "$done_comment_header"
    grep ' pr-review r' "$STATUS_PATH" 2>/dev/null || true
    printf '\nLogs: %s\n' "$META_DIR"
  } > "$comment_body"
  if ! (cd "$WORKTREE" && gh pr comment "$PR_URL" --body-file "$comment_body") >/dev/null 2>"$META_DIR/pr-comment.stderr"; then
    status "OK" "pr comment failed $META_DIR/pr-comment.stderr"
  fi
  # Mark the PR reviewed (and ready, if a draft) when the caller opts in. Both
  # are non-fatal: a finished review must not fail on a GitHub-state hiccup, and
  # reviewing a self-authored PR (e.g. a spec2pr one) hits a self-approval 422.
  if [ -n "$pr_done_approve" ]; then
    if ! (cd "$WORKTREE" && gh pr review "$PR_URL" --approve --body "$done_comment_header") \
        >/dev/null 2>"$META_DIR/pr-approve.stderr"; then
      status "OK" "pr approve skipped $META_DIR/pr-approve.stderr"
    fi
    if [ "$pr_is_draft" = "true" ]; then
      if ! (cd "$WORKTREE" && gh pr ready "$PR_URL") \
          >/dev/null 2>"$META_DIR/pr-ready.stderr"; then
        status "OK" "pr ready skipped $META_DIR/pr-ready.stderr"
      fi
    fi
  fi
  finish 0 "DONE pr=$PR_URL worktree=$WORKTREE"
}
