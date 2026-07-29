# Codex cycle heartbeat backoff

## Context

Rulez currently launches every Codex cycle watcher as a persisted goal. The
goal performs useful work when a review, verification, or fix round is ready,
but most watcher turns are deliberately idle while another task catches up.

Codex goals are designed to drive work toward an outcome, not to act as an
indefinite scheduler. When the same external wait prevents progress for three
consecutive goal turns, Codex's blocked audit marks the goal blocked. Changing
the prompt from a two-minute wait to a longer wait changes the requested
cadence but does not change that turn-count rule. A healthy reviewer/fixer pair
can therefore pause merely because one side took longer than the other.

Codex desktop scheduled tasks provide the missing scheduling primitive. A
heartbeat attached to the current task can wake it on a minute-based cadence,
retain the task context, and keep polling GitHub or local artifacts without
pretending that an idle check is progress toward a persisted goal.

## Settled decisions

- Keep the public Codex invocation unchanged:

  ```text
  use rulez-tools to cycle <reviewer|fixer|verifier> <spec|plan|PR> <target...>
  ```

- Replace the Codex persisted-goal launcher with a same-task heartbeat
  automation when the Codex app exposes `automation_update`.
- Perform the first watcher check immediately in the invoking task. Create or
  reschedule a heartbeat only when the cycle still needs to wait.
- Use adaptive idle delays of 5, then 10, then 15 minutes. Continue at 15
  minutes indefinitely until activity, terminal success, or a real error.
- Reset the next idle delay to 5 minutes after meaningful cycle activity.
- Reviewer, verifier, and fixer remain separate Codex tasks and separate
  heartbeat automations.
- GitHub comments, PR head SHAs, and findings-file revisions remain the source
  of truth for handled work. The heartbeat stores scheduler state only.
- Do not fall back to a persisted goal when scheduled tasks are unavailable.
  Codex CLI and IDE report that durable cycles require the desktop scheduled
  task surface instead of silently restoring the known three-idle-turn flaw.
- Claude `/rulez:cycle` loop and goal behavior remains unchanged.
- No external daemon, cron process, GitHub Action, webhook service, or polling
  shell process is introduced.

## Why a heartbeat

Three approaches were considered:

1. **Same-task heartbeat automation (selected).** This is Codex's native fit
   for returning to the same task at minute intervals, polling GitHub, and
   continuing a review loop. It survives idle periods without goal blocked
   audits and remains visible in the Scheduled view.
2. **Longer sleeps inside a persisted goal (rejected).** Five- or fifteen-minute
   sleeps still produce the same sequence of externally blocked goal turns.
   Prompt wording cannot override the blocked audit.
3. **External event or polling infrastructure (deferred).** GitHub Actions,
   webhooks, or a daemon would outlive the app and react faster, but add
   credentials, deployment, state, and cleanup that this local workflow does
   not need.

## Public behavior

### Launch

The command validates the role, type, and target with the existing rules, then
runs one watcher tick immediately.

- A terminal clean result finishes in the current task and creates no
  automation.
- Useful non-terminal activity performs the existing review, verification, or
  fix protocol, then schedules the next check for five minutes later.
- An idle result schedules the next check using the current backoff level.
- A human-action error reports the problem and creates no active heartbeat.

The launch response states the role, artifact, target, and next check delay.
It does not claim that a goal was created.

### Idle backoff

Scheduler state contains `idle_level`, initially zero. Whenever the watcher
has nothing to process, it chooses and records the next delay as follows:

| Current idle level | Next delay | Stored level for the next idle tick |
| --- | ---: | ---: |
| 0 | 5 minutes | 1 |
| 1 | 10 minutes | 2 |
| 2 | 15 minutes | 2 |

Any meaningful activity resets `idle_level` to zero before scheduling the next
five-minute check. Meaningful activity means one of:

- a review or verification round was posted;
- a fix or rationale response was posted;
- a warranted artifact or code change was committed and, for PR cycles,
  pushed;
