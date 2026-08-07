# Notify-Wake Design Patterns

Use this reference to select an event adapter and review its v2 state, goal ownership, delivery, and security behavior.

## Automatic Invocation Gate

Arm notify-wake automatically only when a defensible prelaunch estimate is strictly more than 10 minutes. Exactly 10 minutes, an unknown runtime, asynchronous execution, or the need for another status check does not qualify by itself. Use an ordinary tool wait or bounded status check instead. Explicit user invocation bypasses this duration gate.

Record the estimate and its basis before launch. Every delivered wake must report `Elapsed before notification: <seconds> seconds` from the registered operation start to its terminal event. For an attached operation whose earlier start cannot be established, use the observation start and record that limitation. Delivery retries must not change the elapsed value.

## Adapter Patterns

### Bundled local-process adapter

For one local Unix command or Linux PID, use the `preflight`, `run`, `attach`, `wait`, `status`, and `reconcile` commands bundled with this skill.

`run` owns a process group and receives exit state through `waitpid`. `attach` captures a pidfd plus `/proc/<pid>/stat` start time and never signals the target. The supervisor syncs source truth before notification state. Each UUID watch is contained under `${CODEX_HOME:-$HOME/.codex}/notify-wake/v2/`.

Delivery uses `research_compatibility` by default. It starts an idle task or steers one exact active turn. `strict` is an explicit opt-in that blocks idle starts and blocked-goal activation. Both policies verify captured authority, serialize by task, persist request boundaries, and reconcile uncertain requests by stable client message ID.

### Native local completion

Use a supervisor that owns the child process or process group. It records exit, signal, timeout, or cancellation state before emitting an event. The child must not wait for Codex.

This pattern fits builds, training, exports, batch transforms, and long file operations.

### Native remote event

Use a provider webhook, queue event, callback, or event stream. Verify its signature or token, store replay metadata, and fetch authoritative state from the provider.

Do not place webhook text, logs, artifact contents, or user-controlled descriptions in the wake prompt.

### Trusted relay

Use a relay when a native event cannot reach local ingress. The relay receives only the permission needed to inspect the exact target. It forwards authenticated identifiers and does not execute untrusted operation code.

A dedicated Luna 5.6 medium relay or subagent may validate durable evidence and summarize an event for the root model. It must remain read-only and must not replace the direct root-delivery path.

### Local non-model watcher

Use this fallback when no event subscription exists. Poll one registered immutable target with a fixed interval, deadline, total lifetime, and terminal-state mapping.

The watcher may fetch exact status, validate identity, record source truth, and emit a durable event. It must not search for related work, interpret results, choose a next action, change state outside its queue, or spend model turns checking progress.

### No observable source

Do not promise automatic wake without a native event, exact status read, or safe watcher. Stop before launch unless the user authorizes execution without automatic continuation.

## Registration and Recovery

Use this order:

1. Generate stable watch and dispatch-correlation IDs.
2. Capture the task, effective permission profile, approval policy, and goal snapshot.
3. Persist the prepared v2 watch.
4. Arm the event source or watcher.
5. Launch or attach.
6. Bind the immutable target and attempt IDs atomically and claim matching early events.
7. Reconcile current source state.
8. Persist any already-observed event.
9. Enter owned goal wait if the active goal has no immediate work until the next event.

If an API returns its target ID only after dispatch, require lookup by a stable correlation ID or a durable authenticated early-event inbox. Do not dispatch work that can become unidentifiable after a lost acknowledgment.

For existing work, reject mutable names, broad filters, and "latest" selectors. Require the exact process, job, run, transfer, request, or attempt ID.

After restart, read only exact registered v2 roots. Preserve accepted deliveries, reconcile in-flight requests, retry due events, and close source-complete watches that do not require attention.

## Owned Persistent-Goal Wait

An active persistent goal can schedule another model turn after the current turn ends. Enter notify wait after the controller is durable when:

- the goal is `active`;
- no implementation, analysis, state transition, or other immediate work remains;
- the goal API permits `blocked`.

Record a prepared `NotifyWaitLease` before changing the goal. The lease contains the task and loop identities, source IDs, goal `createdAt`, objective hash, token budget, and pre-transition `updatedAt`. Set the goal to `blocked`, then claim ownership only after the response confirms the same goal with its new blocked `updatedAt`.

