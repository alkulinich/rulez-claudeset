# Standalone spec2pr Forecast Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Codex and Claude Rulez commands that forecast spec2pr implementation size through one native current-tool subagent before the operator starts the pipeline.

**Architecture:** A shared Bash helper implements a two-phase `prepare`/`evaluate` protocol. `prepare` discovers artifact context, snapshots read-only state, and builds a self-contained prompt; the active Codex or Claude adapter launches one native subagent; `evaluate` validates the response and unchanged state, performs deterministic arithmetic, and emits the existing spec2pr forecast contract.

**Tech Stack:** Bash 3.2-compatible shell, Git, `jq`, SHA-256 via `shasum`/`sha256sum`, Claude command Markdown, Codex skill Markdown, existing shell test harnesses.

## Global Constraints

- Implement from the approved design commit `74ac94d` in an isolated worktree created with `~/.claude/skills/rulez-claudeset/scripts/git-worktree-add.sh feature/spec2pr-standalone-forecast main`.
- Preserve unrelated untracked files in the primary worktree. Do not stage or commit them.
- Public Codex syntax is exactly `use rulez-tools to forecast <path>`.
- Public Claude syntax is exactly `/rulez:spec2pr-forecast <path>`.
- Accept exactly one readable primary file. Discover at most one conventional companion, but never require it.
- Launch exactly one native current-tool subagent. Do not launch external `claude` or `codex` processes.
- Do not cache results, invoke `spec2pr`, invoke `spec2pr-split`, or edit the target repository.
- Use `SPEC2PR_FORECAST_BYTES_PER_LINE` with default `40` and `SPEC2PR_MAX_DIFF` with default `131072`.
- Risk classes are fixed: below 80% is `OK`; 80% through 100% is `WARN` with exit 0; above 100% is `SPLIT` with exit 2.
- `SPEC2PR SPLIT forecast est=<n> limit=<n>` must be the final line on a split.
- Any invalid input, invalid result, agent failure, or changed state emits `SPEC2PR HALT forecast: <reason>` and exits 1.
- Never revert target-repository changes detected after dispatch.
- Keep the existing forecast implementation in `scripts/spec2pr.sh`, `scripts/lib/spec2pr-runtime.sh`, and `tests/spec2pr/test-forecast.sh` unchanged.
- Do not modify `VERSION` or `UPGRADE.md`.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `scripts/spec2pr-forecast.sh` | Shared `prepare`/`evaluate` protocol, prompt, state snapshot, validation, arithmetic, report, and exit codes |
| `tests/spec2pr/test-standalone-forecast.sh` | Executable protocol tests plus Claude command/settings contract tests |
| `commands/rulez/spec2pr-forecast.md` | Claude `/rulez:spec2pr-forecast` orchestration through one Agent |
| `adapters/codex/skills/rulez-tools/SKILL.md` | Codex `rulez-tools forecast` mapping and one-subagent workflow |
| `tests/codex/test-setup-codex.sh` | Codex forecast skill and README contract assertions |
| `settings.json` | Claude permission entries for the shared helper and owned temp-directory lifecycle |
| `README.md` | User-facing examples, behavior, risk bands, and distinction from automatic pipeline forecast |

The shared helper remains one file because `prepare` and `evaluate` share hashing, manifest, contract, and report utilities. The adapters contain orchestration instructions only.

---

### Task 1: Prepare forecast context and prompt

**Files:**
- Create: `scripts/spec2pr-forecast.sh`
- Create: `tests/spec2pr/test-standalone-forecast.sh`

**Interfaces:**
- Produces: `bash scripts/spec2pr-forecast.sh prepare <artifact-path> <run-dir>`.
- Produces: `<run-dir>/manifest.json` with `repo_root`, `repo_head`, diff fingerprints, numeric configuration, primary kind, and exact artifact identities.
- Produces: `<run-dir>/prompt.txt`, a self-contained one-agent read-only forecast prompt.
- Consumes later: Task 2 reads the manifest and prompt contract without changing their field names.

- [ ] **Step 1: Add failing prepare tests and local forecast helpers**

Create `tests/spec2pr/test-standalone-forecast.sh` with:

```bash
#!/usr/bin/env bash

STANDALONE_FORECAST="$REPO_ROOT/scripts/spec2pr-forecast.sh"

_forecast_run_prepare() {
  local artifact="$1"
  FORECAST_RUN_DIR="$(mktemp -d -t standalone-forecast.XXXXXX)"
  local err="$FORECAST_RUN_DIR/prepare.stderr"
  set +e
  FORECAST_OUT="$(
    cd "$PROJECT" &&
      SPEC2PR_MAX_DIFF="${FORECAST_TEST_LIMIT:-131072}" \
      SPEC2PR_FORECAST_BYTES_PER_LINE="${FORECAST_TEST_BPL:-40}" \
      bash "$STANDALONE_FORECAST" prepare "$artifact" "$FORECAST_RUN_DIR" 2>"$err"
  )"
  FORECAST_RC=$?
  set +e
  FORECAST_ERR="$(cat "$err")"
}

test_standalone_forecast_prepare_spec_discovers_plan() {
  make_sandbox
  local plan="$PROJECT/docs/superpowers/plans/toy-spec-plan.md"
  printf '# Toy plan\n\nImplement the version flag.\n' > "$plan"

  _forecast_run_prepare "$SPEC"

  assert_eq "0" "$FORECAST_RC" "forecast prepare accepts a spec"
  assert_file_exists "$FORECAST_RUN_DIR/manifest.json" "prepare writes manifest"
  assert_file_exists "$FORECAST_RUN_DIR/prompt.txt" "prepare writes prompt"
  assert_eq "spec" "$(jq -r '.primary_kind' "$FORECAST_RUN_DIR/manifest.json")" "spec kind recorded"
  assert_eq "2" "$(jq '.artifacts | length' "$FORECAST_RUN_DIR/manifest.json")" "plan companion included"
  assert_eq "$(cd "$(dirname "$SPEC")" && pwd -P)/$(basename "$SPEC")" \
    "$(jq -r '.artifacts[0].path' "$FORECAST_RUN_DIR/manifest.json")" "primary path canonicalized"
  assert_eq "$(cd "$(dirname "$plan")" && pwd -P)/$(basename "$plan")" \
    "$(jq -r '.artifacts[1].path' "$FORECAST_RUN_DIR/manifest.json")" "plan path discovered"
}

test_standalone_forecast_prepare_plan_discovers_spec() {
  make_sandbox
  local plan="$PROJECT/docs/superpowers/plans/toy-spec-plan.md"
  printf '# Toy plan\n' > "$plan"

  _forecast_run_prepare "$plan"

  assert_eq "0" "$FORECAST_RC" "forecast prepare accepts a plan"
  assert_eq "plan" "$(jq -r '.primary_kind' "$FORECAST_RUN_DIR/manifest.json")" "plan kind recorded"
  assert_eq "$(cd "$(dirname "$SPEC")" && pwd -P)/$(basename "$SPEC")" \
    "$(jq -r '.artifacts[1].path' "$FORECAST_RUN_DIR/manifest.json")" "spec path discovered"
}

test_standalone_forecast_prepare_keeps_primary_without_companion() {
  make_sandbox

  _forecast_run_prepare "$SPEC"

  assert_eq "0" "$FORECAST_RC" "missing companion is non-fatal"
  assert_eq "1" "$(jq '.artifacts | length' "$FORECAST_RUN_DIR/manifest.json")" "primary-only manifest"
  assert_contains "$FORECAST_ERR" "companion not found" "missing companion warning is visible"
}

test_standalone_forecast_prepare_accepts_external_path_with_spaces() {
  make_sandbox
  local external="$SANDBOX/external feature.md"
  printf '# External feature\n' > "$external"

  _forecast_run_prepare "$external"

  assert_eq "0" "$FORECAST_RC" "external artifact with spaces accepted"
  assert_eq "$external" "$(jq -r '.artifacts[0].path' "$FORECAST_RUN_DIR/manifest.json")" "external path preserved"
  assert_eq "$PROJECT" "$(jq -r '.repo_root' "$FORECAST_RUN_DIR/manifest.json")" "cwd repository selected"
}

test_standalone_forecast_prepare_generic_file_has_no_companion() {
  make_sandbox
  local artifact="$SANDBOX/feature-input.txt"
  printf 'Implement a small feature.\n' > "$artifact"

  _forecast_run_prepare "$artifact"

  assert_eq "0" "$FORECAST_RC" "generic readable artifact accepted"
  assert_eq "artifact" "$(jq -r '.primary_kind' "$FORECAST_RUN_DIR/manifest.json")" "generic kind recorded"
  assert_eq "1" "$(jq '.artifacts | length' "$FORECAST_RUN_DIR/manifest.json")" "generic artifact has no companion"
}

test_standalone_forecast_prepare_embeds_contract_and_snapshot() {
  make_sandbox
  _forecast_run_prepare "$SPEC"
  local manifest prompt
  manifest="$(cat "$FORECAST_RUN_DIR/manifest.json")"
  prompt="$(cat "$FORECAST_RUN_DIR/prompt.txt")"

  assert_eq "40" "$(jq -r '.bytes_per_line' <<<"$manifest")" "bytes-per-line recorded"
  assert_eq "131072" "$(jq -r '.max_diff' <<<"$manifest")" "diff limit recorded"
  assert_eq "40" "$(jq -r '.bytes_per_line' <<<"$manifest")" "numeric values are JSON numbers"
  assert_contains "$prompt" "Return one JSON object and no prose" "prompt requires JSON only"
  assert_contains "$prompt" "Do not edit, create, or delete" "prompt is read-only"
  assert_contains "$prompt" "Do not launch another agent" "prompt forbids nested agents"
  assert_contains "$prompt" '"depends_on"' "prompt includes split dependency schema"
  assert_contains "$prompt" "131072" "prompt includes live limit"
  assert_contains "$prompt" "40 bytes per changed line" "prompt includes live conversion"
  assert_eq "$(git -C "$PROJECT" rev-parse HEAD)" "$(jq -r '.repo_head' <<<"$manifest")" "HEAD captured"
  assert_eq "64" "$(jq -r '.staged_sha256 | length' <<<"$manifest")" "staged fingerprint captured"
  assert_eq "64" "$(jq -r '.unstaged_sha256 | length' <<<"$manifest")" "unstaged fingerprint captured"
  assert_eq "64" "$(jq -r '.untracked_sha256 | length' <<<"$manifest")" "untracked fingerprint captured"
}

test_standalone_forecast_prepare_rejects_bad_inputs_before_prompt() {
  make_sandbox
  _forecast_run_prepare "$SANDBOX/missing.md"
  assert_eq "1" "$FORECAST_RC" "missing input halts"
  assert_contains "$FORECAST_OUT$FORECAST_ERR" "SPEC2PR HALT forecast:" "missing input uses contract"
  assert_file_absent "$FORECAST_RUN_DIR/prompt.txt" "missing input creates no prompt"

  local outside="$SANDBOX/not-a-repo" artifact="$SANDBOX/standalone.md"
  mkdir -p "$outside"
  printf '# Standalone\n' > "$artifact"
  FORECAST_RUN_DIR="$(mktemp -d -t standalone-forecast.XXXXXX)"
  set +e
  FORECAST_OUT="$(cd "$outside" && bash "$STANDALONE_FORECAST" prepare "$artifact" "$FORECAST_RUN_DIR" 2>&1)"
  FORECAST_RC=$?
  set +e
  assert_eq "1" "$FORECAST_RC" "non-repository cwd halts"
  assert_contains "$FORECAST_OUT" "not inside a Git repository" "repository error is explicit"
}

test_standalone_forecast_prepare_rejects_invalid_configuration() {
  make_sandbox
  FORECAST_TEST_LIMIT=0 _forecast_run_prepare "$SPEC"
  assert_eq "1" "$FORECAST_RC" "zero diff limit rejected"
  assert_contains "$FORECAST_OUT$FORECAST_ERR" "SPEC2PR_MAX_DIFF must be a positive integer" "limit validation is explicit"

  FORECAST_TEST_LIMIT=131072 FORECAST_TEST_BPL=nope _forecast_run_prepare "$SPEC"
  assert_eq "1" "$FORECAST_RC" "non-numeric bytes-per-line rejected"
  assert_contains "$FORECAST_OUT$FORECAST_ERR" "SPEC2PR_FORECAST_BYTES_PER_LINE must be a positive integer" "conversion validation is explicit"
}
```

