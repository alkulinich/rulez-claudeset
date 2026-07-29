# Codex cycle heartbeat backoff implementation plan

## Goal

Replace Codex cycle goals with same-task heartbeat automations so reviewer,
verifier, and fixer cycles can wait indefinitely without being marked blocked.
Idle checks back off through 5, 10, and 15 minutes, then remain at 15 minutes.

The approved design is:

`docs/superpowers/specs/2026-07-29-codex-cycle-heartbeat-backoff-design.md`

## Constraints

- Keep the public Codex command unchanged.
- Keep reviewer, verifier, and fixer in separate tasks.
- Preserve every existing review, verification, fix, decline, and idempotency
  rule.
- Do not change Claude cycle behavior.
- Do not fall back to a Codex goal when scheduled tasks are unavailable.
- Do not add an external daemon, cron job, GitHub Action, or polling process.
- Leave `VERSION` and `UPGRADE.md` unchanged.

## Task 0: Prove the Codex heartbeat primitive

Run a manual Codex desktop spike before changing repository files. Create one
same-task heartbeat by hand with an idle fixer prompt against a quiet PR and
observe it for at least three wakes or thirty minutes.

Record:

- whether heartbeats are recurring or one-shot;
- whether a tick can update or disable its own automation;
- whether the tick receives its automation id or must store it in the prompt;
- how an existing automation can be found without relying on an undocumented
  storage format;
- the rendered prompt size and whether the automation accepts it;
- whether repeated idle wakes avoid the goal blocked audit.

**Gate**

- Continue only if the heartbeat wakes repeatedly, remains attached to the
  current task, can be updated or disabled safely, and survives three idle
  wakes without blocking.
- If any premise fails, stop and amend the design before writing code. Do not
  silently substitute a fixed cadence, goal fallback, or polling process for
  the approved behavior.
- Preserve the automation id, Scheduled run history, desktop version, and task
  status as spike evidence. Disable the spike heartbeat afterward.

## Task 1: Add the heartbeat prompt mode

**Files**

- `scripts/cycle-prompt.sh`
- `tests/cycle/test-cycle-prompt.sh`

Extend the builder's mode selector from `loop|goal` to
`loop|goal|heartbeat`. Keep all role/type body templates unchanged and add only
the heartbeat wrapper text:

- one scheduled tick checks the watched state;
- terminal success completes the cycle and disables the heartbeat;
- idle returns scheduler control without writing anything.

Update usage and comments. Test the wrapper values directly, then spot-check a
PR verifier and a file-based role to prove substitution reaches both template
families. Confirm the existing loop and goal assertions still pass unchanged.

**Acceptance**

- `heartbeat` renders successfully for reviewer/fixer spec and plan, plus
  reviewer/fixer/verifier PR.
- verifier remains PR-only.
- invalid modes still exit with usage.
- Existing loop and goal output remains stable.
- The builder remains hermetic.

## Task 2: Replace the Codex goal launcher

**Files**

- `adapters/codex/skills/rulez-tools/SKILL.md`
- `tests/codex/test-setup-codex.sh`

Rewrite only the Cycle Watcher workflow in the Codex skill.

### Launch flow

1. Preserve current argument parsing and the verifier PR-only check.
2. Require the Codex app `automation_update` capability. When unavailable,
   stop with a clear desktop-only message.
3. Render the watcher protocol with
   `cycle-prompt.sh <role> heartbeat <type> <target...>`.
4. Build `rulez_cycle_key` from repository identity, role, type, and normalized
   target.
5. Reuse an existing match through the supported lookup mechanism proven by
   Task 0 instead of creating a duplicate. Do not introduce a dependency on an
   undocumented Codex storage format.
6. Run the first watcher tick immediately.
7. If the tick is non-terminal, create or update a heartbeat attached to the
   current task with the appropriate next delay.

Remove the cycle-specific `get_goal`, 4,000-character objective check,
`create_goal`, and `update_goal` instructions. Do not touch unrelated goal
workflows elsewhere in the skill.

### Automation state

Store only the scheduler metadata that Task 0 proves must persist:

- automation id and `rulez_cycle_key`;
- repository root, role, type, and normalized target;
- rendered heartbeat protocol;
- `idle_level` and `failure_count`.