A lost or malformed transition response makes the lease `uncertain`. It never confers ownership.

At wake:

1. Read the current goal.
2. Require `blocked`, the same goal identity, and the exact owned blocked `updatedAt`.
3. Set that goal to `active` and persist the returned activation revision.
4. Read it again and require the exact activation revision.
5. Deliver the wake.
6. Release the lease on acceptance.

A blocked goal without an exact owned lease is treated as manually blocked. Preserve it. Also preserve `paused`, `complete`, `usageLimited`, and `budgetLimited`.

If wake delivery is explicitly rejected, verify the activation snapshot is unchanged, restore `blocked`, and renew the owned lease. Use the same restoration after complete history proves the message absent. When wake acceptance is uncertain, leave the goal unchanged until reconciliation.

Codex 0.146.0 goal updates have no compare-and-set field. A user, app, remote-control client, or other controller can write between the notifier's read and write. `createdAt`, the objective hash, token budget, and `updatedAt` detect changes around that window, but cannot close it. This is the non-atomic behavior accepted by `research_compatibility`. It is unrelated to legacy-format support.

## State Machines

Track lifecycle, delivery, and goal wait independently.

| Lifecycle | Meaning |
|---|---|
| `prepared` | Context and intent are durable; no target is bound |
| `armed` | Event source or watcher is ready |
| `active` | Immutable target and attempt are registered |
| `complete` | Source reached a supported terminal state |
| `closed` | Source handling and required delivery are complete |

| Delivery | Meaning |
|---|---|
| `none` | No event or attention predicate is false |
| `pending` | A durable event requires delivery |
| `in_flight` | The request boundary is durable and one send is active |
| `uncertain` | The request may have reached app-server |
| `retry_due` | A transient or proven-absent attempt can retry |
| `accepted` | App-server accepted start or steer |
| `blocked` | Delivery needs configuration, context, or manual recovery |

| Goal wait | Meaning |
|---|---|
| `prepared` | Pre-transition goal identity is durable |
| `blocking_in_flight` | The block request crossed its durable boundary |
| `owned` | The exact blocked revision was acknowledged |
| `activation_in_flight` | Owned activation is being attempted |
| `activated` | The exact active revision was acknowledged |
| `released` | Wake acceptance ended wait ownership |
| `uncertain` | Goal-transition or wake acceptance needs reconciliation |

Write source truth first:

```text
lifecycle: active -> complete
delivery:  none -> pending -> in_flight -> accepted
lifecycle: complete -> closed
```

Acknowledgment loss follows:

```text
delivery:  in_flight -> uncertain
history match: accepted
proven absence: retry_due
incomplete history: blocked
```

Never rewrite operation status because delivery failed.

## Event Identity and Request Boundaries

Deduplicate by the strongest immutable provider identity. Otherwise derive a stable UUID from source namespace, target ID, attempt ID, event kind, and occurrence identity. Provider delivery-attempt IDs are replay metadata.

Enforce an atomic event insert and atomic delivery claim under per-task serialization. Reuse the logical event ID as `clientUserMessageId` for correlation, not as the durable deduplication store.

Persist `in_flight`, the attempted RPC method, and request time before transport write. A proven pre-send failure can retry. Any failure after the request may have reached app-server is `uncertain`.

Reconcile through `thread/read` with `includeTurns: true`. A matching `userMessage.clientId` proves acceptance and identifies the turn. Complete history without a match proves absence. Incomplete, stale, malformed, or unavailable history proves neither.

Retain accepted event IDs for at least the provider replay horizon and watch-retention period. Retain unmatched authenticated early events through registration and recovery.

## Codex 0.146.0 Delivery

The shared runtime, not repository adapters, owns app-server delivery:

1. Discover a running 0.146.0 or later daemon.
2. Initialize and resume the captured task.
3. Require the same non-null permission profile and approval policy.
4. Read the goal and apply the owned-wait rules.
5. Read the task and current turns.
6. Start an idle task under `research_compatibility`, or steer exactly one active turn with `expectedTurnId`.
7. Persist acceptance only after the response identifies the accepted turn.
8. Reconcile uncertain requests by exact client message ID.