- [ ] **Step 2: Run the new tests and verify RED**

Run:

```bash
bash -o pipefail -c 'bash tests/spec2pr/run-tests.sh 2>&1 | tee /tmp/standalone-forecast-task1-red.log'
```

Expected: every `test_standalone_forecast_prepare_*` case fails because `scripts/spec2pr-forecast.sh` does not exist; the existing suite remains otherwise unchanged.

- [ ] **Step 3: Implement the prepare subcommand**

Create `scripts/spec2pr-forecast.sh` with this structure and complete prepare path:

```bash
#!/usr/bin/env bash
set -euo pipefail

SPEC2PR_MAX_DIFF="${SPEC2PR_MAX_DIFF:-131072}"
SPEC2PR_FORECAST_BYTES_PER_LINE="${SPEC2PR_FORECAST_BYTES_PER_LINE:-40}"

halt() {
  printf 'SPEC2PR HALT forecast: %s\n' "$1"
  exit 1
}

warn() {
  printf 'SPEC2PR WARN forecast: %s\n' "$1" >&2
}

usage() {
  halt "usage: spec2pr-forecast.sh prepare <artifact-path> <run-dir> | evaluate <run-dir> | cleanup <run-dir>"
}

positive_integer() {
  case "$1" in
    ''|*[!0-9]*|0) return 1 ;;
    *) return 0 ;;
  esac
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || halt "missing dependency: $1"
}

hash_stream() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    halt "missing dependency: shasum or sha256sum"
  fi
}

hash_file() {
  hash_stream < "$1"
}

absolute_file() {
  local path="$1" dir base
  dir="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)" || return 1
  base="$(basename "$path")"
  printf '%s/%s\n' "$dir" "$base"
}

untracked_fingerprint() {
  local repo="$1"
  (
    while IFS= read -r -d '' rel; do
      local full="$repo/$rel" kind digest
      if [ -L "$full" ]; then
        kind="symlink"
        digest="$(printf '%s' "$(readlink "$full")" | hash_stream)"
      elif [ -f "$full" ]; then
        kind="file"
        digest="$(hash_file "$full")"
      else
        kind="other"
        digest="-"
      fi
      printf '%s\0%s\0%s\0' "$rel" "$kind" "$digest"
    done < <(git -C "$repo" ls-files --others --exclude-standard -z)
  ) | hash_stream
}

repo_snapshot() {
  local repo="$1" head staged unstaged untracked
  head="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" || halt "repository has no HEAD commit"
  staged="$(git -C "$repo" diff --cached --binary | hash_stream)"
  unstaged="$(git -C "$repo" diff --binary | hash_stream)"
  untracked="$(untracked_fingerprint "$repo")"
  jq -n --arg head "$head" --arg staged "$staged" --arg unstaged "$unstaged" --arg untracked "$untracked" \
    '{repo_head:$head, staged_sha256:$staged, unstaged_sha256:$unstaged, untracked_sha256:$untracked}'
}

prepare_forecast() {
  [ "$#" -eq 2 ] || usage
  local input="$1" run_dir="$2" repo primary base primary_kind candidate="" companion=""
  local artifacts snapshot artifacts_json run_dir_abs

  require_command git
  require_command jq
  positive_integer "$SPEC2PR_MAX_DIFF" || halt "SPEC2PR_MAX_DIFF must be a positive integer"
  positive_integer "$SPEC2PR_FORECAST_BYTES_PER_LINE" || halt "SPEC2PR_FORECAST_BYTES_PER_LINE must be a positive integer"
  SPEC2PR_MAX_DIFF=$((10#$SPEC2PR_MAX_DIFF))
  SPEC2PR_FORECAST_BYTES_PER_LINE=$((10#$SPEC2PR_FORECAST_BYTES_PER_LINE))
  [ -f "$input" ] && [ -r "$input" ] || halt "input is not a readable regular file: $input"
  [ -d "$run_dir" ] || halt "run directory does not exist: $run_dir"

  repo="$(git rev-parse --show-toplevel 2>/dev/null)" || halt "not inside a Git repository"
  repo="$(cd "$repo" && pwd -P)"
  run_dir_abs="$(cd "$run_dir" && pwd -P)"
  case "$run_dir_abs/" in
    "$repo/"*) halt "run directory must be outside the target repository" ;;
  esac
  [ ! -e "$run_dir_abs/manifest.json" ] && [ ! -e "$run_dir_abs/prompt.txt" ] \
    || halt "run directory already contains forecast state"

  primary="$(absolute_file "$input")" || halt "cannot resolve input path: $input"
  base="$(basename "$primary")"
  case "$base" in
    *-plan.md)
      primary_kind="plan"
      candidate="$repo/docs/superpowers/specs/${base%-plan.md}.md"
      ;;
    *.md)
      primary_kind="spec"
      candidate="$repo/docs/superpowers/plans/${base%.md}-plan.md"
      ;;
    *)
      primary_kind="artifact"
      ;;
  esac

  if [ -n "$candidate" ]; then
    if [ -f "$candidate" ] && [ -r "$candidate" ]; then
      companion="$(absolute_file "$candidate")"
    elif [ -e "$candidate" ]; then
      warn "companion is not readable; continuing with primary only: $candidate"
    else
      warn "companion not found; continuing with primary only: $candidate"
    fi
  fi

  artifacts="$(jq -n --arg path "$primary" --arg sha "$(hash_file "$primary")" \
    '[{role:"primary", path:$path, sha256:$sha}]')"
  if [ -n "$companion" ]; then
    artifacts="$(jq --arg path "$companion" --arg sha "$(hash_file "$companion")" \
      '. + [{role:"companion", path:$path, sha256:$sha}]' <<<"$artifacts")"
  fi
  snapshot="$(repo_snapshot "$repo")"

  jq -n --arg repo "$repo" --arg kind "$primary_kind" \
    --argjson snapshot "$snapshot" --argjson artifacts "$artifacts" \
    --argjson bpl "$SPEC2PR_FORECAST_BYTES_PER_LINE" --argjson limit "$SPEC2PR_MAX_DIFF" '
      {
        repo_root:$repo,
        repo_head:$snapshot.repo_head,
        staged_sha256:$snapshot.staged_sha256,
        unstaged_sha256:$snapshot.unstaged_sha256,
        untracked_sha256:$snapshot.untracked_sha256,
        bytes_per_line:$bpl,
        max_diff:$limit,
        primary_kind:$kind,
        artifacts:$artifacts
      }
    ' > "$run_dir_abs/manifest.json"

  artifacts_json="$(jq -c '.artifacts' "$run_dir_abs/manifest.json")"
  cat > "$run_dir_abs/prompt.txt" <<EOF
You are one fresh read-only implementation-size forecaster.

Repository root: $repo
Expected repository HEAD: $(jq -r '.repo_head' "$run_dir_abs/manifest.json")
Artifacts to read, in exact identity order: $artifacts_json

Inspect the artifacts and enough of the repository to estimate the eventual
implementation. Include code, tests, configuration, migrations, and supporting
documentation that implementation would create or change. Do not count the
supplied spec or plan artifacts themselves.

Estimate rough added or changed LOC for every likely implementation file.
The deterministic evaluator will multiply total LOC by
$SPEC2PR_FORECAST_BYTES_PER_LINE bytes per changed line and compare it with
the $SPEC2PR_MAX_DIFF-byte diff limit.

If that multiplication exceeds the limit, provide 2-4 sequential advisory
parts. Each part has a unique name, a concise scope, file paths drawn from the
top-level files array, and one-based depends_on part numbers that refer only to
earlier parts. Otherwise return an empty parts array.

This is read-only. Do not edit, create, or delete repository or artifact files.
Do not commit, push, implement, or launch another agent.

Return one JSON object and no prose. Do not use a code fence. Echo repo_head and
artifacts exactly as supplied. Use exactly this shape and no extra keys:
{
  "repo_head":"$(jq -r '.repo_head' "$run_dir_abs/manifest.json")",
  "artifacts":$artifacts_json,
  "files":[{"path":"src/example.ts","loc":100}],
  "total_loc":100,
  "summary":"One-line implementation scope summary.",
  "parts":[]
}

When the estimate exceeds the limit, replace the empty parts array with 2-4
objects using exactly this item shape:
{"name":"Part 1: foundation","scope":"Add the foundation.","files":["src/example.ts"],"depends_on":[]}
EOF
}

case "${1:-}" in
  prepare)
    shift
    prepare_forecast "$@"
    ;;
  evaluate)
    halt "evaluate is not implemented yet"
    ;;
  *)
    usage
    ;;
esac
```

