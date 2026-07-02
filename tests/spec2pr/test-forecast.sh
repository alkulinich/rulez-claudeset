#!/usr/bin/env bash
# Forecast step: runtime helpers (this task) + integration cases (Tasks 3-4).

# Source the runtime in a SUBSHELL only: it installs an EXIT trap and `finish`
# calls `exit`, which would abort the whole test runner otherwise.
run_split_forecast() {
  ( source "$REPO_ROOT/scripts/lib/spec2pr-runtime.sh"; STAGE=forecast; split_forecast "$1" "$2" ) 2>&1
}

payload_valid_rc() {  # <json-string> <plan-sha> <spec-sha> <current-diff-bytes>
  local f="$SANDBOX/payload.json"
  printf '%s' "$1" > "$f"
  (
    source "$REPO_ROOT/scripts/lib/spec2pr-runtime.sh"
    forecast_payload_valid "$f" "$2" "$3" "$4"
    local rc="$?"
    # spec2pr-runtime.sh installs an EXIT trap that treats a normal return from
    # a sourced script as an unexpected pipeline exit. Mark the subshell as
    # finished so this unit helper can preserve forecast_payload_valid's rc.
    FINISHED=1
    exit "$rc"
  )
  printf '%s' "$?"
}

run_forecast_claude_failure_capture() {
  mkdir -p "$SANDBOX/meta"
  printf 'forecast prompt\n' > "$SANDBOX/prompt.txt"
  (
    source "$REPO_ROOT/scripts/lib/spec2pr-runtime.sh"
    WORKTREE="$PROJECT"
    META_DIR="$SANDBOX/meta"
    ID="forecast-test"
    set +e
    forecast_claude_attempt "forecast" "$SANDBOX/prompt.txt" "$SANDBOX/forecast-envelope.json"
    local rc="$?"
    case "$-" in
      *e*) local errexit_state="on" ;;
      *) local errexit_state="off" ;;
    esac
    FINISHED=1
    printf 'rc=%s errexit=%s\n' "$rc" "$errexit_state"
  ) 2>&1
}

test_split_forecast_emits_forecast_token() {
  make_sandbox
  local out rc
  out="$(run_split_forecast 150000 131072)"; rc=$?
  assert_eq "2" "$rc" "split_forecast exits 2"
  assert_eq "SPEC2PR SPLIT forecast est=150000 limit=131072" "$out" \
    "split_forecast prints the forecast split token"
  rm -rf "$SANDBOX"
}

test_forecast_claude_attempt_failure_is_fail_soft() {
  make_sandbox
  enqueue_claude 01-forecast-fail <<'EOF'
exit 42
EOF

  local out rc
  out="$(run_forecast_claude_failure_capture)"; rc=$?
  assert_eq "0" "$rc" "forecast_claude_attempt failure can be captured"
  assert_contains "$out" "rc=2" "forecast_claude_attempt reports process failure"
  assert_contains "$out" "errexit=off" "forecast_claude_attempt preserves disabled errexit"
  rm -rf "$SANDBOX"
}

test_forecast_payload_valid_accepts_good_fits() {
  make_sandbox
  local json
  json='{"plan_sha256":"aa","spec_sha256":"bb","current_diff_bytes":1000,"files":[{"path":"x.ts","loc":10}],"total_loc":10,"implementation_est_bytes":400,"est_bytes":1400,"verdict":"fits"}'
  assert_eq "0" "$(payload_valid_rc "$json" aa bb 1000)" "valid fits payload accepted"
  rm -rf "$SANDBOX"
}

test_forecast_payload_valid_requires_parts_on_exceeds() {
  make_sandbox
  local json
  json='{"plan_sha256":"aa","spec_sha256":"bb","current_diff_bytes":110000,"files":[{"path":"x.ts","loc":1000}],"total_loc":1000,"implementation_est_bytes":40000,"est_bytes":150000,"verdict":"exceeds"}'
  assert_eq "1" "$(payload_valid_rc "$json" aa bb 110000)" "exceeds payload without parts/summary rejected"
  json='{"plan_sha256":"aa","spec_sha256":"bb","current_diff_bytes":110000,"files":[{"path":"x.ts","loc":1000}],"total_loc":1000,"implementation_est_bytes":40000,"est_bytes":150000,"verdict":"exceeds","summary":"split it","parts":["part-1","part-2"]}'
  assert_eq "0" "$(payload_valid_rc "$json" aa bb 110000)" "exceeds payload with parts/summary accepted"
  rm -rf "$SANDBOX"
}

