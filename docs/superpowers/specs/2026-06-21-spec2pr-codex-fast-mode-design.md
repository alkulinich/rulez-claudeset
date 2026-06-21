# spec2pr/review-pr: Codex fast mode for implementation and fix calls

## Context

`spec2pr.sh` and `review-pr.sh` run unattended pipelines that call Codex and
Claude through the shared runtime in `scripts/lib/spec2pr-runtime.sh`.

All Codex subprocesses currently pass through one helper:

```bash
codex_call <role> <tag> <prompt-file>
```

The `role` maps to the output schema and already distinguishes review-style
Codex calls from code-changing Codex calls:

- `review` - used when Codex reviews an artifact or PR diff.
- `plan` - used when Codex writes a plan in older/current topology branches.
- `implement` - used when Codex implements the spec2pr plan.
- `pr-fix` - used when Codex fixes PR-review findings.

The Codex speed docs describe Fast mode as a higher-credit service tier for
supported Codex models, available when Codex is signed in with ChatGPT. The docs
state it can be enabled persistently with:

```toml
service_tier = "fast"

[features]
fast_mode = true
```

The installed `codex exec --help` supports per-invocation config overrides via
`-c/--config` and feature toggles via `--enable`, so the pipeline can opt in for
specific subprocesses without changing the user's global Codex config.

## Goal

Add an opt-in fast mode for Codex calls in the spec2pr family:

- `spec2pr.sh --fast <spec.md>`
- `review-pr.sh --fast [--reviewer <claude|codex>] <pr-number|pr-url>`
- `mctl add --fast spec2pr <spec.md>`
- `mctl add --fast review-pr <pr-number|pr-url>`

Fast mode is off by default. When enabled, it applies only to Codex roles that
change implementation code: `implement` and `pr-fix`.

## Non-goals

- Do not speed up Codex review, plan, classifier, or other quality-gate calls.
- Do not change Claude calls.
- Do not change the default behavior of existing commands.
- Do not persist anything to `~/.codex/config.toml`.
- Do not introduce per-role user configuration beyond the single `--fast` flag.

## Behavior

When fast mode is disabled, `codex_call` produces the exact current Codex command
shape.

When fast mode is enabled:

- `codex_call implement ...` adds:

  ```bash
  --enable fast_mode -c 'service_tier="fast"'
  ```

- `codex_call pr-fix ...` adds the same arguments.
- `codex_call review ...` does not add fast-mode arguments.
- `codex_call plan ...` does not add fast-mode arguments.

This keeps correctness checks at standard speed/quality while accelerating the
expensive code-changing steps where unused Codex fast credits are most useful.

## CLI surface

### `scripts/spec2pr.sh`

Replace the current single-argument check with a small parser:

```text
usage: spec2pr.sh [--fast] <spec-path>
```

Rules:

- Accept `--fast` before or after the spec path.
- Require exactly one spec path.
- Reject unknown flags.
- Set a shared runtime variable, for example `SPEC2PR_CODEX_FAST=1`, before any
  Codex calls run.

### `scripts/review-pr.sh`

Extend the existing parser:

```text
usage: review-pr.sh [--fast] [--reviewer <claude|codex>] <pr-number|pr-url>
```

Rules:

- Accept `--fast` in any position.
- Keep the existing `--reviewer <claude|codex>` behavior unchanged.
- Require exactly one PR ref.
- Reject unknown flags.
- Set the same shared runtime variable before `pr_review_engine_run`.

### `scripts/mctl.sh`

Add `--fast` to the `mctl add` path for `spec2pr` and `review-pr` jobs.

Examples:

```bash
mctl add --fast spec2pr docs/superpowers/specs/my-feature.md
mctl add --fast review-pr 42
```

`mctl` should persist the flag as part of the queued command arguments so a
restart or later worker execution preserves the user's choice. Existing queued
jobs without `--fast` keep standard behavior.

## Runtime implementation

Add a runtime default in `scripts/lib/spec2pr-runtime.sh`:

```bash
SPEC2PR_CODEX_FAST="${SPEC2PR_CODEX_FAST:-}"
```

Add a helper that returns the optional extra Codex arguments for a role:

```bash
codex_fast_args_for_role() {
  local role="$1"
  [ -n "$SPEC2PR_CODEX_FAST" ] || return 0
  case "$role" in
    implement|pr-fix)
      printf '%s\n' "--enable" "fast_mode" "-c" 'service_tier="fast"'
      ;;
  esac
}
```

Use an array inside `codex_call` so arguments with quotes are not re-parsed by
the shell:

```bash
local codex_args=()
while IFS= read -r arg; do
  codex_args+=("$arg")
done < <(codex_fast_args_for_role "$role")

"$SPEC2PR_CODEX_BIN" exec "${codex_args[@]}" --cd "$WORKTREE" ...
```

The exact helper shape may differ, but the implementation must preserve safe
shell quoting and must not build the Codex command through `eval`.

## Visibility

The existing progress line should show when a code-changing Codex call is using
fast mode, without changing parse-critical stdout contracts.

Recommended stderr/progress text:

```text
running codex implement fast
running codex pr-review-r1.fix fast
```

Status files should not grow new fields solely for fast mode. The existing
prompt, stdout, stderr, and JSON artifacts remain in the same locations.

## Error handling

If a user's Codex installation does not support `--enable fast_mode` or
`service_tier`, the affected Codex subprocess should fail normally and the
pipeline should HALT with the existing stderr path:

```text
SPEC2PR HALT implement: codex implement failed (stderr: ...)
PRREVIEW HALT pr-review: codex pr-review-r1.fix failed (stderr: ...)
```

There is no silent fallback to standard mode. A silent fallback would make the
`--fast` flag hard to trust.

If the user is authenticated with an API key rather than ChatGPT, Codex may not
apply Fast mode credits according to the official docs. The pipeline does not
try to detect this; it passes the requested Codex configuration and lets Codex
report any unsupported mode or account behavior.

## Testing

Add focused shell tests under `tests/spec2pr`:

- `spec2pr.sh --fast <spec>` records fast-mode args only on the implementation
  Codex invocation.
- `spec2pr.sh <spec> --fast` is accepted.
- Default `spec2pr.sh <spec>` records no fast-mode args.
- `review-pr.sh --fast <pr>` records fast-mode args on Codex fixer invocations
  when the fixer is Codex.
- `review-pr.sh --fast --reviewer codex <pr>` records no fast-mode args if the
  fixer is Claude and Codex is only reviewing.
- `mctl add --fast spec2pr ...` and `mctl add --fast review-pr ...` preserve the
  flag in the queued command.

The existing `stub-codex.sh` invocation log should be extended only as needed to
assert the exact arguments sent to `codex exec`.

## Documentation

Update the `README.md` `spec2pr & review-pr` section with:

- A short note that `--fast` spends Codex Fast mode credits on implementation and
  fixer calls only.
- Examples for direct scripts and `mctl`.
- A caveat that Codex Fast mode depends on Codex account support and does not
  apply to Claude calls.