- [ ] **Step 4: Make the script executable and run Task 1 tests**

Run:

```bash
chmod +x scripts/spec2pr-forecast.sh
bash -n scripts/spec2pr-forecast.sh
bash -o pipefail -c 'bash tests/spec2pr/run-tests.sh 2>&1 | tee /tmp/standalone-forecast-task1-green.log'
```

Expected: all tests pass, including every `test_standalone_forecast_prepare_*` case; final line is `N tests run, 0 failed`.

- [ ] **Step 5: Commit Task 1**

```bash
git add scripts/spec2pr-forecast.sh tests/spec2pr/test-standalone-forecast.sh
git commit -m "feat: prepare standalone spec2pr forecasts"
```

---

### Task 2: Evaluate valid forecast results and render decisions

**Files:**
- Modify: `scripts/spec2pr-forecast.sh`
- Modify: `tests/spec2pr/test-standalone-forecast.sh`

**Interfaces:**
- Consumes: Task 1's `manifest.json` and adapter-owned `<run-dir>/result.txt`.
- Produces: `bash scripts/spec2pr-forecast.sh evaluate <run-dir>` with exit 0, 1, or 2.
- Produces: exact `OK`, `WARN`, `SPLIT`, and `HALT` terminal contracts.
- Produces: valid bare JSON or a single exact fenced `json` block normalization.

- [ ] **Step 1: Add result-fixture and evaluate helpers**

Append to `tests/spec2pr/test-standalone-forecast.sh`:

```bash
_forecast_write_result() {
  local total_loc="$1" fenced="${2:-0}" parts='[]' body first second
  first=$((total_loc / 2))
  second=$((total_loc - first))
  if [ "$((total_loc * FORECAST_TEST_BPL))" -gt "$FORECAST_TEST_LIMIT" ]; then
    parts='[
      {"name":"Part 1: core","scope":"Add the core implementation.","files":["src/core.ts"],"depends_on":[]},
      {"name":"Part 2: tests","scope":"Add integration coverage.","files":["tests/core.test.ts"],"depends_on":[1]}
    ]'
  fi
  body="$(jq -n \
    --arg head "$(jq -r '.repo_head' "$FORECAST_RUN_DIR/manifest.json")" \
    --argjson artifacts "$(jq -c '.artifacts' "$FORECAST_RUN_DIR/manifest.json")" \
    --argjson first "$first" --argjson second "$second" \
    --argjson total "$total_loc" --argjson parts "$parts" '
      {
        repo_head:$head,
        artifacts:$artifacts,
        files:[
          {path:"src/core.ts", loc:$first},
          {path:"tests/core.test.ts", loc:$second}
        ],
        total_loc:$total,
        summary:"Add the core implementation and integration coverage.",
        parts:$parts
      }
    ')"
  if [ "$fenced" -eq 1 ]; then
    printf '```json\n%s\n```\n' "$body" > "$FORECAST_RUN_DIR/result.txt"
  else
    printf '%s\n' "$body" > "$FORECAST_RUN_DIR/result.txt"
  fi
}

_forecast_run_evaluate() {
  set +e
  FORECAST_OUT="$(bash "$STANDALONE_FORECAST" evaluate "$FORECAST_RUN_DIR" 2>&1)"
  FORECAST_RC=$?
  set +e
}

_forecast_prepare_for_evaluate() {
  make_sandbox
  FORECAST_TEST_LIMIT=1000
  FORECAST_TEST_BPL=40
  _forecast_run_prepare "$SPEC"
  assert_eq "0" "$FORECAST_RC" "evaluation fixture prepares"
}
```

- [ ] **Step 2: Add failing boundary and rendering tests**

Append:

```bash
test_standalone_forecast_evaluate_low_risk_exits_zero() {
  _forecast_prepare_for_evaluate
  _forecast_write_result 19
  _forecast_run_evaluate

  assert_eq "0" "$FORECAST_RC" "low-risk forecast exits zero"
  assert_contains "$FORECAST_OUT" "Estimated implementation: 19 LOC, 760 bytes (76%)" "low-risk arithmetic rendered"
  assert_contains "$FORECAST_OUT" "Likely files:" "file breakdown rendered"
  assert_contains "$FORECAST_OUT" "10 LOC" "largest LOC entry rendered"
  assert_eq "SPEC2PR OK forecast: fits est=760 limit=1000" "$(tail -n1 <<<"$FORECAST_OUT")" "low-risk contract is final"
}

test_standalone_forecast_evaluate_warns_at_first_80_percent_integer() {
  _forecast_prepare_for_evaluate
  _forecast_write_result 20
  _forecast_run_evaluate

  assert_eq "0" "$FORECAST_RC" "near-limit forecast exits zero"
  assert_eq "SPEC2PR WARN forecast: near-limit est=800 limit=1000 utilization=80%" \
    "$(tail -n1 <<<"$FORECAST_OUT")" "80 percent boundary warns"
}

test_standalone_forecast_evaluate_exact_limit_warns_without_split() {
  _forecast_prepare_for_evaluate
  _forecast_write_result 25
  _forecast_run_evaluate

  assert_eq "0" "$FORECAST_RC" "exact limit exits zero"
  assert_eq "SPEC2PR WARN forecast: near-limit est=1000 limit=1000 utilization=100%" \
    "$(tail -n1 <<<"$FORECAST_OUT")" "exact limit is near-limit"
}

test_standalone_forecast_evaluate_over_limit_splits_with_parts() {
  _forecast_prepare_for_evaluate
  _forecast_write_result 26
  _forecast_run_evaluate

  assert_eq "2" "$FORECAST_RC" "over-limit forecast exits two"
  assert_contains "$FORECAST_OUT" "Recommended parts:" "split outline rendered"
  assert_contains "$FORECAST_OUT" "Part 1: core" "first part rendered"
  assert_contains "$FORECAST_OUT" "depends on: 1" "dependency rendered"
  assert_eq "SPEC2PR SPLIT forecast est=1040 limit=1000" "$(tail -n1 <<<"$FORECAST_OUT")" "split contract is final"
}

test_standalone_forecast_evaluate_accepts_one_json_fence() {
  _forecast_prepare_for_evaluate
  _forecast_write_result 19 1
  _forecast_run_evaluate

  assert_eq "0" "$FORECAST_RC" "single JSON fence accepted"
  assert_eq "SPEC2PR OK forecast: fits est=760 limit=1000" "$(tail -n1 <<<"$FORECAST_OUT")" "fenced result evaluated"
}

test_standalone_forecast_evaluate_missing_result_halts() {
  _forecast_prepare_for_evaluate
  _forecast_run_evaluate

  assert_eq "1" "$FORECAST_RC" "missing agent response exits one"
  assert_contains "$FORECAST_OUT" "SPEC2PR HALT forecast: native agent did not return a result" "missing response contract"
}
```

- [ ] **Step 3: Run tests and verify RED**

Run:

```bash
bash -o pipefail -c 'bash tests/spec2pr/run-tests.sh 2>&1 | tee /tmp/standalone-forecast-task2-red.log'
```

Expected: the new `test_standalone_forecast_evaluate_*` cases fail with `evaluate is not implemented yet`; Task 1 prepare tests stay green.

- [ ] **Step 4: Implement result normalization, core validation, arithmetic, and rendering**

Add these functions before the final `case` in `scripts/spec2pr-forecast.sh`:

```bash
normalize_result() {
  local source="$1" target="$2"
  if jq -e . "$source" > /dev/null 2>&1; then
    cp "$source" "$target"
    return 0
  fi
  if [ "$(sed -n '1p' "$source")" = '```json' ] \
      && [ "$(tail -n1 "$source")" = '```' ]; then
    sed '1d;$d' "$source" > "$target"
    jq -e . "$target" > /dev/null 2>&1
    return $?
  fi
  return 1
}

core_result_valid() {
  local result="$1" manifest="$2"
  jq -e \
    --arg head "$(jq -r '.repo_head' "$manifest")" \
    --argjson artifacts "$(jq -c '.artifacts' "$manifest")" \
    --argjson bpl "$(jq '.bytes_per_line' "$manifest")" \
    --argjson limit "$(jq '.max_diff' "$manifest")" '
      type == "object"
      and (.repo_head == $head)
      and (.artifacts == $artifacts)
      and (.files | type == "array")
      and ([.files[] | (
        type == "object"
        and (.path | type == "string" and length > 0)
        and (.loc | type == "number" and . == floor and . >= 0)
      )] | all)
      and (.total_loc | type == "number" and . == floor and . >= 0)
      and (.total_loc == ([.files[].loc] | add // 0))
      and (.summary | type == "string" and length > 0 and (test("[\\r\\n]") | not))
      and (.parts | type == "array")
      and (
        if (.total_loc * $bpl) > $limit
        then (.parts | length >= 2 and length <= 4)
        else (.parts | length == 0)
        end
      )
    ' "$result" > /dev/null 2>&1
}

render_parts() {
  local result="$1"
  jq -r '
    .parts | to_entries[] |
    "  \(.key + 1). \(.value.name)\n" +
    "     \(.value.scope)\n" +
    "     files: \(.value.files | join(", "))\n" +
    "     depends on: \(if (.value.depends_on | length) == 0 then "none" else (.value.depends_on | map(tostring) | join(", ")) end)"
  ' "$result"
}

evaluate_forecast() {
  [ "$#" -eq 1 ] || usage
  local run_dir="$1" manifest="$run_dir/manifest.json" source="$run_dir/result.txt"
  local result="$run_dir/result.normalized.json" total bpl limit estimate utilization

  [ -f "$manifest" ] || halt "forecast manifest is missing"
  [ -s "$source" ] || halt "native agent did not return a result"
  normalize_result "$source" "$result" || halt "native agent returned malformed forecast JSON"
  core_result_valid "$result" "$manifest" || halt "native agent returned an invalid forecast payload"

  total="$(jq -r '.total_loc' "$result")"
  bpl="$(jq -r '.bytes_per_line' "$manifest")"
  limit="$(jq -r '.max_diff' "$manifest")"
  estimate=$((total * bpl))
  utilization=$((estimate * 100 / limit))

  printf 'Forecast context:\n'
  jq -r '.artifacts[] | "  \(.role): \(.path)"' "$manifest"
  printf 'Estimated implementation: %s LOC, %s bytes (%s%%)\n' "$total" "$estimate" "$utilization"
  printf 'Likely files:\n'
  jq -r '.files | sort_by(.loc) | reverse[] | "  \(.loc) LOC  \(.path)"' "$result"
  printf 'Summary: %s\n' "$(jq -r '.summary' "$result")"

  if [ "$estimate" -gt "$limit" ]; then
    printf 'Recommended parts:\n'
    render_parts "$result"
    printf 'SPEC2PR SPLIT forecast est=%s limit=%s\n' "$estimate" "$limit"
    exit 2
  fi
  if [ "$((estimate * 100))" -ge "$((limit * 80))" ]; then
    printf 'SPEC2PR WARN forecast: near-limit est=%s limit=%s utilization=%s%%\n' \
      "$estimate" "$limit" "$utilization"
    exit 0
  fi
  printf 'SPEC2PR OK forecast: fits est=%s limit=%s\n' "$estimate" "$limit"
}
```

Replace the `evaluate)` arm with:

```bash
  evaluate)
    shift
    evaluate_forecast "$@"
    ;;
```

- [ ] **Step 5: Run Task 2 and full spec2pr tests**

Run:

```bash
bash -n scripts/spec2pr-forecast.sh
bash -o pipefail -c 'bash tests/spec2pr/run-tests.sh 2>&1 | tee /tmp/standalone-forecast-task2-green.log'
```

Expected: `N tests run, 0 failed`; valid low, warning, exact-limit, fenced, split, and missing-result cases all pass.

- [ ] **Step 6: Commit Task 2**

```bash
git add scripts/spec2pr-forecast.sh tests/spec2pr/test-standalone-forecast.sh
git commit -m "feat: evaluate standalone spec2pr forecasts"
```

---

### Task 3: Enforce strict payload and read-only state contracts

**Files:**
- Modify: `scripts/spec2pr-forecast.sh`
- Modify: `tests/spec2pr/test-standalone-forecast.sh`

**Interfaces:**
- Strengthens: `evaluate` rejects extra keys, duplicate paths, invalid part references, stale artifact hashes, and any target-state change.
- Preserves: Task 2's valid result and output contracts verbatim.
- Safety rule: detection reports and exits 1; it never runs reset, checkout, clean, or restore.

- [ ] **Step 1: Add failing strict-validation tests**

Append:

