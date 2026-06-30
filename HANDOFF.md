# Handoff

## Task
Several threads in one session, all around spec2pr/spec2pr-chain dogfooding:
1. Merge PR #25 (spec2pr-chain **part-2**) — `/rulez:merge-pr 25`.
2. Brainstorm + spec a new feature: `spec2pr --implementer codex|claude[:sonnet]`.
3. Split that spec into two sequential sub-specs and publish them.
4. Run the chain on the dogfood server; diagnose its "hang".
5. Fix the chain so it streams spec2pr output live (the `tee` hotfix).

## Current State
On `main`, **`HEAD == origin/main == 3e4058e`** (in sync). `VERSION` is `1.10.1`.

- **PR #25 merged** at `19499d0` (VERSION 1.10.0 → 1.10.1), remote branch deleted,
  suite **834/0**, global install refreshed to 1.10.1.
- **`3e4058e`** is the `tee` hotfix (`scripts/spec2pr-chain.sh` only). Pushed to
  origin/main. Suite re-verified **834/0** with the change in.
- **Two part specs are on main** (published at `0f0b2b1`):
  `docs/superpowers/specs/2026-06-30-spec2pr-implementer-switch-part-1-design.md`
  and `…-part-2-design.md`. The feature itself is **NOT implemented yet** — see below.
- **A chain is RUNNING on the dogfood server** (`ssh rulez@dogfood`, passwordless)
  building those two parts: `spec2pr-chain.sh …part-1… …part-2…`. Last observed at
  **part-1, plan stage**, after **7 spec-review rounds**. It is executing the
  **old (pre-`tee`) installed copy**, so its terminal stays silent until each spec
  finishes; that is expected, not a hang.
- Working tree: only untracked **protected** paths remain (`references/`, `tmp/`,
  `docs/research-auto-handoff-at-context-threshold.md`,
  `docs/superpowers/specs/2026-06-29-spec2pr-chain-design.md`,
  `docs/superpowers/specs/2026-06-30-spec2pr-implementer-switch-design.md` — the
  un-split original). **Do not stage/commit these.**

## What Worked
1. **`/rulez:merge-pr 25`** — clean this time (no version collision; part-2 correctly
   bumped 1.10.0→1.10.1). `git-merge-pr.sh 25 merge`, then manually deleted the remote
   branch (`--merge` doesn't `--delete-branch`). Suite 834/0. Install refreshed.
2. **Brainstormed the `--implementer` feature** and wrote the design to
   `…implementer-switch-design.md`. Settled: agent switch `codex|claude` + optional
   model tier `claude:sonnet` (tier on the **implement call only**); pr-review reviewer
   = **opposite agent**; `spec2pr.sh` only (NOT mctl/chain); strict allowlist
   `codex|claude|claude:sonnet` (haiku/opus dropped as YAGNI).
3. **`/rulez:spec2pr-split`** on that spec (gate defaulted to `spec` — no SPLIT
   evidence; a deliberate decomposition, not size-forced). Produced part-1 (agent
   switch) and part-2 (model tier), each < 32 KB, with the mandated "part-1 is already
   merged…" prose in part-2. User published both via `git-publish-spec.sh` → `0f0b2b1`.
4. **Diagnosed the chain "hang"** as `spec2pr-chain.sh:443/445` capturing output in a
   command substitution (`spec_out="$(… 2>&1)"`). Confirmed the run was alive via a
   read-only SSH check (chain PID present, `claude -p` running, meta files advancing).
5. **`tee` hotfix** (`3e4058e`): replaced the command substitution with
   `bash spec2pr.sh … | tee "$spec_log"`, `spec_rc=${PIPESTATUS[0]}`, then
   `spec_out="$(cat "$spec_log")"`. Suite 834/0. Committed + pushed to origin/main.

## What Didn't Work
- **No real dead ends.** The chain "hang" was a false alarm (capture, not a stall).
- Considered `script(1)` (the user's `references/script-backed-output-capture/` idea)
  but rejected it: `status()`/`progress()` are plain `printf` (not tty-gated, see
  `spec2pr-runtime.sh:46-58`), so `tee` streams them live AND avoids the util-linux vs
  BSD `script` syntax split that would diverge between the dogfood box and the macOS
  test suite.

## Next Steps
1. **Watch the running dogfood chain.** It auto-merges part-1's PR, then builds part-2
   on top. **Risk:** `MAX_FIX_ROUNDS` is **8** on dogfood and part-1 already used **7**
   spec-review rounds — one shy of a `DIRTY` halt. If any spec hits 8 still-dirty,
   `spec2pr` exits 3 → the chain `CHAIN HALT`s at that spec and stops (remaining specs
   unprocessed); publish-on-halt pushes the refined spec to main. Recovery: re-run the
   same chain command (merged specs skipped via `.merged` marker; halted spec resumes
   its worktree), but a blind re-run usually re-DIRTYs the same findings — read
   `spec-review-r8.json`, hand-tighten, or raise `MAX_FIX_ROUNDS`.
2. **When the chain finishes**, the `--implementer` feature lands on main
   (VERSION → 1.11.0 then 1.11.1). Review/verify the two PRs' diffs against the specs.
3. **(Offered, awaiting answer)** Refresh the **local** global install for the `tee`
   fix now: `git -C ~/.claude/skills/rulez-claudeset pull --ff-only origin main && \
   ~/.claude/skills/rulez-claudeset/bin/setup -q`. Otherwise auto-update handles it.
4. **(Optional, not started) Phase 2 of live output:** stream codex/claude **stderr**
   live during the long implement/review stages (those go to `$err` files today). More
   invasive — touches every `codex_call`/`claude` invocation in `spec2pr.sh`; gate
   behind `SPEC2PR_VERBOSE` or a flag. Without it, the `tee` fix shows stage-boundary
   lines but still goes quiet *during* a long codex/claude call.

## Key Decisions
- **`tee`, not `script`.** spec2pr narration is plain `printf` (not tty-gated), so a
  pty buys nothing; `tee` is portable and dodges the macOS/Linux `script` syntax trap.
  Exit code via `${PIPESTATUS[0]}` so `tee` can't mask a halt.
- **The hotfix deliberately does NOT bump `VERSION`/`UPGRADE.md`.** The in-flight part
  branches DO touch those files (1.10.1→1.11.0→1.11.1); editing them in the hotfix would
  recreate the PR #24 version-collision at merge time. Scoping to `spec2pr-chain.sh`
  only (a file the part specs don't touch) keeps it conflict-free with the running chain.
- **Implementer-switch decomposition (agent → model seam).** part-1 = agent switch +
  the **claude-implement adapter** (Claude CLI has no `--output-schema`, so it's
  *prompted* to emit `{status,summary,blocked_reason}` JSON which the orchestrator
  re-parses — mirrors the forecast stage at `spec2pr.sh:528-532`) + reviewer-opposite.
  part-2 = `claude:sonnet` tier + `--model` plumbing into `claude_json_attempt`.
- **`MAX_FIX_ROUNDS` is the single global cap** for ALL review loops (spec-review,
  plan-review, pr-review, standalone review-pr); `spec2pr-runtime.sh:20`, default 3,
  **8 on dogfood**. Distinct from the `SPEC2PR_MAX_SPEC/PLAN/DIFF` byte size-gates
  (those trigger `SPLIT`, not rounds).