- a new relevant round or revision was observed and processed.

Reading unchanged state is not meaningful activity. It creates no PR comment,
commit, findings-file section, or user-facing idle message.

### Completion

Existing role-specific terminal conditions remain authoritative:

- reviewer: the latest review has `Result: No findings.`;
- verifier: every acceptance criterion passes and nothing breaks, or the PR
  has no acceptance criteria and the verifier reports that condition;
- fixer: the latest applicable clean round is handled and no other unhandled
  review or verification round remains;
- spec/plan roles: the existing no-findings condition is reached.

On completion, the watcher disables its heartbeat, preserves its run history
in Scheduled where the app supports that, and notifies the user once.

## Components

### Prompt builder

`scripts/cycle-prompt.sh` gains a `heartbeat` mode in addition to the existing
`loop` and `goal` modes. The role/type bodies remain the single source of truth.
Only the mode wrapper changes:

- recurrence describes one scheduled tick rather than a continuously active
  goal;
- terminal wording says to complete the cycle and disable the heartbeat;
- idle wording returns an explicit idle outcome for the scheduler without
  writing to the watched channel.

Claude continues to request only `loop` or `goal`. The new mode is Codex-only.

The builder remains hermetic. It performs no Git, GitHub, automation, clock, or
filesystem state lookup.

### Codex skill launcher

The Cycle Watcher section in
`adapters/codex/skills/rulez-tools/SKILL.md` becomes a heartbeat launcher and
tick workflow.

The launcher:

1. validates public arguments and the verifier PR-only restriction;
2. requires the Codex app `automation_update` capability;
3. renders `cycle-prompt.sh <role> heartbeat <type> <target...>`;
4. computes a deterministic automation identity from repository, role, type,
   and normalized target;
5. reuses an existing matching automation instead of creating a duplicate;
6. executes the first tick immediately;
7. creates or updates a current-task heartbeat only if more waiting is needed.

The old `get_goal`, 4,000-character objective gate, and `create_goal` steps are
removed from the Codex cycle workflow. The launcher does not clear or mutate
unrelated goals.

The heartbeat tick prompt includes:

- the complete rendered watcher protocol;
- the automation id and deterministic cycle identity;
- role, type, normalized target, and repository root;
- `idle_level` and `failure_count`;
- instructions to update the same automation rather than create another one.

New automation creation is always two-phase. The launcher first creates an
inactive bootstrap heartbeat, captures its id, then updates it with the final
self-rescheduling prompt and activates it. If the second call fails, the
launcher deletes the bootstrap automation and reports the failure. A
half-configured watcher is never left active.

### Automation identity and duplicates

Automation identity includes the repository, role, type, and normalized
target. Repository identity is the normalized GitHub `owner/repo` from
`origin` when available, otherwise the physical Git repository root. PR
targets normalize to their bare number. Spec and plan targets normalize to an
absolute lexical path based on the repository root; normalization does not
require the watched file to exist yet.

The complete identity is stored in the heartbeat prompt as a machine-readable
`rulez_cycle_key` marker and included in a concise human-readable automation
name. The launcher reads existing local automation configs for that exact
marker before creating anything. This prevents `fixer PR 54` in two
repositories from colliding while still ensuring that repeated launches for
the same cycle reuse one heartbeat.

Launching an already-active cycle refreshes its prompt from the current Rulez
version, resets its next delay to five minutes, and reports that the existing
heartbeat was updated. It does not create a second automation.

Reviewer, verifier, and fixer identities differ by role, so all three may watch
the same PR concurrently from separate tasks.

## Tick state machine

Each scheduled wake produces exactly one of four internal outcomes:

### `activity`

Run the role-specific protocol. If it is non-terminal, store
`idle_level=0`, clear `failure_count`, and schedule the next tick in five
minutes.

### `idle`

Do not write to GitHub, the artifact, or the task. Advance the backoff table,
clear `failure_count`, and update the same heartbeat's next schedule.

### `complete`

Disable the heartbeat and notify once. Do not schedule another tick.