```bash
test_standalone_forecast_evaluate_rejects_extra_keys_and_duplicate_files() {
  _forecast_prepare_for_evaluate
  _forecast_write_result 19
  local tmp="$FORECAST_RUN_DIR/result.tmp"
  jq '.extra = true' "$FORECAST_RUN_DIR/result.txt" > "$tmp"
  mv "$tmp" "$FORECAST_RUN_DIR/result.txt"
  _forecast_run_evaluate
  assert_eq "1" "$FORECAST_RC" "extra result key rejected"

  _forecast_prepare_for_evaluate
  _forecast_write_result 19
  tmp="$FORECAST_RUN_DIR/result.tmp"
  jq '.files[1].path = .files[0].path' "$FORECAST_RUN_DIR/result.txt" > "$tmp"
  mv "$tmp" "$FORECAST_RUN_DIR/result.txt"
  _forecast_run_evaluate
  assert_eq "1" "$FORECAST_RC" "duplicate file path rejected"
}

test_standalone_forecast_evaluate_rejects_invalid_part_dependencies() {
  _forecast_prepare_for_evaluate
  _forecast_write_result 26
  local tmp="$FORECAST_RUN_DIR/result.tmp"
  jq '.parts[0].depends_on = [1]' "$FORECAST_RUN_DIR/result.txt" > "$tmp"
  mv "$tmp" "$FORECAST_RUN_DIR/result.txt"
  _forecast_run_evaluate
  assert_eq "1" "$FORECAST_RC" "part cannot depend on itself"
  assert_contains "$FORECAST_OUT" "invalid forecast payload" "dependency error uses payload halt"
}

test_standalone_forecast_evaluate_rejects_surrounding_prose() {
  _forecast_prepare_for_evaluate
  _forecast_write_result 19
  local body
  body="$(cat "$FORECAST_RUN_DIR/result.txt")"
  printf 'Forecast follows.\n%s\n' "$body" > "$FORECAST_RUN_DIR/result.txt"
  _forecast_run_evaluate
  assert_eq "1" "$FORECAST_RC" "surrounding prose rejected"
  assert_contains "$FORECAST_OUT" "malformed forecast JSON" "prose failure is explicit"
}

test_standalone_forecast_evaluate_rejects_stale_context_and_bad_total() {
  _forecast_prepare_for_evaluate
  _forecast_write_result 19
  local tmp="$FORECAST_RUN_DIR/result.tmp"
  jq '.repo_head = "wrong"' "$FORECAST_RUN_DIR/result.txt" > "$tmp"
  mv "$tmp" "$FORECAST_RUN_DIR/result.txt"
  _forecast_run_evaluate
  assert_eq "1" "$FORECAST_RC" "stale repository identity rejected"

  _forecast_prepare_for_evaluate
  _forecast_write_result 19
  tmp="$FORECAST_RUN_DIR/result.tmp"
  jq '.artifacts[0].sha256 = "wrong"' "$FORECAST_RUN_DIR/result.txt" > "$tmp"
  mv "$tmp" "$FORECAST_RUN_DIR/result.txt"
  _forecast_run_evaluate
  assert_eq "1" "$FORECAST_RC" "stale artifact identity rejected"

  _forecast_prepare_for_evaluate
  _forecast_write_result 19
  tmp="$FORECAST_RUN_DIR/result.tmp"
  jq '.total_loc += 1' "$FORECAST_RUN_DIR/result.txt" > "$tmp"
  mv "$tmp" "$FORECAST_RUN_DIR/result.txt"
  _forecast_run_evaluate
  assert_eq "1" "$FORECAST_RC" "inconsistent LOC total rejected"
}

test_standalone_forecast_evaluate_rejects_bad_split_shape() {
  _forecast_prepare_for_evaluate
  _forecast_write_result 26
  local tmp="$FORECAST_RUN_DIR/result.tmp"
  jq '.parts = [.parts[0]]' "$FORECAST_RUN_DIR/result.txt" > "$tmp"
  mv "$tmp" "$FORECAST_RUN_DIR/result.txt"
  _forecast_run_evaluate
  assert_eq "1" "$FORECAST_RC" "one-part over-limit outline rejected"

  _forecast_prepare_for_evaluate
  _forecast_write_result 26
  tmp="$FORECAST_RUN_DIR/result.tmp"
  jq '.parts[1].files = ["src/unknown.ts"]' "$FORECAST_RUN_DIR/result.txt" > "$tmp"
  mv "$tmp" "$FORECAST_RUN_DIR/result.txt"
  _forecast_run_evaluate
  assert_eq "1" "$FORECAST_RC" "unknown split file rejected"

  _forecast_prepare_for_evaluate
  _forecast_write_result 19
  tmp="$FORECAST_RUN_DIR/result.tmp"
  jq '.summary = "line one\nline two"' "$FORECAST_RUN_DIR/result.txt" > "$tmp"
  mv "$tmp" "$FORECAST_RUN_DIR/result.txt"
  _forecast_run_evaluate
  assert_eq "1" "$FORECAST_RC" "multiline summary rejected"
}
```

- [ ] **Step 2: Add failing state-mutation tests**

Append:

```bash
test_standalone_forecast_evaluate_detects_unstaged_change_without_reverting() {
  _forecast_prepare_for_evaluate
  _forecast_write_result 19
  printf 'changed while forecasting\n' >> "$PROJECT/README.md"
  _forecast_run_evaluate

  assert_eq "1" "$FORECAST_RC" "unstaged mutation halts"
  assert_contains "$FORECAST_OUT" "repository changed during forecast: unstaged" "unstaged category reported"
  assert_contains "$(cat "$PROJECT/README.md")" "changed while forecasting" "mutation is not reverted"
}

test_standalone_forecast_evaluate_detects_staged_change() {
  _forecast_prepare_for_evaluate
  _forecast_write_result 19
  printf 'staged change\n' >> "$PROJECT/README.md"
  git -C "$PROJECT" add README.md
  _forecast_run_evaluate
  assert_eq "1" "$FORECAST_RC" "staged mutation halts"
  assert_contains "$FORECAST_OUT" "repository changed during forecast: staged" "staged category reported"
}

test_standalone_forecast_evaluate_detects_untracked_change() {
  _forecast_prepare_for_evaluate
  _forecast_write_result 19
  printf 'new file\n' > "$PROJECT/new-during-forecast.txt"
  _forecast_run_evaluate
  assert_eq "1" "$FORECAST_RC" "untracked mutation halts"
  assert_contains "$FORECAST_OUT" "repository changed during forecast: untracked" "untracked category reported"
}

test_standalone_forecast_evaluate_detects_head_change() {
  _forecast_prepare_for_evaluate
  _forecast_write_result 19
  git -C "$PROJECT" commit --allow-empty -qm "move head during forecast"
  _forecast_run_evaluate
  assert_eq "1" "$FORECAST_RC" "HEAD mutation halts"
  assert_contains "$FORECAST_OUT" "repository changed during forecast: HEAD" "HEAD category reported"
}

test_standalone_forecast_evaluate_detects_external_artifact_change() {
  make_sandbox
  FORECAST_TEST_LIMIT=1000
  FORECAST_TEST_BPL=40
  local external="$SANDBOX/external feature.md"
  printf '# External feature\n' > "$external"
  _forecast_run_prepare "$external"
  _forecast_write_result 19
  printf 'changed\n' >> "$external"
  _forecast_run_evaluate

  assert_eq "1" "$FORECAST_RC" "external artifact mutation halts"
  assert_contains "$FORECAST_OUT" "artifact changed during forecast" "artifact category reported"
  assert_contains "$(cat "$external")" "changed" "external edit is not reverted"
}
```

- [ ] **Step 3: Run tests and verify RED**

Run:

```bash
bash -o pipefail -c 'bash tests/spec2pr/run-tests.sh 2>&1 | tee /tmp/standalone-forecast-task3-red.log'
```

Expected: state-mutation, extra-key, duplicate-file, and invalid-dependency tests fail because Task 2 does not yet enforce those contracts. Existing valid evaluations remain green.

- [ ] **Step 4: Add snapshot and artifact comparison**

Add before `normalize_result`:

```bash
assert_unchanged_state() {
  local manifest="$1" repo current categories="" status
  repo="$(jq -r '.repo_root' "$manifest")"
  current="$(repo_snapshot "$repo")"

  [ "$(jq -r '.repo_head' "$manifest")" = "$(jq -r '.repo_head' <<<"$current")" ] \
    || categories="${categories:+$categories, }HEAD"
  [ "$(jq -r '.staged_sha256' "$manifest")" = "$(jq -r '.staged_sha256' <<<"$current")" ] \
    || categories="${categories:+$categories, }staged"
  [ "$(jq -r '.unstaged_sha256' "$manifest")" = "$(jq -r '.unstaged_sha256' <<<"$current")" ] \
    || categories="${categories:+$categories, }unstaged"
  [ "$(jq -r '.untracked_sha256' "$manifest")" = "$(jq -r '.untracked_sha256' <<<"$current")" ] \
    || categories="${categories:+$categories, }untracked"

  if [ -n "$categories" ]; then
    status="$(git -C "$repo" status --short --untracked-files=all | tr '\n' ';' | sed 's/;$//')"
    if [ -n "$status" ]; then
      halt "repository changed during forecast: $categories ($status)"
    fi
    halt "repository changed during forecast: $categories"
  fi

  while IFS= read -r artifact; do
    local path expected
    path="$(jq -r '.path' <<<"$artifact")"
    expected="$(jq -r '.sha256' <<<"$artifact")"
    [ -f "$path" ] && [ -r "$path" ] && [ "$(hash_file "$path")" = "$expected" ] \
      || halt "artifact changed during forecast: $path"
  done < <(jq -c '.artifacts[]' "$manifest")
}
```

