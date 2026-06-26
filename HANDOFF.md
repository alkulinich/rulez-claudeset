# Handoff

## Task
Make `scripts/git-publish-spec.sh` usable the way it's meant to be: run from a
repo's root on `main`, pass it spec/plan paths that live in a **worktree**
(e.g. `~/.worktrees/<branch>/docs/superpowers/specs/...`), have it copy those
files into the repo, then commit + push to `origin/main`. Previously it died
with `path is outside docs/superpowers/specs or docs/superpowers/plans` because
it anchored its scope check to the current repo root.

## Current State
Done and merged. On `main`, in sync with `origin/main`. Tracked tree clean.

- PR #18 (`feat(spec2pr): copy worktree spec/plan paths into repo on publish`)
  created and merged via `/rulez:merge-pr 18`; feature branch
  `feature/publish-spec-worktree-paths` deleted, remotes pruned.
- VERSION is now `1.7.1`.

## What Worked
Files changed (all merged to `main`):
- `scripts/git-publish-spec.sh` — three edits:
  1. After `cd "$repo_root"`, re-set `repo_root="$(pwd -P)"` so destination
     paths compare equal to `canonical_path()` output (avoids `/var` vs
     `/private/var` symlink mismatch on macOS triggering a copy-onto-itself).
  2. Scope check changed from repo-root prefix (`"$spec_root"*`) to path-shape
     glob (`*/docs/superpowers/specs/*`, `*/docs/superpowers/plans/*`); each
     source is copied into the repo's `docs/superpowers/{specs,plans}/` via
     `cp` **unless** `canonical == dest` (in-repo path → no copy, original
     behavior preserved). New `dest_paths` array drives staging.
  3. Temp-index block now stages/diffs `"${dest_paths[@]}"` instead of `"$@"`.
     The commit line stays `git commit -m "$SUBJECT"` (no pathspec) and the
     post-commit `git add -- "${paths_to_clean[@]}"` reconcile is unchanged.
- `tests/spec2pr/test-publish-spec.sh` — two new tests:
  `test_publish_spec_copies_external_worktree_spec` and
  `test_publish_spec_copies_external_worktree_spec_and_plan`. They build an
  external dir under `$SANDBOX` (outside `$PROJECT`) to simulate a worktree.
- `VERSION` → `1.7.1`; `UPGRADE.md` → new `## To v1.7.1 - from v1.7.0` section
  (Action: None; Caveat describes the new worktree-path capability).

Verification: `bash tests/spec2pr/run-tests.sh` → **587 assertions, 0 failed**
(was 577; the 2 new test functions add 5 assertions each = +10). The suite
counts assertions, not functions.

PR flow used `/rulez:create-pr` (PR-drafter subagent) then `/rulez:merge-pr`.
Both staged by exact path, so the protected untracked paths were never touched.

## What Didn't Work
No failures. Merge was clean (MERGEABLE, no conflicts); tests passed first run;
create-pr and merge-pr both succeeded. The merge script's
"Warning: 3 uncommitted changes" is expected — it's the three protected
untracked paths, which a plain `git stash` and branch switch leave alone.

## Next Steps
Nothing pending. No open issues or PRs in the repo. Possible follow-ups only if
the user asks:
- Manual smoke-test from a real `barevibe-API`-style checkout: run
  `scripts/git-publish-spec.sh <worktree-spec-path> <worktree-plan-path>` from
  the repo root on `main` and confirm the copy-in + push (automated tests
  already cover this path).
- Global install auto-updates via the SessionStart hook;
  `/rulez:update-claudeset` forces it if the user wants v1.7.1 live immediately.

## Key Decisions
- **Kept the temp-index commit machinery untouched.** `test-publish-spec.sh`
  pins it hard (MM staged state preserved, pre-staged unrelated file ignored,
  `git commit -m "$SUBJECT"` present, `git commit --only` absent). The whole fix
  is gated on `[ "$canonical" != "$dest" ]`: in-repo paths skip the copy and
  flow through the exact original logic, which is why every existing assertion
  stayed green. A simpler `git add` + `git commit -- paths` rewrite was rejected
  because it would overwrite the MM-staged index version and break that test.
- **Included the VERSION/UPGRADE bump** because this is a user-facing behavior
  change to an installed script (repo convention). Patch bump.
- `commands/rulez/spec2pr-split.md` (lines 122-131) already calls this helper
  with "concrete part paths" — no doc change needed; the new behavior is a
  superset of the old.

## Protected - DO NOT touch / commit
These untracked paths are intentionally excluded from all commits. Always stage
by exact path; never `git add .`:
- `tmp/`
- `references/`
- `docs/research-auto-handoff-at-context-threshold.md`
