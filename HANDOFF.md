# Handoff

## Task
The statusline's context-meter chip displayed a percentage that did not match `/context` — e.g., a session at 149k tokens rendered "15%" while `/context` reported "37%". User asked to investigate, fix so the meter tracks auto-compact proximity (the signal users actually want), and ship as a formal release. Initial guess: recompute against the 400k auto-compact threshold; if no clean way, multiply upstream's percentage by 2.5 (the 1M:400k ratio).

## Current State
- **Branch:** `main`, synced with `origin/main`.
- **Released as v1.1.4.** Global install at `~/.claude/skills/rulez-claudeset/` is at v1.1.4, setup re-run, clean.
- **Commits pushed this session (newest first):**
  - `5b732ee chore: release v1.1.4`
  - `ab86ed8 fix: context meter percentage tracks auto-compact threshold`
- **Files modified:**
  - `scripts/statusline.sh` — replaced the single-line `ctx_pct` extraction with a multi-branch jq pipeline that reads `.context_window.current_usage` raw token fields, sums them, and divides against a threshold of 400000 on 1M models or `context_window_size` otherwise. Adds the `used_percentage * 2.5` fallback when `current_usage` is null on 1M models, and finally falls through to upstream's raw percentage on non-1M models with no current_usage.
  - `VERSION` — `1.1.3` → `1.1.4`.
  - `UPGRADE.md` — new `## To v1.1.4 — from v1.1.3` section at top documenting the fix and the fallback chain.
- **Untracked:** `tmp/` (per repo convention).

## What Worked