test_forecast_payload_valid_rejects_hash_mismatch() {
  make_sandbox
  local json
  json='{"plan_sha256":"WRONG","spec_sha256":"bb","current_diff_bytes":1000,"files":[{"path":"x.ts","loc":10}],"total_loc":10,"implementation_est_bytes":400,"est_bytes":1400,"verdict":"fits"}'
  assert_eq "1" "$(payload_valid_rc "$json" aa bb 1000)" "plan hash mismatch rejected"
  rm -rf "$SANDBOX"
}

test_forecast_payload_valid_rejects_est_inconsistency() {
  make_sandbox
  local json
  json='{"plan_sha256":"aa","spec_sha256":"bb","current_diff_bytes":1000,"files":[{"path":"x.ts","loc":10}],"total_loc":10,"implementation_est_bytes":400,"est_bytes":9999,"verdict":"fits"}'
  assert_eq "1" "$(payload_valid_rc "$json" aa bb 1000)" "est_bytes != current + impl rejected"
  json='{"plan_sha256":"aa","spec_sha256":"bb","current_diff_bytes":999,"files":[{"path":"x.ts","loc":10}],"total_loc":10,"implementation_est_bytes":400,"est_bytes":1399,"verdict":"fits"}'
  assert_eq "1" "$(payload_valid_rc "$json" aa bb 1000)" "current_diff_bytes mismatch rejected"
  json='{"plan_sha256":"aa","spec_sha256":"bb","current_diff_bytes":1000,"files":[{"path":"x.ts","loc":10}],"total_loc":11,"implementation_est_bytes":440,"est_bytes":1440,"verdict":"fits"}'
  assert_eq "1" "$(payload_valid_rc "$json" aa bb 1000)" "total_loc must equal file loc sum"
  json='{"plan_sha256":"aa","spec_sha256":"bb","current_diff_bytes":1000,"files":[{"path":"x.ts","loc":10}],"total_loc":10,"implementation_est_bytes":401,"est_bytes":1401,"verdict":"fits"}'
  assert_eq "1" "$(payload_valid_rc "$json" aa bb 1000)" "implementation bytes must use bytes-per-line constant"
  rm -rf "$SANDBOX"
}

test_forecast_fits_proceeds_to_implement() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  queue_spec2pr_subject_implementation_commit 05-implement
  queue_clean_pr_review 06-pr-review
  run_spec2pr "$SPEC"

  assert_eq "0" "$RC" "forecast fits run reaches done"
  assert_contains "$OUT" "SPEC2PR OK forecast: fits est=" "fits status printed"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1" "fits run reaches done"
  assert_file_exists "$SPEC2PR_HOME/$ID/forecast.json" "forecast payload extracted"
  assert_file_exists "$SPEC2PR_HOME/$ID/forecast.claude.json" "raw claude envelope stored"
}

test_forecast_exceeds_splits_without_implement() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_exceeds_forecast 04-forecast
  # Implement fixture intentionally present but must NOT be consumed.
  queue_spec2pr_subject_implementation_commit 05-implement
  run_spec2pr "$SPEC"

  assert_eq "2" "$RC" "forecast exceeds exits 2 (split)"
  assert_contains "$OUT" "SPEC2PR SPLIT forecast est=" "forecast split token printed"
  assert_contains "$OUT" "limit=131072" "forecast split limit printed"
  assert_contains "$OUT" "Recommended split: part-1 helpers" "recommended split summary printed before split"
  assert_eq "2" "$(codex_calls)" "no implement codex call spent (only spec-review + plan-review)"
}

test_forecast_exceeds_overridden_by_ignore_pr_limit() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_exceeds_forecast 04-forecast
  queue_spec2pr_subject_implementation_commit 05-implement
  queue_clean_pr_review 06-pr-review
  run_spec2pr --ignore-pr-limit "$SPEC"

  assert_eq "0" "$RC" "ignore-pr-limit overrides forecast split"
  assert_contains "$OUT" "SPEC2PR OK forecast: est=" "override status printed"
  assert_contains "$OUT" "exceeds limit; overridden" "override suffix printed"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1" "override run reaches done"
}

test_forecast_claude_failure_warns_and_proceeds() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  enqueue_claude 04-forecast <<'EOF'
echo "boom" >&2
exit 7
EOF
  queue_spec2pr_subject_implementation_commit 05-implement
  queue_clean_pr_review 06-pr-review
  run_spec2pr "$SPEC"

  assert_eq "0" "$RC" "forecast claude failure does not block the run"
  assert_contains "$OUT" "SPEC2PR WARN forecast: claude failed; proceeding to implement" "process-failure warn"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1" "fail-soft run reaches done"
}

