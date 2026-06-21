# Handoff

## Task
Implemented, reviewed, PR'd, and merged the opt-in Codex Fast mode for the
spec2pr family.

## Current State
- Branch: `main`.
- PR #15 merged: https://github.com/alkulinich/rulez-claudeset/pull/15
- Merge commit: `482626e Merge pull request #15 from alkulinich/feat/spec2pr-codex-fast-mode`.
- Local checkout was switched back to `main` by `scripts/git-merge-pr.sh 15`.
- Tracked tree is clean. Three untracked protected paths remain; see the
  protected section below.

## What Changed
- Added `--fast` to `scripts/spec2pr.sh`.
- Added `--fast` to `scripts/review-pr.sh`, alongside the existing
  `--reviewer <claude|codex>` option.
- Added `--fast` support to `scripts/mctl.sh` for detached `spec2pr` and
  `review-pr` runs.
- Centralized Codex Fast mode gating in `scripts/lib/spec2pr-runtime.sh`.
- Extended tests in `tests/spec2pr/` and `tests/mctl/test-add.sh`.
- Documented direct and `mctl` usage in `README.md`.

## Behavior Now
- `--fast` is off by default.
- When enabled, Codex receives:

```text
--enable fast_mode -c 'service_tier="fast"'
```

- Fast mode is applied only to code-changing Codex roles:
  - `implement`
  - `pr-fix`
- Fast mode is not applied to review, planning, classification, or any Claude
  call.
- Supported forms:

```bash
scripts/spec2pr.sh --fast docs/superpowers/specs/feature-a.md
scripts/spec2pr.sh docs/superpowers/specs/feature-a.md --fast
scripts/review-pr.sh --fast 15
scripts/review-pr.sh --fast --reviewer codex 15
mctl add --fast spec2pr docs/superpowers/specs/feature-a.md
mctl add spec2pr docs/superpowers/specs/feature-a.md --fast
mctl add --fast review-pr 15
```

## Verification Run
- `bash tests/spec2pr/run-tests.sh` passed: `420 tests run, 0 failed`.
- `bash -n scripts/lib/spec2pr-runtime.sh scripts/spec2pr.sh scripts/review-pr.sh scripts/mctl.sh tests/spec2pr/stub-codex.sh tests/spec2pr/test-harness.sh tests/spec2pr/test-stages.sh tests/spec2pr/test-review-pr.sh tests/spec2pr/test-preflight.sh tests/mctl/test-add.sh` passed.
- `git diff --check main..HEAD` passed before PR creation.
- Final whole-branch subagent code review approved.

## Known Issues
- `bash tests/mctl/run-tests.sh` still fails with `175 tests run, 6 failed`.
- The new fast-mode mctl tests passed.
- The six failures match known unrelated baseline/environment failures:
  - `/var` vs `/private/var` path expectations on macOS.
  - Linux-vs-Darwin `script` wrapper expectation.
  - Dashboard/fzf PATH/`dirname` failure cases.

## Notes For Next Session
- If testing `mctl`, account for the existing six unrelated failures before
  judging new failures.
- `gh` in this Codex tool environment reported an invalid token, but pushing via
  git SSH worked and the GitHub connector successfully created PR #15.
- PR #15 was created as draft and `scripts/git-merge-pr.sh 15` merged it
  successfully.
- `review-pr.sh` reviewer switching reminder:

```bash
scripts/review-pr.sh --reviewer codex 15
scripts/review-pr.sh --fast --reviewer codex 15
```

## Protected - DO NOT touch / commit
These untracked paths are intentionally excluded from all commits:
- `tmp/`
- `references/`
- `docs/research-auto-handoff-at-context-threshold.md`
