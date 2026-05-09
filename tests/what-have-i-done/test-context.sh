#!/usr/bin/env bash

test_context_default_is_three_days() {
  local out
  out=$(bash "$SCRIPTS_DIR/what-have-i-done-context.sh")

  # All required keys present.
  assert_contains "TODAY=" "$out" "context emits TODAY"
  assert_contains "YESTERDAY=" "$out" "context emits YESTERDAY"
  assert_contains "START_DATE=" "$out" "context emits START_DATE"
  assert_contains "START_ISO=" "$out" "context emits START_ISO"
  assert_contains "END_ISO=" "$out" "context emits END_ISO"
  assert_contains "DATES_LIST=" "$out" "context emits DATES_LIST"

  # DATES_LIST has three comma-separated values for default N=3.
  local dates
  dates=$(printf '%s' "$out" | grep '^DATES_LIST=' | sed 's/^DATES_LIST=//')
  local count
  count=$(printf '%s' "$dates" | awk -F, '{print NF}')
  assert_eq "3" "$count" "default N=3 → 3 dates in DATES_LIST"
}

test_context_respects_n_argument() {
  local out
  out=$(bash "$SCRIPTS_DIR/what-have-i-done-context.sh" 7)
  local dates
  dates=$(printf '%s' "$out" | grep '^DATES_LIST=' | sed 's/^DATES_LIST=//')
  local count
  count=$(printf '%s' "$dates" | awk -F, '{print NF}')
  assert_eq "7" "$count" "N=7 → 7 dates in DATES_LIST"
}

test_context_dates_oldest_to_newest() {
  local out
  out=$(bash "$SCRIPTS_DIR/what-have-i-done-context.sh" 3)
  local dates today first last
  dates=$(printf '%s' "$out" | grep '^DATES_LIST=' | sed 's/^DATES_LIST=//')
  today=$(printf '%s' "$out" | grep '^TODAY=' | sed 's/^TODAY=//')
  first=$(printf '%s' "$dates" | cut -d, -f1)
  last=$(printf '%s' "$dates" | rev | cut -d, -f1 | rev)

  assert_eq "$today" "$last" "DATES_LIST ends on TODAY (newest last)"
  # First date should be today minus 2 days.
  local expected_first
  expected_first=$(date -j -f %Y-%m-%d -v-2d "$today" +%Y-%m-%d)
  assert_eq "$expected_first" "$first" "DATES_LIST starts on today-2 (oldest first)"
}

test_context_rejects_garbage_n() {
  # Non-numeric N should fall back to default of 3.
  local out
  out=$(bash "$SCRIPTS_DIR/what-have-i-done-context.sh" abc)
  local dates count
  dates=$(printf '%s' "$out" | grep '^DATES_LIST=' | sed 's/^DATES_LIST=//')
  count=$(printf '%s' "$dates" | awk -F, '{print NF}')
  assert_eq "3" "$count" "non-numeric N falls back to 3"
}