test_forecast_malformed_payload_warns_and_proceeds() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  enqueue_claude 04-forecast <<'EOF'
jq -n --arg result "Malformed forecast payload." \
  '{result:$result, structured_output:{verdict:"maybe"}}'
EOF
  queue_spec2pr_subject_implementation_commit 05-implement
  queue_clean_pr_review 06-pr-review
  run_spec2pr "$SPEC"

  assert_eq "0" "$RC" "malformed forecast payload does not block the run"
  assert_contains "$OUT" "SPEC2PR WARN forecast: malformed forecast JSON; proceeding to implement" "malformed warn"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1" "malformed fail-soft reaches done"
}

test_forecast_missing_structured_output_warns_and_proceeds() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  # Schema-bound forecast requires structured_output; prose/fenced JSON in
  # result is no longer recovered.
  enqueue_claude 04-forecast <<'EOF'
plan_sha="$(sha256sum docs/superpowers/plans/toy-spec-plan.md | awk '{print $1}')"
spec_sha="$(sha256sum docs/superpowers/specs/toy-spec.md | awk '{print $1}')"
base_sha="$(git merge-base origin/main HEAD)"
cur_bytes="$(git diff "$base_sha...HEAD" | wc -c | tr -d ' ')"
est=$((cur_bytes + 40))
payload=$(printf '{"plan_sha256":"%s","spec_sha256":"%s","current_diff_bytes":%s,"files":[{"path":"version.txt","loc":1}],"total_loc":1,"implementation_est_bytes":40,"est_bytes":%s,"verdict":"fits"}' "$plan_sha" "$spec_sha" "$cur_bytes" "$est")
prose=$(printf 'Here are my per-file estimates.\n\n```json\n%s\n```' "$payload")
jq -n --arg r "$prose" '{result: $r}'
EOF
  queue_spec2pr_subject_implementation_commit 05-implement
  queue_clean_pr_review 06-pr-review
  run_spec2pr "$SPEC"

  assert_eq "0" "$RC" "missing structured forecast output does not block the run"
  assert_contains "$OUT" "SPEC2PR WARN forecast: invalid claude JSON; proceeding to implement" \
    "missing structured output warns as invalid claude JSON"
  assert_file_absent "$SPEC2PR_HOME/$ID/forecast.json" "missing structured output writes no forecast payload"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1" \
    "missing structured output still reaches done"
}

test_forecast_string_structured_output_is_not_recovered() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  enqueue_claude 04-forecast <<'EOF'
plan_sha="$(sha256sum docs/superpowers/plans/toy-spec-plan.md | awk '{print $1}')"
spec_sha="$(sha256sum docs/superpowers/specs/toy-spec.md | awk '{print $1}')"
base_sha="$(git merge-base origin/main HEAD)"
cur_bytes="$(git diff "$base_sha...HEAD" | wc -c | tr -d ' ')"
est=$((cur_bytes + 40))
payload=$(printf '{"plan_sha256":"%s","spec_sha256":"%s","current_diff_bytes":%s,"files":[{"path":"version.txt","loc":1}],"total_loc":1,"implementation_est_bytes":40,"est_bytes":%s,"verdict":"fits"}' "$plan_sha" "$spec_sha" "$cur_bytes" "$est")
prose=$(printf 'Here are my per-file estimates.\n\n```json\n%s\n```' "$payload")
jq -n --arg result "Forecast returned as structured prose." --arg structured "$prose" \
  '{result:$result, structured_output:$structured}'
EOF
  queue_spec2pr_subject_implementation_commit 05-implement
  queue_clean_pr_review 06-pr-review
  run_spec2pr "$SPEC"

  assert_eq "0" "$RC" "string structured forecast output does not block the run"
  assert_contains "$OUT" "SPEC2PR WARN forecast: malformed forecast JSON; proceeding to implement" \
    "string structured output warns as malformed forecast JSON"
  assert_file_absent "$SPEC2PR_HOME/$ID/forecast.json" "string structured output writes no forecast payload"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1" \
    "string structured output still reaches done"
}