Call it in `evaluate_forecast` immediately after the manifest/result presence checks and before result normalization:

```bash
  assert_unchanged_state "$manifest"
```

- [ ] **Step 5: Replace core validation with strict validation**

Replace `core_result_valid` with:

```bash
strict_result_valid() {
  local result="$1" manifest="$2"
  jq -e \
    --arg head "$(jq -r '.repo_head' "$manifest")" \
    --argjson artifacts "$(jq -c '.artifacts' "$manifest")" \
    --argjson bpl "$(jq '.bytes_per_line' "$manifest")" \
    --argjson limit "$(jq '.max_diff' "$manifest")" '
      type == "object"
      and ((keys | sort) == ["artifacts","files","parts","repo_head","summary","total_loc"])
      and (.repo_head == $head)
      and (.artifacts == $artifacts)
      and (.files | type == "array")
      and ([.files[] | (
        type == "object"
        and ((keys | sort) == ["loc","path"])
        and (.path | type == "string" and length > 0)
        and (.loc | type == "number" and . == floor and . >= 0)
      )] | all)
      and (([.files[].path] | length) == ([.files[].path] | unique | length))
      and (.total_loc | type == "number" and . == floor and . >= 0)
      and (.total_loc == ([.files[].loc] | add // 0))
      and (.summary | type == "string" and length > 0 and (test("[\\r\\n]") | not))
      and (.parts | type == "array")
      and (
        (.files | map(.path)) as $known_files
        | ([range(0; (.parts | length)) as $index | .parts[$index] | (
          type == "object"
          and ((keys | sort) == ["depends_on","files","name","scope"])
          and (.name | type == "string" and length > 0)
          and (.scope | type == "string" and length > 0)
          and (.files | type == "array" and length > 0)
          and ([.files[] as $part_file | ($known_files | index($part_file) != null)] | all)
          and ((.files | length) == (.files | unique | length))
          and (.depends_on | type == "array")
          and ([.depends_on[] | type == "number" and . == floor and . >= 1 and . <= $index] | all)
          and ((.depends_on | length) == (.depends_on | unique | length))
        )] | all)
      )
      and (([.parts[].name] | length) == ([.parts[].name] | unique | length))
      and (
        if (.total_loc * $bpl) > $limit
        then (.parts | length >= 2 and length <= 4)
        else (.parts | length == 0)
        end
      )
    ' "$result" > /dev/null 2>&1
}
```

Change the evaluator call to:

```bash
  strict_result_valid "$result" "$manifest" \
    || halt "native agent returned an invalid forecast payload"
```

- [ ] **Step 6: Run focused and full verification**

Run:

```bash
bash -n scripts/spec2pr-forecast.sh
bash -o pipefail -c 'bash tests/spec2pr/run-tests.sh 2>&1 | tee /tmp/standalone-forecast-task3-green.log'
git diff --check
```

Expected: `N tests run, 0 failed`; all mutation cases halt while preserving the changed content; `git diff --check` prints nothing.

- [ ] **Step 7: Commit Task 3**

```bash
git add scripts/spec2pr-forecast.sh tests/spec2pr/test-standalone-forecast.sh
git commit -m "fix: enforce standalone forecast contracts"
```

---

### Task 4: Add the Claude command adapter

**Files:**
- Create: `commands/rulez/spec2pr-forecast.md`
- Modify: `scripts/spec2pr-forecast.sh`
- Modify: `settings.json`
- Modify: `tests/spec2pr/test-standalone-forecast.sh`

**Interfaces:**
- Produces: `/rulez:spec2pr-forecast <path>`.
- Consumes: shared `prepare` and `evaluate` subcommands from Tasks 1-3.
- Agent contract: one `Agent` call with `subagent_type: "general-purpose"`; its final response is saved verbatim to `result.txt`.

- [ ] **Step 1: Add failing Claude command and permission contract tests**

Append:

```bash
test_standalone_forecast_claude_command_contract() {
  local command_file="$REPO_ROOT/commands/rulez/spec2pr-forecast.md" body
  assert_file_exists "$command_file" "Claude spec2pr forecast command exists"
  [ -f "$command_file" ] || return 0
  body="$(cat "$command_file")"

  assert_contains "$body" '/rulez:spec2pr-forecast <path>' "Claude usage has spec2pr prefix"
  assert_contains "$body" 'set-current-command.sh spec2pr-forecast' "Claude command tracks status"
  assert_contains "$body" 'spec2pr-forecast.sh prepare' "Claude command delegates preparation"
  assert_contains "$body" 'subagent_type: "general-purpose"' "Claude command uses native general-purpose Agent"
  assert_contains "$body" 'Invoke the `Agent` tool exactly once' "Claude command limits agent count"
  assert_contains "$body" 'result.txt' "Claude command saves the final response"
  assert_contains "$body" 'spec2pr-forecast.sh evaluate' "Claude command delegates evaluation"
  assert_contains "$body" 'Do not run `claude -p` or `codex`' "Claude command forbids external model CLIs"
  assert_contains "$body" 'Run `evaluate` even when the Agent fails' "Claude agent failure reaches shared evaluator"
}

test_standalone_forecast_claude_permissions_are_allowlisted() {
  local settings
  settings="$(cat "$REPO_ROOT/settings.json")"
  assert_contains "$settings" 'Bash(bash ~/.claude/skills/rulez-claudeset/scripts/spec2pr-forecast.sh:*)' "forecast helper is allowlisted"
  assert_contains "$settings" 'Bash(mktemp -d /tmp/spec2pr-forecast.XXXXXX)' "forecast temp creation is allowlisted"
  assert_not_contains "$settings" 'Bash(rm -rf:*)' "forecast does not grant general recursive removal"
}

test_standalone_forecast_cleanup_is_guarded() {
  local owned outside out rc
  owned="$(mktemp -d /tmp/spec2pr-forecast.XXXXXX)"
  bash "$STANDALONE_FORECAST" cleanup "$owned"
  assert_file_absent "$owned" "guarded cleanup removes owned forecast directory"

  outside="$(mktemp -d -t not-forecast.XXXXXX)"
  set +e
  out="$(bash "$STANDALONE_FORECAST" cleanup "$outside" 2>&1)"
  rc=$?
  set +e
  assert_eq "1" "$rc" "guarded cleanup rejects unrelated directory"
  assert_contains "$out" "refusing to clean non-forecast directory" "cleanup refusal is explicit"
  assert_file_exists "$outside" "refused cleanup preserves unrelated directory"
  rmdir "$outside"
}
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
bash -o pipefail -c 'bash tests/spec2pr/run-tests.sh 2>&1 | tee /tmp/standalone-forecast-task4-red.log'
```

Expected: Claude command-file and permission assertions fail; all executable helper tests remain green.

- [ ] **Step 3: Create the Claude command**

Create `commands/rulez/spec2pr-forecast.md`:

```markdown
# Spec2PR Forecast

Forecast whether implementing one spec or plan is likely to fit through
spec2pr's PR-size gate. This command is read-only and uses one native Claude
Agent. It does not run spec2pr or create split files.

## Usage

`/rulez:spec2pr-forecast <path>`

Exactly one readable path is required. Quote paths containing spaces.

## Instructions

0. Track the command:
   `~/.claude/skills/rulez-claudeset/scripts/set-current-command.sh spec2pr-forecast`

1. Parse `$ARGUMENTS` as exactly one path. Reject missing input, unknown flags,
   or an additional positional argument by showing the Usage block. Preserve a
   quoted path as one argument.

2. Create one owned run directory with
   `mktemp -d /tmp/spec2pr-forecast.XXXXXX`. Remember it as `RUN_DIR`.

3. From the target project workspace run:
   `bash ~/.claude/skills/rulez-claudeset/scripts/spec2pr-forecast.sh prepare "$PATH" "$RUN_DIR"`
   If preparation fails, show its output, remove `RUN_DIR`, and stop. Do not
   invoke an Agent.

4. Read `$RUN_DIR/prompt.txt`. Invoke the `Agent` tool exactly once with
   `subagent_type: "general-purpose"` and the complete prompt as its task.
   Do not add or remove forecast requirements. Wait for that Agent to finish.
   Do not launch a retry, reviewer, decomposer, or fallback Agent.

5. Use the Write tool to save the Agent's complete final response verbatim to
   `$RUN_DIR/result.txt`. If the Agent tool fails or has no final response,
   leave `result.txt` absent. Run `evaluate` even when the Agent fails.

6. Run:
   `bash ~/.claude/skills/rulez-claudeset/scripts/spec2pr-forecast.sh evaluate "$RUN_DIR"`
   Preserve and show its complete output. Treat exit 2 as a successful
   forecast whose result is SPLIT, not as an orchestration failure.

7. Run
   `bash ~/.claude/skills/rulez-claudeset/scripts/spec2pr-forecast.sh cleanup "$RUN_DIR"`.
   Preserve the evaluator's exit classification if cleanup fails, and warn
   about the leftover directory.

Do not run `claude -p` or `codex`. Do not edit the target repository. Do not
invoke spec2pr or spec2pr-split. The helper owns validation, arithmetic, report
wording, and terminal contracts.
```

