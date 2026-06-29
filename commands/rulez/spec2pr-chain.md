# Spec2PR Chain

Run several brainstormed specs in dependency order, squash-merging each PR
before the next spec starts, so each spec branches off a `main` that already
contains its predecessors. A spec that does not reach DONE, or a PR that does
not merge cleanly, stops the chain.

## Usage

- `/rulez:spec2pr-chain <spec…>` — run the ordered list of specs
- `/rulez:spec2pr-chain --fast <spec…>` — forward `--fast` to each spec2pr run
- `/rulez:spec2pr-chain status` — show the latest state of every chain

## Instructions

If the argument is `status`:

1. Run:
   `bash ~/.claude/skills/rulez-claudeset/scripts/spec2pr-chain.sh status`
2. Present the result as-is. Stop.

Otherwise:

1. Parse an optional leading `--fast` flag; everything after it is the ordered
   spec list. Require at least one spec path.
2. If any spec file does not exist, tell the user and stop.
3. Launch the orchestrator as one **background** Bash task (single call,
   `run_in_background: true`), the same pattern `/rulez:spec2pr` uses:
   `bash ~/.claude/skills/rulez-claudeset/scripts/spec2pr-chain.sh [--fast] <spec…>`
   If `--fast` was not supplied, omit it. The orchestrator supports Bash 3.2+
   so macOS system Bash is valid.
4. Tell the user the chain has started, that a completion notification will
   arrive in this session, and that `/rulez:spec2pr-chain status` shows
   progress meanwhile. Do not poll.

When the background task completes, read the last `CHAIN` line of its output
and react:

- `CHAIN DONE merged=<n>/<total>` — every spec merged; report the count.
- `CHAIN HALT <slug>: <reason>` — the chain stopped at `<slug>`. Earlier specs
  stayed merged; show the reason. If `<reason>` is a forwarded `SPEC2PR DIRTY`
  or `SPEC2PR HALT` line, treat it like the matching `/rulez:spec2pr` outcome
  for that one spec, then re-run `/rulez:spec2pr-chain [--fast] <spec…>` with
  the original flags to resume past the specs already merged. If `<reason>` is
  a forwarded `SPEC2PR SPLIT` line, split or replace the offending spec in the
  ordered list, or otherwise resolve the split condition, then re-run
  `/rulez:spec2pr-chain [--fast] <updated-spec…>` with the original flags;
  already-merged predecessors will be skipped.
- `CHAIN HALT: <reason>` (no slug — preflight or lock) — fix the invocation
  (same repo, no duplicate IDs, no other chain running) and re-run.