### `error`

- A transient read failure increments `failure_count` and chooses a retry delay
  from the same capped sequence: failure 1 waits 5 minutes, failure 2 waits 10,
  and failure 3 waits 15. Transient failures do not change `idle_level`.
- Three consecutive transient failures pause the heartbeat and notify with the
  last error.
- Any successful read clears `failure_count`, even when the tick is idle.
- An approval, authentication, malformed-state, partial-write, or other
  human-action failure pauses immediately and notifies.
- A PR fixer never posts `fixed` until the push and PR-head verification have
  succeeded, matching the existing invariant.

The state machine never uses `update_goal`. Waiting is scheduler state, not a
goal completion or blocked decision.

## Surface behavior

### Codex desktop

Desktop is the supported durable-cycle surface. The heartbeat is attached to
the current task and appears in Scheduled. The computer must remain on and the
app running for local project checks. Existing sandbox, GitHub authentication,
and approval rules still apply.

### Codex CLI and IDE

The CLI and IDE do not expose scheduled-task management. If
`automation_update` is unavailable, Rulez prints a concise message that durable
cycle polling requires Codex desktop. It does not start a goal, background
shell, or external process as a fallback.

### Claude

Claude continues to use `/rulez:cycle <role> <loop|goal> ...`. Its launcher,
loop behavior, permissions, and prompt modes are unchanged.

## Testing

Offline cycle tests cover:

- `heartbeat` as a valid builder mode;
- unchanged `loop` and `goal` output contracts;
- heartbeat recurrence, terminal, and idle wrapper wording for every supported
  role/type combination;
- verifier remaining PR-only;
- the existing target validation and prompt bodies remaining intact.

Codex adapter contract tests cover:

- the unchanged public invocation;
- `automation_update` as the required scheduler;
- no `get_goal`, `create_goal`, or persisted-goal fallback in the cycle
  workflow;
- immediate first tick;
- deterministic duplicate reuse;
- 5/10/15-minute capped backoff and reset after activity;
- one automation per repository/role/type/target identity;
- terminal disable, three-transient-failure pause, and immediate pause for
  human-action errors;
- a clear unsupported message when scheduled tasks are unavailable;
- reviewer, verifier, and fixer remaining separate tasks.

Because the shell suite cannot invoke the Codex app automation tool, app calls
are verified as a static workflow contract plus a manual smoke test:

1. launch an idle fixer cycle in Codex desktop;
2. confirm one current-task heartbeat appears in Scheduled;
3. confirm its next delays progress 5, 10, 15, 15 minutes without PR comments;
4. post a review round and confirm the fixer processes it and resets to five;
5. finish with a clean round and confirm the heartbeat disables itself;
6. launch the same cycle twice and confirm exactly one automation remains.

Run the existing suites as regression coverage:

```bash
bash tests/cycle/run-tests.sh
bash tests/codex/run-tests.sh
bash -n scripts/cycle-prompt.sh bin/setup-codex
```

## Documentation and rollout

- Update `README.md` to describe Codex desktop heartbeats, adaptive backoff,
  Scheduled visibility, and the CLI/IDE limitation.
- Update the Codex skill capability text from goal watchers to heartbeat cycle
  watchers.
- Keep the public cycle examples unchanged.
- Existing blocked or active goal-based cycles are not migrated automatically.
  Users clear or leave those old tasks, then relaunch the cycle with the new
  Rulez version.
- Leave `VERSION` and `UPGRADE.md` unchanged, matching the recent cycle feature
  changes. This behavior change ships with the next explicit Rulez release.

## Out of scope

- Running cycles while the desktop app or computer is offline.
- A GitHub webhook, GitHub Action, server daemon, or launchd/systemd service.
- Cross-task orchestration that combines reviewer, verifier, and fixer into one
  task.
- A new public stop command; users can pause or disable the heartbeat from
  Scheduled.
- Changing review, verification, fix, severity, decline, or idempotency rules.
- Migrating or clearing existing persisted goals automatically.