test_forecast_worktree_modification_is_cleaned_and_warns() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  enqueue_claude 04-forecast <<'EOF'
printf 'sneaky\n' > sneaky.txt
git add sneaky.txt
git commit -qm "forecast should not commit"
plan_sha="$(sha256sum docs/superpowers/plans/toy-spec-plan.md | awk '{print $1}')"
spec_sha="$(sha256sum docs/superpowers/specs/toy-spec.md | awk '{print $1}')"
base_sha="$(git merge-base origin/main HEAD)"
cur_bytes="$(git diff "$base_sha...HEAD" | wc -c | tr -d ' ')"
est=$((cur_bytes + 40))
jq -n \
  --arg result "Forecast after modifying worktree." \
  --arg plan_sha "$plan_sha" \
  --arg spec_sha "$spec_sha" \
  --argjson cur_bytes "$cur_bytes" \
  --argjson est "$est" \
  '{result:$result, structured_output:{plan_sha256:$plan_sha, spec_sha256:$spec_sha, current_diff_bytes:$cur_bytes, files:[{path:"version.txt", loc:1}], total_loc:1, implementation_est_bytes:40, est_bytes:$est, verdict:"fits"}}'
EOF
  queue_spec2pr_subject_implementation_commit 05-implement
  queue_clean_pr_review 06-pr-review
  run_spec2pr "$SPEC"

  local wt="$SPEC2PR_WORKTREES/$ID"
  assert_eq "0" "$RC" "worktree-modifying forecast does not block the run"
  assert_contains "$OUT" "SPEC2PR WARN forecast: claude modified worktree; proceeding to implement" "worktree-modified warn"
  assert_not_contains "$(git -C "$wt" log --format=%s)" "forecast should not commit" "forecast commit was discarded"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1" "cleaned fail-soft reaches done"
}

test_forecast_kill_switch_skips_step() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  # No forecast fixture queued: the step must not call claude at all.
  queue_spec2pr_subject_implementation_commit 04-implement
  queue_clean_pr_review 05-pr-review
  SPEC2PR_FORECAST=0 run_spec2pr "$SPEC"

  assert_eq "0" "$RC" "kill-switch run reaches done"
  assert_not_contains "$OUT" "forecast" "no forecast status lines emitted"
  assert_file_absent "$SPEC2PR_HOME/$ID/forecast.json" "no forecast payload written"
}

test_forecast_cache_reused_when_hashes_match() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  queue_blocked_implementation 05-implement
  run_spec2pr "$SPEC"

  assert_eq "1" "$RC" "seed run stops at blocked implementation"
  assert_file_exists "$SPEC2PR_HOME/$ID/forecast.json" "seed run writes forecast payload"
  local before_claude
  before_claude="$(claude_calls)"

  queue_clean_spec_review 06-spec-review
  queue_clean_plan_review 07-plan-review
  queue_spec2pr_subject_implementation_commit 08-implement
  queue_clean_pr_review 09-pr-review
  run_spec2pr "$SPEC"

  assert_eq "0" "$RC" "resume with cached forecast reaches done"
  assert_contains "$OUT" "SPEC2PR OK forecast: fits est=" "cached forecast still reports fits"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1" "cached forecast resume reaches done"
  assert_eq "$((before_claude + 2))" "$(claude_calls)" "second run adds only the pr-review claude calls"
}

test_forecast_stale_hash_regenerates() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  queue_blocked_implementation 05-implement
  run_spec2pr "$SPEC"

  local forecast_path="$SPEC2PR_HOME/$ID/forecast.json"
  local forecast_tmp="$SANDBOX/forecast.tmp"
  jq '.plan_sha256 = "WRONG"' "$forecast_path" > "$forecast_tmp"
  mv "$forecast_tmp" "$forecast_path"

  queue_clean_spec_review 06-spec-review
  queue_clean_plan_review 07-plan-review
  queue_clean_forecast 08-forecast
  queue_spec2pr_subject_implementation_commit 09-implement
  queue_clean_pr_review 10-pr-review
  run_spec2pr "$SPEC"

  local wt="$SPEC2PR_WORKTREES/$ID"
  local live_plan_sha
  live_plan_sha="$(sha256sum "$wt/docs/superpowers/plans/toy-spec-plan.md" | awk '{print $1}')"
  assert_eq "0" "$RC" "stale plan hash triggers regeneration and reaches done"
  assert_eq "$live_plan_sha" "$(jq -r '.plan_sha256' "$forecast_path")" "regenerated payload uses live plan hash"
}

