# Notify-Wake Design Patterns

Use this reference to select an adapter and review its state, delivery, and security behavior.

## Contents

- [Adapter Patterns](#adapter-patterns)
- [Registration and Reconciliation](#registration-and-reconciliation)
- [Persistent Goal Event-Wait](#persistent-goal-event-wait)
- [Watch and Delivery States](#watch-and-delivery-states)
- [Codex Task Delivery](#codex-task-delivery)
- [Security Boundaries](#security-boundaries)
- [Design Review](#design-review)
- [Acceptance Scenarios](#acceptance-scenarios)

## Adapter Patterns

### Native local completion

Use a supervisor that owns the child process or process group and receives its exit status. The supervisor writes lifecycle and terminal state, then emits a notification event. The child must not wait for Codex delivery.

Use this pattern for builds, training, exports, batch transforms, and long file operations. Treat child exit, fatal signal, timeout, and cancellation as terminal source events.

### Native remote event

Use a provider webhook, queue event, callback, or event stream. Verify provider signatures or tokens before accepting identifiers. Store the provider event or delivery identifier for replay deduplication, then fetch authoritative state from the provider.

Do not place webhook text, logs, artifact contents, branch names as commands, or user-controlled descriptions in the wake prompt.

### Trusted relay

Use a relay when the native event cannot reach the local ingress directly. Give the relay the least privilege needed to read or receive completion state. It must execute no untrusted operation code and send only authenticated identifiers to the trusted ingress.

Keep provider credentials and Codex task context out of untrusted jobs. The trusted ingress resolves identifiers and records source truth.

### Local non-model watcher

Use this fallback when no event subscription exists. Poll only one registered immutable target. Set a bounded interval, deadline, total lifetime, and terminal-state mapping before starting the watcher.

The watcher may:

- fetch status for the registered target;
- validate target and attempt identity;
- write lifecycle or terminal state;
- emit the corresponding durable event.

It must not:

- search broadly for related work;
- interpret results or logs;
- choose a next action;
- change code, Git state, job state, or source configuration;
- spend model turns checking progress.

### No observable source

Do not promise automatic wake when the operation lacks a native event, exact status read, or safe local watcher. Stop before launch unless the user explicitly authorizes execution without automatic continuation.

## Registration and Reconciliation

Prefer this order:

1. Generate stable watch and dispatch-correlation identifiers.
2. Capture the originating task, permission context, and persistent-goal snapshot when one exists.
3. Persist the prepared watch.
4. Arm the event source or watcher.
5. Launch or dispatch the operation.
6. Bind the returned immutable target and attempt identifiers atomically and claim matching early events.
7. Query current source state immediately.
8. Persist any already-observed terminal event.
9. When the turn cannot progress until an event, use native compare-and-set or a lease-protected read/verify/write to move the captured active goal into `blocked`, then persist the returned event-wait snapshot before returning control.

When an API returns the target identifier only after dispatch, require provider lookup by a stable dispatch correlation identifier or keep a durable inbox for authenticated provider events. Match the returned identifier or correlation identifier before processing an early event. Preflight recovery from a lost dispatch acknowledgment; if a started operation could become unidentifiable, do not dispatch it.

For attachment to existing work, reject mutable names, broad filters, or "latest run" selectors. Require the exact process, job, run, transfer, request, or attempt identifier.

After restart:

- load only registered watch records;
- validate their schema and managed location;
- query each exact target;
- preserve already-accepted delivery;
- retry due pending delivery;
- close source-complete watches that do not meet the attention predicate.

## Persistent Goal Event-Wait

An active persistent goal can schedule another model turn after the current turn ends. A notify-wake design has not removed model polling unless it also controls that continuation.

Before launch, preflight an authorized goal controller and either native compare-and-set support or an exclusive goal-write lease honored by every goal controller. After the operation is registered and immediate reconciliation confirms that no model action is due:

1. Re-read the goal and require the captured identity, revision, objective, and `active` status.
2. Use the native precondition or hold the goal-write lease while setting that exact snapshot to `blocked` for this watch.
3. Persist the returned blocked snapshot, transition owner, time, and watch identifier.
4. Return control only after the blocked state is durable.

Do not block a goal merely because a watcher exists. Use event-wait only when the current turn has no useful work until the registered source emits an event. If the goal cannot be blocked safely, stop before launch. If the post-launch transition fails despite preflight, keep the current turn active and follow a defined recovery path rather than returning with an active goal.

At delivery, keep the goal blocked while submitting the wake whenever the installed app-server permits it. After `turn/start` or `turn/steer` is accepted, use native compare-and-set or the exclusive goal-write lease to reactivate the exact blocked snapshot and persist the result before closing the notification.

If the app-server requires goal activation before wake acceptance, use this fallback only under a task-scoped lease honored by every input client and the goal controller:

1. Verify that the goal still equals the recorded blocked snapshot.
2. Activate it under the lease and persist the returned activation snapshot.
3. Read task and goal state again while holding the lease.
4. Submit `turn/start` with its atomic idle precondition or `turn/steer` with `expectedTurnId`.
5. If the request is explicitly rejected or authoritative history proves absence, verify that the activation snapshot is unchanged and restore it to `blocked` before releasing the lease.
6. If acceptance is uncertain, leave the goal unchanged and reconcile the client message before another wake or goal transition.

Never restore or reactivate a goal after its identity, revision, objective, or protected status changes. Preserve paused, complete, budget-limited, and usage-limited states.

## Watch and Delivery States

Track lifecycle and delivery independently.

Lifecycle states:

| State | Meaning |
|---|---|
| `prepared` | Origin context and intent are durable; no target is bound |
| `armed` | Event source or watcher is ready |
| `active` | Immutable target and attempt are registered |
| `complete` | Source reached a supported terminal state |
| `closed` | Terminal source handling and any required delivery are complete |

Store the authoritative source status separately. Every emitted event also stores the result of the declared attention predicate. A terminal event can therefore have lifecycle `complete` and `attention_required: true`. A nonterminal decision event can have lifecycle `active` and `attention_required: true`.

Delivery states:

| State | Meaning |
|---|---|
| `none` | Attention predicate is false or no event exists |
| `pending` | Durable event requires delivery |
| `in_flight` | One serialized delivery attempt is active |
| `uncertain` | A request may have been accepted, but its acknowledgment was lost |
| `retry_due` | Prior attempt failed transiently |
| `accepted` | App-server accepted start or steer |
| `blocked` | The durable event remains undelivered after retry exhaustion or until a context or configuration change |

Write source state first. For a terminal event that requires attention:

```text
lifecycle: active -> complete
delivery:  none -> pending -> in_flight -> accepted
lifecycle: complete -> closed
```

Silent success uses:

```text
lifecycle: active -> complete -> closed
delivery:  none
```

An app-server outage uses:

```text
lifecycle: active -> complete
delivery:  none -> pending -> in_flight -> retry_due
```

An acknowledgment loss uses:

```text
lifecycle: active -> complete
delivery:  none -> pending -> in_flight -> uncertain
reconcile: matching clientId -> accepted
           proven absence    -> retry_due
           unknown           -> blocked
```

An accepted nonterminal decision event does not close the watch. Keep source observation armed while the operation remains active. Once terminal source truth is durable, the source subscription may be disarmed while delivery remains pending; retain the watch in `complete` until delivery is accepted.

Never rewrite authoritative source status or lifecycle because delivery failed.

Deduplicate source events by the strongest immutable logical provider identity. Otherwise derive a stable identity from source namespace, target ID, attempt ID, event kind, and occurrence identity. Treat webhook delivery IDs as replay metadata. Enforce an atomic unique insert for the event ID and an atomic delivery claim under the per-task serializer. Reuse the logical event ID for `clientUserMessageId`, but treat that field as correlation metadata unless the installed app-server explicitly documents stronger semantics.

Persist the request-sent boundary before transport write. A transport error before any bytes are sent is retryable. A timeout, disconnect, or crash after bytes may have been sent is `uncertain`, not retryable by assumption. Reconcile it through an app-server idempotency result or an authoritative history read that returns turn items and can prove presence or absence of the exact `userMessage.clientId`. A matching item is accepted delivery even when the original response was lost. If the history contract cannot prove absence, keep the delivery blocked instead of sending the wake again.

Retain accepted event identities for at least the provider replay horizon and watch retention period. Keep unmatched early events through registration, restart recovery, and the watch deadline.

## Codex Task Delivery

Capture the effective permission profile and approval policy before launch. Do not infer them from static configuration when the app-server can return the active values. If a persistent goal is involved, follow [Persistent Goal Event-Wait](#persistent-goal-event-wait) and record both sides of every authorized transition.

At delivery:

1. Initialize the app-server connection.
2. Call `thread/resume` with the captured permission and approval context.
3. Reject a different effective context.
4. Call `thread/read` and identify the current task and active turn state.
5. Read persistent goal state when the task uses a goal.
6. Verify that any event-wait goal still matches the watch's blocked snapshot.
7. Use `turn/start` for an idle task only under an atomic idle-start guarantee. Use `turn/steer` with `expectedTurnId` for an active task.
8. Keep the goal blocked until wake acceptance, or use the lease-protected activation-first fallback when the installed app-server requires it.
9. Persist acceptance only after the RPC response identifies the accepted turn, then durably reactivate the exact event-wait goal before closing the notification.
10. If acknowledgment is lost, call `thread/read` with `includeTurns: true`, find the exact `userMessage.clientId`, and reconcile goal state before any retry.

If silent success would still require a goal transition or user-visible completion, the attention predicate is true and the adapter must wake the task. If task, turn, or goal state changes between the read and delivery request, keep the event queued and reconcile again.

App-server outages before request transmission and task-state races use `retry_due`. A request with an unknown acceptance result uses `uncertain` until reconciled. Persistent permission, approval, configuration, or unresolvable delivery-state mismatches use `blocked`. In every case, preserve the pending event and the observed operation result. The retry trigger, capped delay and jitter, and delivery deadline or attempt limit must be selected during preflight.

`thread/read` followed by `turn/start` is subject to a time-of-check/time-of-use race. Before enabling idle delivery, inspect the installed schema and app-server behavior for an expected-idle or equivalent atomic precondition. If none exists, require a task-scoped lease honored by every start-capable client. A lock held only by the notifier does not cover user, app, remote-control, or other client input. Without either guarantee, leave the event `blocked` and report that automatic idle wake is unavailable.

Wake text should identify:

- trusted source namespace;
- target, attempt, and event identifiers;
- validated lifecycle or terminal status;
- occurrence time;
- local state path or provider URL used to retrieve evidence.

The resumed task fetches source state, jobs, logs, artifacts, or metrics through the authoritative tool or local state reader. It must not trust the wake text as result evidence.

## Security Boundaries

- Validate all provider payloads, local state, paths, identifiers, and app-server responses.
- Authenticate public ingress and prevent replay from creating another accepted wake.
- Keep trusted delivery code separate from untrusted operation code.
- Use least-privilege provider and repository permissions.
- Keep task IDs, permission context, and local socket paths out of untrusted jobs.
- Keep secrets, raw logs, stack traces, model output, user data, and artifact contents out of wake input.
- Bound stored error text and remove control characters before persistence or display.
- Restrict local watch files and sockets with host-appropriate permissions.
- Never let delivery mutate the recorded operation result.
- Never make the operation depend on Codex availability.
- Test with fake transports and mock sources. Automated tests must not wake a real task.

## Design Review

Reject a design unless it answers:

- What exact operation will be observed?
- Which immutable identifiers distinguish retries and attempts?
- Which source is authoritative for status and evidence?
- Is the event source armed before launch, or how is the race reconciled?
- Which outcomes meet the attention predicate?
- Where are lifecycle truth, watch state, and delivery state stored?
- How are duplicates, concurrent delivery, restarts, and transient errors handled?
- How is a lost app-server acknowledgment reconciled without a blind resend?
- How are lost dispatch acknowledgments, early-event retention, atomic event insertion, and atomic delivery claims handled?
- How are permission, approval, task, active-turn, and goal state preserved?
- How is an active persistent goal placed into event-wait before control returns?
- Is goal reactivation post-acceptance, or protected by a cross-client lease and safe rollback?
- What information enters the wake input?
- What happens when the event source, local watcher, or app-server is unavailable?
- When and how is the watcher disarmed?
- How does the design prove that no model polling is required?

## Acceptance Scenarios

| Scenario | Required result |
|---|---|
| Successful operation needs analysis | One accepted wake, followed by source-backed analysis |
| Successful operation completes the objective | Durable silent close with no wake |
| Failure, cancellation, timeout, or stall | Pending attention event and one idempotent accepted wake |
| Duplicate provider delivery | Stored event result, no second accepted wake |
| Delivery acknowledgment is lost | Reconcile by stable client message ID; accept a match, retry only after proven absence, otherwise block |
| Originating task is idle | `turn/start` with the stable client message ID only under an atomic idle-start guarantee; otherwise keep delivery blocked |
| Originating task has an active turn | `turn/steer` with the expected active turn ID |
| Active persistent goal waits on the operation | Exact goal snapshot is moved to `blocked` under a native precondition or exclusive goal-write lease before control returns |
| Wake is explicitly rejected after activation-first fallback | Unchanged activation snapshot is restored to the recorded event-wait state before the lease is released |
| Wake acceptance is uncertain | Goal state is left unchanged until client-message reconciliation proves acceptance or absence |
| App-server is unavailable | Source truth remains durable and delivery stays retryable |
| Task, turn, goal, or permission context changed | Delivery remains queued or blocked without changing source truth |
| Operation completes during registration | Immediate reconciliation records the missed terminal event |
| No native source or safe watcher exists | Launch stops and automatic wake is reported unavailable |
