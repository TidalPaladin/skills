---
name: notify-wake
description: Replace model polling with durable event notifications that wake the originating Codex task. Use before starting long-running or asynchronous compute, I/O, CI, builds, transfers, queued work, or other machine-observable operations that would otherwise require another model turn only to check status; also use when designing, reviewing, or debugging completion, failure, timeout, cancellation, stall, or approval-needed wake delivery.
---

# Notify & Wake

Use an event source or a run-specific non-model watcher to resume Codex only when agent attention is required. Keep the operation independent of Codex availability.

Read `references/design-patterns.md` before selecting an adapter, registering a watch, or reviewing a notify-wake design.

## Operating Contract

Apply this skill when an operation is asynchronous, detached, remote, or would otherwise require a second model turn solely to ask whether it finished. Do not apply it to a short operation that completes within one ordinary tool wait.

Support two modes:

- In a planning context, produce a decision-complete design without registering, launching, or changing an external system.
- In an execution context, arm a task-specific adapter before launching or attaching to the operation.

Invocation does not authorize the operation itself, new network exposure, service installation, daemon creation, schedule creation, credential use, or broader permissions. Obtain any authority those actions require through the task's normal workflow.

Use the bundled strict local-process adapter for commands and existing Unix
processes. Use repository or provider adapters for remote operations and
provider-specific event sources. Do not expand the local adapter into a generic
daemon or provider framework.

A planning result must name the real event source, adapter owner, durable watch location, retry trigger, and target identity rule. If the environment cannot supply them, report automatic continuation as unavailable. Do not hide an unresolved implementation behind a placeholder adapter.

## Bundled Local-Process CLI

The synced skill includes a locked `uv` project with
`websockets==16.1.1`. Set the skill path once, then invoke the script through
that project:

```bash
notify_wake_skill="${CODEX_HOME:-$HOME/.codex}/skills/notify-wake"
uv run --project "$notify_wake_skill" --locked \
  python "$notify_wake_skill/scripts/notify_wake.py" preflight --format json
```

Public commands:

- `preflight` discovers the managed daemon, captures the effective non-null
  permission profile and approval policy, and reports whether strict delivery
  is available.
- `run --timeout-seconds N [--wake-on always|failure] [--evidence ABS] -- COMMAND...`
  registers a prepared watch before releasing an owned child process group.
- `attach --pid PID --timeout-seconds N [--expect-start-ticks TICKS]
  [--evidence ABS]` captures a Linux pidfd plus `/proc` start time and never
  signals the attached process.
- `status WATCH_ID` reads one exact durable watch.
- `reconcile WATCH_ID` reconciles one exact terminal event and uncertain
  request boundary.

When the watched command runs `uv` for a different project, prefix that command
with `env -u VIRTUAL_ENV` so the notifier's locked environment does not leak
into the nested invocation.

Use `--format json` for automation. The CLI returns `0` for success, `1` when
durable state requires attention or strict automatic delivery is unavailable,
and `2` for a runtime or state error. Watch state is stored under
`${CODEX_HOME:-$HOME/.codex}/notify-wake/<watch-id>/`.

The adapter intentionally blocks delivery when the originating task is idle,
when a persistent goal exists, or when the effective permission profile or
approval policy differs after resume. It does not mutate goals or issue
`turn/start` because the installed app-server does not expose the required
cross-client lease or atomic idle-start precondition.

## Adapter Selection

Choose the first safe option that can observe one immutable operation:

1. Native completion callback, webhook, event stream, queue event, or process-exit signal.
2. Trusted relay that authenticates and forwards identifiers from the native event.
3. Local non-model watcher that observes only the registered operation identifier.
4. No automatic wake.

For option 4, stop before launch and report that automatic continuation is unavailable. Do not substitute model-driven polling without explicit user authorization.

Use a non-model watcher only when it has a bounded lifetime, an enforced timeout, and no need for model judgment. It may inspect source state and emit a durable event. It must not interpret results or modify the operation.

## Prelaunch Workflow

Before launch or attachment:

1. Define the exact operation and immutable target identity or dispatch correlation identity.
2. Define what work remains after each possible outcome.
3. Write the attention predicate.
4. Select and preflight the event source, adapter, authentication, durable state location, delivery retry trigger, timeout, fallback, and any persistent-goal event-wait transition.
5. Capture the originating Codex task ID, effective permission profile, approval policy, capture time, and current persistent-goal snapshot when one exists.
6. Persist a prepared watch record.
7. Arm the event subscription or non-model watcher.
8. Launch the operation and bind its returned identifier with an atomic transaction or idempotent compare-and-set, or attach an existing exact identifier.
9. Reconcile source state immediately to close the launch-registration race.
10. If the originating task has an active persistent goal and no model work remains until an event arrives, use an authorized controller with native compare-and-set support or an exclusive goal-write lease to move that exact goal into `blocked` for this event wait. Persist the returned blocked snapshot and transition ownership.
11. Return control only after the watch is active and any required goal transition is durable.

When attaching to an operation that already started, require an exact immutable identifier and reconcile its current state before claiming the watch is armed.

If launch returns the immutable identifier only after the operation starts, require a provider correlation lookup or a durable authenticated early-event inbox. The adapter must recover after dispatch acknowledgment is lost. Do not launch when a crash between dispatch and registration could leave an unidentifiable operation.

Block a goal only when the current turn cannot make progress until a registered event. A watcher being active is not enough. Preflight the authority and either native compare-and-set support or an exclusive goal-write lease honored by every goal controller. If an active goal cannot enter event-wait safely, stop before launch and report that model-free continuation is unavailable. After launch, do not return control until the transition succeeds or the current turn completes a defined recovery path.

## Attention Predicate

Declare the predicate before launch.

Always require attention for:

- failure, cancellation, timeout, startup failure, or fatal signal;
- a stalled heartbeat or missed progress deadline;
- approval or other external action required;
- target, attempt, ref, revision, or evidence mismatch;
- an unknown, malformed, or unsupported terminal state.

Wake on success only when Codex still must analyze results, validate artifacts, start dependent work, publish authorized output, choose a next step, change persistent goal state, or finish the user-visible handoff. Close successful work silently when durable source evidence proves that no agent action remains.

Do not wake for routine progress, heartbeats, retry bookkeeping, duplicate events, or successful delivery-state updates. Nonterminal events may wake only when the predefined protocol requires a model decision.

## Adapter Contract

Require these logical operations:

- `preflight`: verify source access, authentication, target identity rules, durable paths, timeout, and Codex delivery support.
- `arm`: establish the native subscription, relay, or local watcher before launch when possible.
- `register`: bind the immutable target and attempt identifiers to the prepared watch atomically and claim any matching early events.
- `observe`: read current state from the authoritative source without model judgment.
- `emit`: insert one validated event under an atomic uniqueness constraint after source state is durable.
- `deliver`: atomically claim a pending event, apply the attention predicate, and submit one idempotent wake under per-task serialization.
- `reconcile`: recover races, restarts, missed events, and partially completed delivery.
- `close`: record silent terminal completion or accepted terminal delivery and disarm future source observation. An accepted nonterminal event leaves the watch active.

Persist:

- schema version; watch, operation, attempt, and event identifiers;
- event source, adapter, immutable target identity, and evidence locator;
- originating task ID, permission profile, approval policy, and capture time;
- optional persistent-goal identity and revision, active and blocked snapshots, transition owner, transition state, and bounded transition error;
- attention predicate, authoritative source status, current lifecycle state, and the predicate result for each event;
- occurrence, observation, and terminal timestamps;
- delivery state, attempt count, request-sent time, uncertainty reason, last bounded error, retry time, acceptance time, accepted RPC method, and accepted turn ID.

Keep lifecycle truth separate from delivery state. Write the observed lifecycle or terminal state before creating or updating a notification. Delivery failure must never change the operation result.

## Codex Delivery

Use at-least-once delivery with a stable logical event identifier. A provider webhook delivery-attempt ID is replay metadata, not the event identity. Enforce uniqueness when inserting events and claiming delivery. Retain accepted identities for at least the provider replay horizon and the watch retention period. The durable adapter state provides idempotency; do not assume `clientUserMessageId` deduplicates app-server requests.

Serialize delivery per originating task. Persist `in_flight` and the request-sent time before writing the request. If the request is explicitly rejected or fails before any bytes are sent, use `retry_due`. If the connection fails after the request may have reached the app-server, use `uncertain` and reconcile before another send.