External comments, SHAs, and findings revisions remain authoritative for what
has already been processed.

### Scheduling behavior

- First idle wait: 5 minutes.
- Second consecutive idle wait: 10 minutes.
- Later idle waits: 15 minutes.
- Meaningful activity: reset to a 5-minute next wait.
- Terminal result: disable the heartbeat and notify once.
- Idle result: reschedule silently with no artifact, PR, or chat write.

Use the simplest creation flow supported by Task 0. If the final prompt must
contain the newly allocated automation id, use two-phase creation: create an
inactive bootstrap, capture its id, then install the final prompt and activate
it. Delete the bootstrap if finalization fails. If the runtime supplies the id
to each tick, use one-step creation and omit self-identification state.

### Error behavior

- Transient failures retry after 5, 10, and 15 minutes without changing
  `idle_level`.
- A successful read clears `failure_count`.
- The third consecutive transient failure pauses the heartbeat and notifies.
- Authentication, approval, malformed state, or partial-write failures pause
  immediately and notify.
- A fixer still cannot post `fixed` until push and PR-head verification pass.

### Contract tests

Replace the goal-launcher assertions with high-signal heartbeat contract
assertions covering:

- unchanged public syntax and separate watcher tasks;
- `automation_update` capability gating;
- heartbeat builder mode;
- immediate first tick;
- deterministic identity and duplicate reuse;
- the scheduler state and update mechanism actually selected after Task 0;
- terminal disable and error pauses;
- no goal fallback;
- desktop-only unsupported message.

Do not add prose-grep tests that merely restate every delay or error sentence.
Real cadence, reset, duplicate, and retry behavior belongs to the desktop smoke
test because the shell suite cannot execute `automation_update`.

**Acceptance**

- The installed skill instructs Codex desktop to create one current-task
  heartbeat per repository/role/type/target.
- Re-launching the same cycle updates that heartbeat rather than duplicating
  it.
- CLI and IDE do not start a fragile goal.

## Task 3: Update operator documentation

**File**

- `README.md`

Keep all existing invocation examples. Replace persisted-goal wording with:

- Codex desktop uses same-task Scheduled heartbeats;
- the first check is immediate;
- idle checks use 5/10/15-minute capped backoff;
- activity resets the delay to five minutes;
- reviewer, verifier, and fixer remain separate tasks;
- CLI and IDE cannot launch durable cycles because they lack scheduled-task
  management;
- the app and computer must remain running for local checks.

Do not change Claude documentation except where needed to distinguish its
unchanged loop/goal behavior from Codex desktop.

## Task 4: Verify behavior

Run automated checks:

```bash
bash tests/cycle/run-tests.sh
bash tests/codex/run-tests.sh
bash -n scripts/cycle-prompt.sh bin/setup-codex
git diff --check
```

Then run the full Codex desktop smoke test in a disposable or already-open test
PR, using the mechanism proven by Task 0:

1. Start an idle fixer cycle and confirm exactly one heartbeat appears in
   Scheduled.
2. Confirm idle delays progress 5, 10, 15, 15 minutes without commits or PR
   comments.
3. Post a review or verification round and confirm it is processed and the
   next delay resets to five minutes.
4. Post a clean terminal round and confirm the heartbeat disables itself and
   notifies once.
5. Launch the same cycle twice and confirm no duplicate automation appears.
6. Exercise one transient failure and confirm retry state changes without
   changing idle state.

Record the exact desktop version and automation ids used for the smoke test in
the implementation summary. Remove or disable any disposable heartbeat after
verification.

## Completion criteria

- Waiting longer than three checks never blocks a healthy Codex desktop cycle.
- The Task 0 evidence proves the selected automation mechanism before code is
  written.
- Idle cadence is 5, 10, 15, then 15 minutes until activity.
- Activity resets cadence to five minutes.
- Terminal success disables the heartbeat.
- Re-launches are idempotent.
- No idle commits, artifact edits, PR comments, or task messages are created.
- Claude loop/goal behavior and all existing cycle semantics remain unchanged.
- Automated suites pass and the desktop smoke test confirms real scheduling.