**Root-cause investigation (web research first, this time).**
- Diagnosed the discrepancy by inspecting the `/context` output the user pasted: `149k/400k tokens (37%)` and `Auto-compact window: 400k tokens`. Math confirmed: 149k/1M ≈ 15% (statusline), 149k/400k ≈ 37% (`/context`). The bar wasn't lying — it was just using the upstream `.context_window.used_percentage` denominator (full 1M window) when the user wanted the auto-compact denominator (400k).
- Two parallel research paths, both via Explore subagents:
  1. **Schema dive** — WebFetched [Claude Code statusline docs](https://code.claude.com/docs/en/statusline) and confirmed the `context_window` object exposes `context_window_size`, `used_percentage`, `remaining_percentage`, `total_input_tokens`, `total_output_tokens`, and `current_usage.{input_tokens, cache_creation_input_tokens, cache_read_input_tokens, output_tokens}`. So raw tokens are available — no need to scrape transcripts.
  2. **Community survey** — found multiple battle-tested implementations (notably the [GGPrompts gist](https://gist.github.com/GGPrompts/8125321d4cd462da19769b04f43ee70a)) that all agreed on the canonical "input tokens" sum: `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` (excluding `output_tokens`, which matches what upstream's own `used_percentage` is calculated from per the docs).
- Confirmed via [claude-code#43989](https://github.com/anthropics/claude-code/issues/43989) that the 400k auto-compact threshold on 1M models is set internally by Claude Code (regression introduced in v2.1.92), not exposed in the JSON, and applies universally to 1M models — so hardcoding 400000 for 1M and `context_window_size` otherwise is the right call.

**The fix (`scripts/statusline.sh`).**
Single multi-branch jq pipeline replacing the original `ctx_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')`:
```jq
(.context_window // {}) as $cw
| ($cw.context_window_size // 0) as $size
| (if $size >= 1000000 then 400000 else $size end) as $threshold
| $cw.current_usage as $u
| if ($u != null) and ($threshold > 0) then
    ((($u.input_tokens // 0)
      + ($u.cache_creation_input_tokens // 0)
      + ($u.cache_read_input_tokens // 0)) * 100 / $threshold) | floor
  elif ($cw.used_percentage // null) != null and $size >= 1000000 then
    ($cw.used_percentage * 2.5) | floor
  else
    $cw.used_percentage // empty
  end
```
Three precedence levels: (1) raw-token recompute when `current_usage` is populated; (2) `used_percentage × 2.5` when `current_usage` is null but the model is 1M (covers the pre-first-API-call window); (3) raw upstream `used_percentage` on non-1M models (no oversized reservation, so the bar already reflects what users want). Empty/missing context_window → empty `ctx_pct` → meter not rendered (existing behavior).

**Testing.**
Wrote 4 synthetic JSON cases against `bash scripts/statusline.sh`:
1. 1M model + populated `current_usage` summing to 149k → **37%** ✓
2. 1M model + `current_usage: null` + `used_percentage: 15` → **37%** (15 × 2.5) ✓
3. 200k model + `current_usage` summing to 50k → **25%** (50k/200k) ✓
4. `context_window: {}` → no meter rendered ✓
All passed on first run.

**Release.**
- Two-commit release pattern (same as v1.1.3): `ab86ed8` is the isolated behavior change (`scripts/statusline.sh` only); `5b732ee` is `VERSION` + `UPGRADE.md` only. Easy to bisect, easy to revert the fix without touching docs.
- `git commit -F /tmp/cc-commit-msg-*.txt` to bypass the heredoc-shell-quoting bug that bit again on the first commit attempt (backticks/asterisks in commit body trip up bash heredoc when chained with `&&`).
- `/rulez:update-claudeset` already pulled v1.1.4 cleanly into the global install — no "modified" friction this time because we did NOT mirror via `cp` mid-session.

## What Didn't Work

- **First commit attempt with `git commit -m "$(cat <<'EOF' ... EOF)"`** failed with `unexpected EOF while looking for matching '`. Same shell-quoting bug as the v1.1.3 session. Switched to `git commit -F /tmp/cc-commit-msg-fix.txt` (and the same for the release commit) — both via the Write tool to dodge any quoting issues entirely. Pattern is now established as the default for non-trivial commit messages in this repo.
- **None of the community implementations surveyed used 400k as a denominator** — they all divide by `context_window_size`. So the divisor switch (`>= 1000000 ? 400000 : $size`) is original to this fix, not copied from a battle-tested project. The math is sound (matches `/context`'s output exactly), but it's worth flagging that we're ahead of community practice on this specific point — if upstream changes the auto-compact behavior, this fix will need updating before the community catches up.

## Next Steps

Ordered by priority.

1. **Live-verify the chip in this session.** Run `/context` and check the statusline within ~1 minute — they should agree within ±1%. Synthetic tests passed but eyeball confirmation against real upstream JSON is still pending.
2. **Carryovers from prior sessions, still outstanding:**
   - **Add failure marker to `bin/auto-update.sh`** — on `fetch` or `pull --ff-only` failure, write `"auto-update failed: <reason>"` to `$MARKER_FILE` so silent skips become visible next session.
   - **Harden `scripts/set-current-command.sh`** — prepend `mkdir -p .claude` before the redirect. One-liner.
   - **Smoke-test `/rulez:todo` end-to-end** in a real session (`/rulez:todo buy milk` → `ls` → `done 1` → `archive`).
   - **Smoke-test `/effort max` chip rendering** (carried from v1.1.3 session) — type `/effort max` and confirm the magenta `MAX` chip appears between model and session time.
3. **Watch upstream [claude-code#43989](https://github.com/anthropics/claude-code/issues/43989).** If Claude Code starts exposing `auto_compact_threshold` (or similar) in the statusLine JSON, switch to reading it dynamically and remove the hardcoded `400000` constant.
4. **Watch upstream [claude-code#11819](https://github.com/anthropics/claude-code/issues/11819).** If `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` becomes a stable knob, honor it in the statusline (read the env var and use it instead of 400k).

## Key Decisions

- **Hardcode 400000 for 1M models, fall through to `context_window_size` otherwise.** Auto-compact threshold isn't exposed in JSON, so we'd otherwise have to either guess or read an undocumented config. The 400k figure is well-attested in claude-code#43989. For 200k models, there's no oversized reservation, so dividing by the full window is correct — and the threshold-switch keeps the formula model-agnostic without per-model lookup tables.
- **Three-tier fallback chain (raw tokens → `used_percentage × 2.5` → raw `used_percentage`).** The 2.5x trick is mathematically equivalent to the raw-token path for 1M models (since `used_percentage` is itself computed from the same input tokens, just divided by 1M), so it's a clean fallback when `current_usage` is null in the brief pre-first-API-call window. The third tier (raw `used_percentage`) only fires for non-1M models where the meter doesn't need the threshold rescale anyway — keeps the behavior strictly additive for that case.
- **No changes to `scripts/context-meter.sh`.** It already clamps 0–100 and applies threshold colors. Pushing the recompute responsibility into `statusline.sh` (the data-extraction layer) keeps `context-meter.sh` purely about rendering — clean separation of concerns.
- **Two-commit release (`fix:` + `chore:`) instead of one bundled commit.** Mirrors v1.1.3 pattern. `ab86ed8` is the isolated behavior change (revertable without touching VERSION/UPGRADE.md churn); `5b732ee` is the docs/version pin. Bisect-friendly.
- **Did NOT mirror the fix to the global install via `cp` before pushing.** v1.1.3 session got bitten by this — the global clone ended up "modified" against its HEAD, requiring `git checkout --` to resolve before `pull --ff-only` would work. This time, push first, then `/rulez:update-claudeset` — clean pull every time. Worth canonicalizing as the standard dev-loop for this repo.
- **Used Write-to-tempfile + `git commit -F` for both commits.** The heredoc/`-m` approach has now failed twice in a row on this repo (commit messages contain markdown that confuses bash). Pattern is locked in: write the message via the Write tool, commit with `-F`. No ceremony, always works.
- **Did NOT honor `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` (deferred).** It's a niche power-user knob and there's no strong signal that it's stable upstream. Adding it would mean reading the env var and recomputing the threshold — easy to bolt on later if the issue gains traction.
- **Did NOT subtract the 33k autocompact reserved buffer (deferred).** `/context` shows it as a separate slice ("Autocompact buffer: 33k"). Subtracting it would shift "100% on the meter" from "compaction soon" to "compaction now" — adds noise without much signal. Easy to add as a polish later if the user actually wants the more aggressive read.