Reconcile uncertain delivery through an app-server idempotency guarantee or an authoritative history query. With the current item schema, request `thread/read` with `includeTurns: true` and search `userMessage.clientId` for the stable `clientUserMessageId`. A match proves acceptance and supplies the turn identity. Retry only when the delivery API or query contract proves the message is absent. If the query is incomplete, stale, unavailable, or cannot prove absence, keep the event durable and `blocked`; never retry an uncertain request blindly.

Preflight an existing authorized retry trigger. Retry eligible transient failures with exponential backoff whose delay and jitter are capped, and define a delivery deadline or attempt limit. Use `retry_due` while automatic retry remains possible. Keep the notification durable and use `blocked` after retry exhaustion or for a persistent configuration or context mismatch. Mark acceptance only after the app-server accepts the request or authoritative reconciliation finds the matching client message.

Preflight concurrency across every start-capable ingress for the originating task. Use `turn/start` only when the installed app-server provides an atomic idle-start precondition or the adapter holds a task-scoped lease honored by every input client. A preceding `thread/read` is not an atomic idle check. If neither guarantee exists, retain the event as `blocked` instead of risking a second active turn.

Keep an event-wait goal blocked until the wake request is accepted. Prefer delivering `turn/start` or `turn/steer` while the goal remains blocked, then use native compare-and-set or a lease-protected read/verify/write to reactivate the exact recorded goal. Do not close the notification until that reactivation is durable. If the installed app-server requires an active goal before it accepts a wake, the adapter must hold a task-scoped lease honored by every start-capable client and goal controller. Under that lease, verify and activate the recorded goal, read task and goal state again, and submit the wake. On an explicit rejection or authoritative proof that the wake was not accepted, restore the unchanged activation snapshot to the recorded event-wait state while still holding the lease. For uncertain delivery, reconcile acceptance before changing the goal again.

For the local Codex app-server:

1. Initialize the connection and resume the captured task with `thread/resume`.
2. Verify the effective permission profile and approval policy match the captured context.
3. Read current task and goal state with `thread/read` and the installed goal-read method.
4. Preserve paused, complete, budget-limited, and usage-limited goals. Reactivate only when the watch owns the event-wait transition and the current goal exactly matches the recorded blocked snapshot.
5. Use `turn/start` when the task is idle and the preflighted atomic idle-start guarantee holds. Use `turn/steer` with `expectedTurnId` when a turn is active.
6. Follow the preferred blocked-goal delivery sequence or the lease-protected activation-first fallback above.
7. Reuse the event identity as `clientUserMessageId` for correlation and duplicate diagnosis, not as the adapter's deduplication store.
8. After an uncertain request, read authoritative turn history and locate that exact client message before deciding whether another send or goal transition is safe.

If the app-server is unavailable before sending or task state changes before delivery, retain the pending event and use `retry_due`. Keep an event-wait goal blocked unless the lease-protected fallback proves that restoring the recorded snapshot is safe. If availability is lost after sending, use `uncertain`. For a persistent permission or approval-context mismatch, retain the event and use `blocked`. Do not start a second concurrent turn or deliver under a different permission context.

Keep wake input fixed and small. Include only validated identifiers, status, timestamps, and evidence locations. Never include raw logs, stack traces, remote output, artifacts, secrets, or other untrusted content. The resumed task must fetch and validate source evidence before acting.

Prefer the Codex SDK, stdio, or a local Unix socket. Do not expose an unauthenticated non-loopback WebSocket listener. Validate methods and fields against the schema generated by the installed Codex version and the [Codex App Server documentation](https://learn.chatgpt.com/docs/app-server.md).

## Recovery and Handoff

On adapter restart, scan only registered watch records, reconcile each exact target with its source, and resume due delivery. Reconcile prepared watches through their correlation identifiers or early-event inboxes. Reconcile every `in_flight` or `uncertain` delivery against authoritative task history before retrying it. Do not discover or claim unrelated operations.

If the event source fails, use the declared local non-model watcher when available. If both paths fail, leave the watch pending, preserve source truth, and report the loss of automatic continuation through the next authorized interaction. Do not create a model polling loop.

In planning mode, return:

`Operation | Target identity | Event source | Adapter | Attention predicate | Watch location | Codex delivery | Fallback | Validation`

In execution mode, report the armed adapter, immutable target or correlation identity, attention predicate, durable watch location, timeout, and fallback before returning control. On wake, re-read source state, validate evidence, and continue the original task within its existing authority.
