# Spec2PR Split

Recover from a `spec2pr` size-gate halt by splitting one too-big spec into
sequential, independently implementable sub-specs.

This command is pure orchestration. It never commits, pushes, closes PRs, or
deletes anything.

## Usage

`/rulez:spec2pr-split <blob>`

Paste the `spec2pr` halt output as `<blob>`. The blob should include the spec
path, optional plan path, the `SPLIT` line, and optionally a PR URL or `#N`.

If no blob argument is given, ask the user to paste the halt output and stop.

## Instructions

1. Gather context from the pasted blob:
   - Write the blob to a temporary file referenced by `BLOB`.
   - Run exactly. Command files intentionally use the installed tilde path:
     `bash ~/.claude/skills/rulez-claudeset/scripts/spec2pr-split-context.sh "$BLOB"`
   - Remove the temporary file after the call returns.
   - If the script exits nonzero, show the error and stop.
   - Parse the helper's stdout `key=value` block only and collect:
     - `spec_path`
     - `plan_path`
     - `gate`
     - `pr_number`
     - every `changed_file=...`
   - Show helper warnings or errors from stderr, but do not mix stderr lines
     into the parsed keys.

2. Compute split targets from `spec_path`:
   - Treat `spec_path` as a normal `...-design.md` spec path.
   - Insert `-part-N` before `-design` to produce:
     - `docs/superpowers/specs/<slug>-part-1-design.md`
     - `docs/superpowers/specs/<slug>-part-2-design.md`
   - If `spec_path` does not end in `-design.md`, stop and report that there is
     no `-design.md` suffix to split against.
   - If either target path already exists, refuse to continue.
   - Name the colliding path explicitly.
   - Tell the operator to rename, remove, or archive the stale draft first.
   - Do not overwrite either file.
   - Do not invoke `superpowers:brainstorming` when a collision is present.

3. Delegate the split to `superpowers:brainstorming` via the Skill tool.
   Prime it with the extracted evidence and these directives:
   - `spec2pr`'s `<gate>` gate rejected this spec because size `N > limit M`.
     Decompose it into sequential, independently implementable sub-specs;
     default to `2`; minimize shared files.
   - Write both files in one pass to the computed part paths.
   - Each sub-spec must follow house style:
     `Context / Settled decisions / Affected code / The change / Edge cases & invariants / Testing / Out of scope`
   - Keep each file under `32 KB`.
   - Produce a coverage map where every original requirement maps to exactly one
     part, with no gaps.
   - Shared files are only allowed when justified.
   - Cross-check the `changed_file` list when present.
   - Part 2 must include this exact prose:
     `part-1 is already merged into main; build on it, do not re-specify its changes.`
   - Leave both files uncommitted.
   - Do not push.
   - Terminal state is the `brainstorming` review gate.
   - Stop after writing the files.
   - Do not chain to `writing-plans`.

4. When `brainstorming` returns:
   - Surface both part paths.
   - Surface the coverage map.
   - Print manual next steps keyed to `gate`.
   - Execute nothing destructive.

5. Manual next steps:
   - If `gate=diff` and `pr_number` is present:
     - Print this manual cleanup note and standalone command; do not execute
       them here:
       `dead PR #<pr_number>`
       `gh pr close <pr_number> --delete-branch`
     - Then tell the operator to remove stale worktree and metadata.
   - If `gate=spec` or `gate=plan`:
     - State that there is no PR to clean up.
     - Tell the operator to remove local worktree and metadata only if the
       original run created them.
   - Always print the sequencing recipe, one path at a time:
     - `bash ~/.claude/skills/rulez-claudeset/scripts/git-publish-spec.sh docs/superpowers/specs/<slug>-part-1-design.md`
     - `/rulez:spec2pr docs/superpowers/specs/<slug>-part-1-design.md`, then
       review and merge that PR
     - `git pull --ff-only origin main`
     - `bash ~/.claude/skills/rulez-claudeset/scripts/git-publish-spec.sh docs/superpowers/specs/<slug>-part-2-design.md`
     - `/rulez:spec2pr docs/superpowers/specs/<slug>-part-2-design.md`, then
       review and merge that PR

## Verification

Verify this command by manual dry-run and read-through, not unit tests.
