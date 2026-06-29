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