`thread/read` followed by `turn/start` is a time-of-check/time-of-use race. A notifier lock does not cover user input, app input, remote control, or another client. `research_compatibility` accepts the race because 0.146.0 has no atomic idle-start precondition. `strict` keeps the event blocked instead.

Never set `model` or `effort` on a root `turn/start`. In 0.146.0, those root overrides remain selected for later turns. `turn/steer` uses the current turn's model.

Model selection is allowed only for a dedicated relay target. Use Luna 5.6 medium for read-only scheduled checks, relay/subagent summaries, or other low-value non-mutating work. The root model owns goal changes, launches, recovery, scientific decisions, and code changes.

Queued agent mail can wake sleeping agents in 0.146.0. Treat it as an optional relay optimization. Durable direct root delivery remains the fallback and correctness path.

## Version-2 Cutover

Version 2 has separate namespaces:

- global watches: `${CODEX_HOME:-$HOME/.codex}/notify-wake/v2/`;
- research events: `<registered-root>/.notify-wake/v2/`.

Reject version-1 files and pre-0.146 response shapes. Do not parse, migrate, or requeue them.

Before cutover, prove that no old watch, run, supervisor, or controller is live. Keep old files in place. Write a manifest containing:

- canonical source commit and contract version;
- file counts and SHA-256 hashes;
- live-state inspection result;
- disposition for each old state class;
- exact list of pending events intentionally superseded.

## Security Boundaries

- Validate provider payloads, paths, identifiers, v2 state, and app-server responses.
- Authenticate public ingress and prevent replay from creating another event.
- Keep trusted delivery code separate from untrusted operation code.
- Keep credentials, task IDs, permission context, and socket paths out of untrusted jobs.
- Keep raw logs, stack traces, model output, user data, secrets, and artifact contents out of wake input.
- Bound persisted errors and remove control characters.
- Restrict state and sockets with host-appropriate permissions.
- Never let the operation depend on Codex availability.
- Test only with fake app servers and fake sources.

## Review Questions

Reject a design unless it answers:

- What exact operation and attempt are observed?
- What prelaunch evidence supports automatic use for strictly more than 10 minutes, or did the user explicitly request it?
- Which source is authoritative?
- How are registration races and lost dispatch acknowledgments recovered?
- Which outcomes require attention?
- Where is the exact registered v2 root?
- How are duplicates, concurrent delivery, retries, and restarts handled?
- How is uncertain acceptance reconciled without a blind resend?
- When does the active goal enter owned wait?
- How are manual goal blocks distinguished from owned notify waits?
- What non-atomic race does the selected policy accept?
- Does root delivery omit model and effort?
- Which code remains provider-specific, and which calls the shared runtime?
- What happens when the source, watcher, relay, or app-server is unavailable?
- How does the design avoid model polling?
- Does every wake report the fixed elapsed time before notification?

## Acceptance Scenarios

| Scenario | Required result |
|---|---|
| Success needs analysis | One accepted wake followed by source-backed analysis |
| Success completes the objective | Durable silent close |
| Failure, timeout, cancellation, or stall | One durable attention event and accepted wake |
| Automatic use estimated at 10 minutes or less, or unknown | Do not arm notify-wake; use an ordinary wait or bounded status check |
| Delivered wake | Include fixed elapsed seconds from operation or observation start to terminal event |
| Duplicate source delivery | No second logical event or accepted wake |
| Lost wake acknowledgment | Match means accepted; complete absence means retry; incomplete history blocks |
| Idle root task, compatibility policy | Root `turn/start` without model or effort |
| Idle root task, strict policy | Event remains blocked |
| Active task | `turn/steer` with exact `expectedTurnId` |
| Exact owned blocked goal | Activate, verify, deliver, then release |
| Manual, changed, or uncertain blocked goal | Preserve it without activation |
| Explicit wake rejection after activation | Restore blocked and renew ownership |
| Uncertain wake after activation | Leave the goal unchanged until reconciliation |
| Old state or response shape | Reject with cutover-required error |
| No observable source | Stop before launch or report no automatic wake |