test_forecast_stale_spec_hash_regenerates() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  queue_blocked_implementation 05-implement
  run_spec2pr "$SPEC"

  local forecast_path="$SPEC2PR_HOME/$ID/forecast.json"
  local forecast_tmp="$SANDBOX/forecast.tmp"
  jq '.spec_sha256 = "WRONG"' "$forecast_path" > "$forecast_tmp"
  mv "$forecast_tmp" "$forecast_path"

  queue_clean_spec_review 06-spec-review
  queue_clean_plan_review 07-plan-review
  queue_clean_forecast 08-forecast
  queue_spec2pr_subject_implementation_commit 09-implement
  queue_clean_pr_review 10-pr-review
  run_spec2pr "$SPEC"

  local wt="$SPEC2PR_WORKTREES/$ID"
  local live_spec_sha
  live_spec_sha="$(sha256sum "$wt/docs/superpowers/specs/toy-spec.md" | awk '{print $1}')"
  assert_eq "0" "$RC" "stale spec hash triggers regeneration and reaches done"
  assert_eq "$live_spec_sha" "$(jq -r '.spec_sha256' "$forecast_path")" "regenerated payload uses live spec hash"
}

test_forecast_stale_current_diff_regenerates() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  queue_blocked_implementation 05-implement
  run_spec2pr "$SPEC"

  local forecast_path="$SPEC2PR_HOME/$ID/forecast.json"
  local forecast_tmp="$SANDBOX/forecast.tmp"
  jq '.current_diff_bytes = 999999' "$forecast_path" > "$forecast_tmp"
  mv "$forecast_tmp" "$forecast_path"

  queue_clean_spec_review 06-spec-review
  queue_clean_plan_review 07-plan-review
  queue_clean_forecast 08-forecast
  queue_spec2pr_subject_implementation_commit 09-implement
  queue_clean_pr_review 10-pr-review
  run_spec2pr "$SPEC"

  assert_eq "0" "$RC" "stale current diff triggers regeneration and reaches done"
  assert_not_contains "$(cat "$forecast_path")" "999999" "regenerated payload replaces stale current_diff_bytes"
}

test_forecast_regenerated_mismatch_warns_and_proceeds() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  queue_blocked_implementation 05-implement
  run_spec2pr "$SPEC"

  local forecast_path="$SPEC2PR_HOME/$ID/forecast.json"
  local forecast_tmp="$SANDBOX/forecast.tmp"
  jq '.plan_sha256 = "WRONG"' "$forecast_path" > "$forecast_tmp"
  mv "$forecast_tmp" "$forecast_path"

  queue_clean_spec_review 06-spec-review
  queue_clean_plan_review 07-plan-review
  enqueue_claude 08-forecast <<'EOF'
jq -n --arg result "Mismatched forecast payload." \
  '{result:$result, structured_output:{plan_sha256:"WRONG", spec_sha256:"WRONG", current_diff_bytes:999999, files:[{path:"version.txt", loc:1}], total_loc:1, implementation_est_bytes:40, est_bytes:1000039, verdict:"fits"}}'
EOF
  queue_spec2pr_subject_implementation_commit 09-implement
  queue_clean_pr_review 10-pr-review
  run_spec2pr "$SPEC"

  assert_eq "0" "$RC" "mismatched regenerated forecast does not block the run"
  assert_contains "$OUT" "SPEC2PR WARN forecast: malformed forecast JSON; proceeding to implement" "hash/current-diff mismatch warns"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1" "mismatch warning still reaches done"
  assert_file_absent "$forecast_path" "invalid regenerated payload removed"
}

test_forecast_start_from_plan_review_clears_forecast_artifacts() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  queue_blocked_implementation 05-implement
  run_spec2pr "$SPEC"

  local forecast_dir="$SPEC2PR_HOME/$ID"
  assert_file_exists "$forecast_dir/forecast.json" "seed run keeps forecast payload"
  assert_file_exists "$forecast_dir/forecast.claude.json" "seed run keeps raw forecast envelope"
  assert_file_exists "$forecast_dir/forecast.prompt" "seed run keeps forecast prompt"

  queue_clean_plan_review 06-plan-review
  queue_blocked_implementation 07-implement
  SPEC2PR_FORECAST=0 run_spec2pr --start-from plan-review "$SPEC"

  assert_eq "1" "$RC" "plan-review rewind can continue without forecast and stop at blocked implementation"
  assert_file_absent "$forecast_dir/forecast.json" "plan-review rewind clears forecast payload"
  assert_file_absent "$forecast_dir/forecast.claude.json" "plan-review rewind clears raw forecast envelope"
  assert_file_absent "$forecast_dir/forecast.prompt" "plan-review rewind clears forecast prompt"
}