- [ ] **Step 4: Add the narrow Claude permissions**

In `settings.json`, next to the existing `spec2pr.sh` and `cycle-prompt.sh` entries, add:

```json
"Bash(bash ~/.claude/skills/rulez-claudeset/scripts/spec2pr-forecast.sh:*)",
"Bash(mktemp -d /tmp/spec2pr-forecast.XXXXXX)",
```

Do not add a general `rm`, `mktemp`, `claude`, or `codex` permission.

- [ ] **Step 5: Implement guarded cleanup**

Add before the final `case` in `scripts/spec2pr-forecast.sh`:

```bash
cleanup_forecast() {
  [ "$#" -eq 1 ] || usage
  local run_dir="$1" canonical temp_root
  [ -d "$run_dir" ] || return 0
  canonical="$(cd "$run_dir" 2>/dev/null && pwd -P)" \
    || halt "cannot resolve forecast directory: $run_dir"
  temp_root="$(cd /tmp && pwd -P)"
  case "$canonical" in
    "$temp_root"/spec2pr-forecast.*)
      rm -rf -- "$canonical"
      ;;
    *)
      halt "refusing to clean non-forecast directory: $run_dir"
      ;;
  esac
}
```

Add this final dispatch arm:

```bash
  cleanup)
    shift
    cleanup_forecast "$@"
    ;;
```

- [ ] **Step 6: Verify Task 4**

Run:

```bash
jq -e . settings.json >/dev/null
bash -o pipefail -c 'bash tests/spec2pr/run-tests.sh 2>&1 | tee /tmp/standalone-forecast-task4-green.log'
git diff --check
```

Expected: settings JSON is valid; spec2pr suite ends `N tests run, 0 failed`; diff check is silent.

- [ ] **Step 7: Commit Task 4**

```bash
git add commands/rulez/spec2pr-forecast.md scripts/spec2pr-forecast.sh settings.json tests/spec2pr/test-standalone-forecast.sh
git commit -m "feat: add Claude spec2pr forecast command"
```

---

### Task 5: Add the Codex rulez-tools workflow

**Files:**
- Modify: `adapters/codex/skills/rulez-tools/SKILL.md`
- Modify: `tests/codex/test-setup-codex.sh`

**Interfaces:**
- Produces: `use rulez-tools to forecast <path>`.
- Consumes: shared `prepare` and `evaluate` protocol.
- Agent contract: one `spawn_agent` call with a self-contained prompt and no forked conversation context.

- [ ] **Step 1: Add failing Codex skill contract tests**

Append to `tests/codex/test-setup-codex.sh`:

```bash
test_rulez_tools_skill_documents_standalone_forecast_workflow() {
  local skill_file skill_body skill_description
  skill_file="$REPO_ROOT/adapters/codex/skills/rulez-tools/SKILL.md"
  skill_body="$(cat "$skill_file")"
  skill_description="$(sed -n '3p' "$skill_file")"

  assert_contains "forecasting" "$skill_description" "skill description advertises forecasting"
  assert_contains 'use rulez-tools to forecast <path>' "$skill_body" "skill documents Codex forecast syntax"
  assert_contains 'scripts/spec2pr-forecast.sh prepare' "$skill_body" "Codex delegates preparation"
  assert_contains 'Call `spawn_agent` exactly once' "$skill_body" "Codex launches one forecast agent"
  assert_contains '`fork_turns` set to `none`' "$skill_body" "Codex forecast starts fresh"
  assert_contains 'result.txt' "$skill_body" "Codex saves agent response"
  assert_contains 'scripts/spec2pr-forecast.sh evaluate' "$skill_body" "Codex delegates evaluation"
  assert_contains 'Run `evaluate` even when the subagent fails' "$skill_body" "Codex failure reaches shared evaluator"
  assert_contains 'Do not run external `claude` or `codex` processes' "$skill_body" "Codex forbids external model CLIs"
  assert_contains 'exit 2 as a successful SPLIT forecast' "$skill_body" "Codex interprets split exit"
  assert_contains 'Do not call `spawn_agent` again' "$skill_body" "Codex forbids retries and decomposition agents"
}
```

- [ ] **Step 2: Run Codex tests and verify RED**

Run:

```bash
bash -o pipefail -c 'bash tests/codex/run-tests.sh 2>&1 | tee /tmp/standalone-forecast-task5-red.log'
```

Expected: the new forecast contract assertions fail because the skill has no forecast workflow.

- [ ] **Step 3: Extend the Codex skill description and shared scripts**

Change the frontmatter description to:

```yaml
description: "Use for Rulez shared tooling in Codex: GitHub workflows, standalone spec2pr forecasting, cycle goal watchers, handoffs, and punts backed by this repository's scripts."
```

Add forecasting to the trigger sentence and add this shared-script entry after Cycle prompt:

```markdown
- Forecast protocol: `scripts/spec2pr-forecast.sh prepare <path> <run-dir>` and `scripts/spec2pr-forecast.sh evaluate <run-dir>`
```

- [ ] **Step 4: Add command mapping and the complete Codex workflow**

In Command Mapping, add:

```markdown
When the user says `use rulez-tools to forecast <path>`:

1. Use the `Standalone Forecast` workflow below.
2. Report the shared evaluator's forecast and classification without
   re-estimating or rewriting it.
```

Before `## Cycle Watcher`, add:

```markdown
## Standalone Forecast

Use this workflow when the user says `use rulez-tools to forecast <path>`.
The command itself explicitly authorizes one read-only forecast subagent. It
does not authorize retries, reviewers, implementation agents, or split agents.

1. Parse exactly one path. Reject a missing path, unknown option, or additional
   positional argument with
   `use rulez-tools to forecast <path>`. Preserve paths containing spaces as
   one argument.
2. Resolve `RULEZ_HOME` using the repository-layout rule above. Create one
   temporary directory with `mktemp -d /tmp/spec2pr-forecast.XXXXXX` and
   remember it as `RUN_DIR`.
3. From the target project workspace run
   `bash "$RULEZ_HOME/scripts/spec2pr-forecast.sh" prepare "$PATH" "$RUN_DIR"`.
   If it fails, show its output, remove the owned run directory, and stop
   without calling `spawn_agent`.
4. Read the complete `$RUN_DIR/prompt.txt`. Call `spawn_agent` exactly once
   with `fork_turns` set to `none` and the prompt as the complete task. Wait for
   that subagent to finish. Do not add conversational context or forecast
   requirements.
5. Save the subagent's complete final response verbatim to
   `$RUN_DIR/result.txt`. If dispatch fails or no final response arrives, leave
   the file absent. Run `evaluate` even when the subagent fails.
6. Run
   `bash "$RULEZ_HOME/scripts/spec2pr-forecast.sh" evaluate "$RUN_DIR"` and
   preserve its complete output. Treat exit 2 as a successful SPLIT forecast,
   not as an orchestration failure.
7. Run
   `bash "$RULEZ_HOME/scripts/spec2pr-forecast.sh" cleanup "$RUN_DIR"`. If
   cleanup fails, warn without replacing the evaluator classification.
8. Report the evaluator output. Do not call `spawn_agent` again, implement the
   plan, invoke spec2pr, invoke spec2pr-split, or edit repository files.

Do not run external `claude` or `codex` processes. Do not use a persisted goal.
The shared helper owns discovery, validation, arithmetic, risk, wording, and
exit contracts.
```

- [ ] **Step 5: Verify Task 5**

Run:

```bash
bash -o pipefail -c 'bash tests/codex/run-tests.sh 2>&1 | tee /tmp/standalone-forecast-task5-green.log'
bash -o pipefail -c 'bash tests/spec2pr/run-tests.sh 2>&1 | tee /tmp/standalone-forecast-task5-spec2pr.log'
git diff --check
```

Expected: both suites end `N tests run, 0 failed`; diff check is silent.

- [ ] **Step 6: Commit Task 5**

```bash
git add adapters/codex/skills/rulez-tools/SKILL.md tests/codex/test-setup-codex.sh
git commit -m "feat: add Codex spec2pr forecast workflow"
```

---

### Task 6: Document and smoke-test the complete feature

**Files:**
- Modify: `README.md`
- Modify: `tests/codex/test-setup-codex.sh`

**Interfaces:**
- Documents: both public commands, one-agent behavior, companion discovery, risk bands, split output, and automatic-pipeline distinction.
- Verifies: one real Codex subagent can consume the generated prompt and produce an evaluator-accepted result without repository changes.

- [ ] **Step 1: Add failing README contract tests**

Append to `tests/codex/test-setup-codex.sh`:

```bash
test_readme_documents_standalone_spec2pr_forecast() {
  local readme
  readme="$(cat "$REPO_ROOT/README.md")"

  assert_contains "use rulez-tools to forecast docs/superpowers/specs/foo-design.md" "$readme" "README shows Codex forecast"
  assert_contains "/rulez:spec2pr-forecast docs/superpowers/plans/foo-design-plan.md" "$readme" "README shows Claude forecast"
  assert_contains "one native subagent from the current tool" "$readme" "README explains current-tool agent"
  assert_contains "80%" "$readme" "README documents warning boundary"
  assert_contains "SPEC2PR SPLIT forecast est=" "$readme" "README documents split contract"
  assert_contains "does not replace spec2pr's automatic Claude-backed forecast" "$readme" "README distinguishes pipeline forecast"
  assert_contains "standalone spec2pr forecasting" "$readme" "Codex capability list includes forecast"
  assert_contains "`/rulez:spec2pr-forecast <path>`" "$readme" "Claude command table includes forecast"
}
```

- [ ] **Step 2: Run Codex tests and verify RED**

Run:

```bash
bash -o pipefail -c 'bash tests/codex/run-tests.sh 2>&1 | tee /tmp/standalone-forecast-task6-red.log'
```

Expected: README-specific assertions fail while the Codex skill assertions stay green.

- [ ] **Step 3: Update README command surfaces**

Add this line to the Codex example block near the top:

```text
use rulez-tools to forecast docs/superpowers/specs/foo-design.md
```

Change both Codex capability lists to include `standalone spec2pr forecasting`.

Add this row to the Claude Commands table:

```markdown
| `/rulez:spec2pr-forecast <path>` | Forecast implementation size from a spec or plan with one native Claude Agent |
```

Immediately after the `## spec2pr & review-pr` introduction, add:

````markdown
### Standalone size forecast

Forecast before starting the pipeline when a draft spec or plan may be too
large:

```text
use rulez-tools to forecast docs/superpowers/specs/foo-design.md
/rulez:spec2pr-forecast docs/superpowers/plans/foo-design-plan.md
```

Both commands use one native subagent from the current tool. They automatically
include the conventional companion plan or spec when present, but one readable
artifact is enough. The estimate uses the same 40-bytes-per-line conversion and
128 KiB implementation limit as spec2pr. Below 80% reports `OK`; 80% through
100% reports a non-terminal near-limit warning; above the limit ends with
`SPEC2PR SPLIT forecast est=<n> limit=<n>` and an advisory 2-4 part outline.

This standalone command is read-only and does not run, cache, or split the
implementation. It does not replace spec2pr's automatic Claude-backed forecast;
that pipeline step still runs before a new implementation and keeps its existing
cache and fail-soft behavior.
````

Keep the nested command example fenced correctly: the outer README section is
normal Markdown, not wrapped in another fence.

- [ ] **Step 4: Run all automated verification**

Run:

```bash
bash -n scripts/spec2pr-forecast.sh scripts/spec2pr.sh scripts/lib/spec2pr-runtime.sh
jq -e . settings.json >/dev/null
bash -o pipefail -c 'bash tests/spec2pr/run-tests.sh 2>&1 | tee /tmp/standalone-forecast-final-spec2pr.log'
bash -o pipefail -c 'bash tests/codex/run-tests.sh 2>&1 | tee /tmp/standalone-forecast-final-codex.log'
git diff --check
git status --short
```

Expected:

- Bash syntax checks exit 0.
- `settings.json` parses.
- Both test suites end `N tests run, 0 failed`.
- `git diff --check` prints nothing.
- Status contains only the intended Task 6 files plus any explicitly preserved pre-existing untracked files.

- [ ] **Step 5: Run one live Codex-subagent smoke in a disposable repository**

Create a disposable repository outside the feature worktree:

```bash
SMOKE_REPO="$(mktemp -d -t spec2pr-forecast-smoke.XXXXXX)"
git -C "$SMOKE_REPO" init -q -b main
git -C "$SMOKE_REPO" config user.email smoke@example.com
git -C "$SMOKE_REPO" config user.name "Forecast Smoke"
mkdir -p "$SMOKE_REPO/docs/superpowers/specs" "$SMOKE_REPO/src"
printf '# Smoke project\n' > "$SMOKE_REPO/README.md"
printf 'export const value = 1;\n' > "$SMOKE_REPO/src/value.ts"
printf '# Small change\n\nAdd a --version output and one focused test.\n' \
  > "$SMOKE_REPO/docs/superpowers/specs/small-design.md"
git -C "$SMOKE_REPO" add -A
git -C "$SMOKE_REPO" commit -qm init
SMOKE_RUN="$(mktemp -d /tmp/spec2pr-forecast.XXXXXX)"
(cd "$SMOKE_REPO" && bash "$OLDPWD/scripts/spec2pr-forecast.sh" prepare \
  docs/superpowers/specs/small-design.md "$SMOKE_RUN")
```

Then use the current Codex tool's `spawn_agent` exactly once with
`fork_turns: "none"` and the exact contents of `$SMOKE_RUN/prompt.txt`. Save
its final response verbatim to `$SMOKE_RUN/result.txt`, then run:

```bash
(cd "$SMOKE_REPO" && bash "$OLDPWD/scripts/spec2pr-forecast.sh" evaluate "$SMOKE_RUN")
git -C "$SMOKE_REPO" status --short
```

Expected: evaluator exits 0 with `SPEC2PR OK forecast:` or
`SPEC2PR WARN forecast:` as its final line; exactly one subagent was dispatched;
`git status --short` prints nothing. If the model returns an over-limit estimate
for this intentionally small spec, record the output and treat that as a smoke
failure requiring prompt correction before proceeding.

After recording the result, remove only the two disposable directories:

```bash
rm -rf "$SMOKE_RUN" "$SMOKE_REPO"
```

- [ ] **Step 6: Commit Task 6**

```bash
git add README.md tests/codex/test-setup-codex.sh
git commit -m "docs: explain standalone spec2pr forecasts"
```

- [ ] **Step 7: Final scope and regression audit**

Run:

```bash
git diff --stat 74ac94d..HEAD
git diff --name-only 74ac94d..HEAD
git log --oneline 74ac94d..HEAD
git status --short --branch
```

Expected changed implementation files only:

```text
README.md
adapters/codex/skills/rulez-tools/SKILL.md
commands/rulez/spec2pr-forecast.md
scripts/spec2pr-forecast.sh
settings.json
tests/codex/test-setup-codex.sh
tests/spec2pr/test-standalone-forecast.sh
```

The design and this plan are already committed before the implementation range.
Confirm `scripts/spec2pr.sh`, `scripts/lib/spec2pr-runtime.sh`,
`tests/spec2pr/test-forecast.sh`, `VERSION`, and `UPGRADE.md` do not appear.

---

## Final Review Gate

After all tasks pass, invoke `superpowers:requesting-code-review` against the
full implementation range `74ac94d..HEAD`. The reviewer must verify:

- one native agent per public invocation;
- no external model CLI or automatic pipeline call;
- unchanged repository and artifact enforcement without rollback;
- deterministic 40-byte conversion, 128 KiB default limit, and exact 80%
  warning boundary;
- exact terminal contracts and exit codes;
- valid 2-4 part decomposition only for over-limit estimates;
- existing automatic forecast code and release metadata remain untouched;
- both suites and the live smoke evidence are green.

Address any blocker or major finding, rerun both full suites, and repeat review
until the reviewer reports no blocker or major findings.
