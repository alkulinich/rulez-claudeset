#!/usr/bin/env bash
# Static contract tests for the lightweight Claude forecast command.

test_standalone_forecast_command_contract() {
  local command="$REPO_ROOT/commands/rulez/spec2pr-forecast.md"

  assert_file_exists "$command" "standalone forecast command exists"
  [ -f "$command" ] || return

  local content; content="$(<"$command")"
  assert_contains "$content" "/rulez:spec2pr-forecast <path>" "documents the public invocation"
  assert_contains "$content" "native Claude Agent tool exactly once" "requires one native Agent call"
  assert_contains "$content" "Read <path> and relevant context in <repository-root>." "uses the shared forecast prompt"
  assert_contains "$content" "If the supplied artifact has an obvious conventional companion spec or plan, read that too." "reads an obvious companion"
  assert_contains "$content" "This is a read-only forecast: do not run spec2pr or spec2pr-split, implement any work, create split specs, commit, or push." "forbids forecast-side implementation and publishing"
  assert_contains "$content" "do not run spec2pr or spec2pr-split" "forbids running spec2pr commands inside the prompt"
  assert_contains "$content" "implement any work" "forbids implementing work inside the prompt"
  assert_contains "$content" "create split specs" "forbids creating split specs inside the prompt"
  assert_contains "$content" "commit, or push" "forbids committing or pushing inside the prompt"
  assert_contains "$content" "Do not modify anything and do not launch another agent." "enforces read-only single-agent work"
  assert_contains "$content" "larger than 131072 bytes" "includes the forecast threshold"
  assert_contains "$content" "Risk: LOW, MEDIUM, or HIGH" "includes the risk contract"
  assert_contains "$content" "Expected size: a rough changed-LOC range" "includes the expected size heading"
  assert_contains "$content" "Reasons:" "includes the reasons heading"
  assert_contains "$content" "Suggested split:" "includes the conditional split heading"
  assert_contains "$content" "For MEDIUM or HIGH, also return:" "makes split advice conditional"
  assert_contains "$content" "For LOW, omit Suggested split." "omits split advice for low risk"
  assert_contains "$content" "missing, unreadable, or extra input" "rejects invalid input before dispatch"
  assert_contains "$content" "current working directory" "uses the current directory as repository context"
  assert_contains "$content" "not in a Git repository" "stops outside a Git repository"
  assert_contains "$content" "Do not launch external claude, external codex, spec2pr, or spec2pr-split" "forbids external dispatch"
  assert_contains "$content" "forecast failed" "reports native subagent failure"
  assert_contains "$content" "malformed" "reports malformed responses"
  assert_contains "$content" "Return the Agent result directly" "returns the native result"

  assert_not_contains "$content" "helper script" "does not add helper-script machinery"
  assert_not_contains "$content" "JSON schema" "does not add a JSON schema"
  assert_not_contains "$content" "cache" "does not add caching"
  assert_not_contains "$content" "state manifest" "does not add a state manifest"
  assert_not_contains "$content" "exact byte arithmetic" "does not add deterministic byte arithmetic"
  assert_not_contains "$content" "SPEC2PR OK" "does not add a status token"
  assert_not_contains "$content" "SPEC2PR WARN" "does not add a status token"
  assert_not_contains "$content" "SPEC2PR SPLIT" "does not add a status token"
  assert_not_contains "$content" "SPEC2PR HALT" "does not add a status token"
}
