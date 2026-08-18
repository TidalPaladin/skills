---
name: notify-wake
description: Replace model polling with durable event notifications that wake the originating Codex task. Invoke automatically only for compute, I/O, CI, builds, transfers, queued work, or other machine-observable operations defensibly estimated before launch to take strictly more than 10 minutes. Also use when the user explicitly requests notify-wake, or when designing, reviewing, or debugging wake delivery regardless of runtime.
---

# Notify & Wake

Use an event source or a run-specific non-model watcher to wake Codex only when agent attention is required. Keep the operation independent of Codex availability.

Read `references/design-patterns.md` before selecting an adapter, registering a watch, or reviewing a notify-wake design.

## Source and Runtime Contract

The canonical source for this skill and the `notify-wake-runtime` Python package is `notify-wake/` in [TidalPaladin/skills](https://github.com/TidalPaladin/skills) at the exact commit that contains this file. Resolve that immutable source revision with `git rev-parse HEAD` in the containing repository. Repository adapters must pin package version `1.0.0` from that full commit SHA. They may own event production, trusted prompts, registered roots, controllers, and retry timing. They must not copy the app-server transport, authority capture, goal lifecycle, wake delivery, or reconciliation code.

The runtime supports Python 3.11 through 3.14 and requires Codex app-server 0.146.0 or a later schema-conforming release. It exposes:

- `WakeContext`, `WakeRequest`, `DeliveryOutcome`, and `NotifyWaitLease`;
- app-server socket discovery, transport, authority capture, delivery, and reconciliation;
- `DeliveryPolicy.RESEARCH_COMPATIBILITY`, which is the default;
- explicit `DeliveryPolicy.STRICT`;
- `enter_notify_wait()` and `deliver_wake()`.

`research_compatibility` permits the current non-atomic idle start and goal transitions described below. It does not mean compatibility with old state or response formats.

State contract version 2 is mandatory. Global watches live under `${CODEX_HOME:-$HOME/.codex}/notify-wake/v2/`. Research queues live under the registered root's `.notify-wake/v2/`. Do not parse, migrate, requeue, or conditionally support version-1 contexts, notifications, ledgers, or response shapes. Preserve old files only as inert audit evidence. Report version mismatches as `unsupported notify-wake contract; cutover required`.

## Invocation Policy

When deciding automatically, apply this skill only when a defensible prelaunch estimate says the operation will take strictly more than 10 minutes. An estimate of exactly 10 minutes does not qualify. An unknown or weakly supported estimate does not qualify. Use an ordinary tool wait or bounded status check for operations estimated to take 10 minutes or less and for unknown runtimes.

The 10-minute gate does not apply when the user explicitly requests `$notify-wake` or a durable wake path. It also does not prevent design, review, or debugging work that does not arm a watch.

Being asynchronous, detached, remote, or likely to require another status check is not enough by itself to justify automatic invocation. Record the estimate and its basis before selecting this flow so the eventual elapsed time can be compared with the decision.

Invocation does not authorize the underlying operation, network exposure, service installation, schedule creation, credential use, or broader permissions. Obtain that authority through the task's normal workflow.

Choose the first event source that can identify one exact operation:

1. Native callback, webhook, event stream, queue event, or process-exit signal.
2. Trusted relay that authenticates and forwards immutable identifiers.
3. Bounded local non-model watcher for one registered identifier.
4. No automatic wake.

For option 4, stop before launch and report that automatic continuation is unavailable. Do not replace it with model polling unless the user authorizes polling.

## Bundled Local-Process CLI

The synced skill contains a locked `uv` project. Run its preflight before a local command or existing Linux PID:

```bash
notify_wake_skill="${CODEX_HOME:-$HOME/.codex}/skills/notify-wake"
uv run --project "$notify_wake_skill" --locked \
  python "$notify_wake_skill/scripts/notify_wake.py" preflight --format json
```

Public commands:

- `preflight` checks Codex 0.146.0, the managed daemon, authority, and the default delivery policy.
- `run --timeout-seconds N [--wake-on always|failure] [--evidence ABS] -- COMMAND...` registers an owned process before releasing it.
- `attach --pid PID --timeout-seconds N [--expect-start-ticks TICKS] [--evidence ABS]` captures a Linux pidfd and `/proc` start time. It never signals the attached process.
- `wait WATCH_ID` enters an owned persistent-goal wait after the watch is durably armed.
- `status WATCH_ID` reads one exact v2 watch.
- `reconcile WATCH_ID` reconciles one exact uncertain request boundary.

When the watched command runs `uv` for another project, prefix it with `env -u VIRTUAL_ENV` so the notifier environment does not leak into the nested command.

Use `--format json` for automation. The CLI returns `0` for success, `1` when durable state requires attention, and `2` for a runtime or state error.

## Prelaunch Workflow

Before launch or attachment:

1. Record the expected runtime and its basis. Confirm that automatic use clears the strict 10-minute gate, or record that the user explicitly requested the flow.
2. Define the exact operation, immutable target or dispatch identity, attention predicate, and required work for each outcome.
3. Select and preflight the event source, adapter, authentication, durable v2 root, retry trigger, timeout, fallback, and goal-wait behavior.
4. Capture the originating task ID, effective non-null permission profile, approval policy, capture time, and current persistent-goal snapshot.
5. Persist a prepared watch, then arm the event source or watcher.
6. Launch and bind the returned identifier atomically, or attach an already known exact identifier.
7. Reconcile the source immediately to close the registration race.
8. If an active persistent goal has no implementation, analysis, state transition, or other immediate work left, enter notify wait as described below.
9. Return control only after the controller and any goal-wait ownership record are durable.

If dispatch returns its immutable identifier only after starting the operation, require a provider correlation lookup or durable authenticated early-event inbox. Do not launch when a lost dispatch acknowledgment could leave an unidentifiable operation.

## Owned Goal Wait

An armed notification loop should usually block an active persistent goal when no other immediate work remains and the goal API permits blocking. This prevents the persistent goal from scheduling model turns that only rediscover an active operation.

`enter_notify_wait()` performs this sequence:

1. Verify the exact controller or loop identity and require the current goal to be `active`.
2. Persist a prepared lease with the task ID, loop sources, goal `createdAt`, objective hash, token budget, and pre-transition `updatedAt`.
3. Set the goal to `blocked`.
4. Claim ownership only when the response contains the same goal and its new blocked `updatedAt`.
5. Mark a lost or ambiguous transition `uncertain`. Never claim ownership after an uncertain response.

Wake delivery may change `blocked` to `active` only when the current goal identity and `updatedAt` match an acknowledged owned lease. A blocked goal without that lease, with changed metadata, or with an uncertain lease is treated as manually blocked and remains unchanged. Preserve `paused`, `complete`, `usageLimited`, and `budgetLimited`.

If a wake is explicitly rejected or complete history proves it absent after activation, restore the same unchanged goal to `blocked` and renew the lease. If delivery is uncertain, leave the goal unchanged until history reconciliation proves acceptance or absence.

Codex 0.146.0 has no compare-and-set goal update. A user, app client, remote-control client, or other controller can change the goal between the notifier's final read and write. The lease and exact `updatedAt` checks detect changes before and after that window, but they cannot make the transition atomic. `research_compatibility` accepts this documented race. `strict` leaves idle starts and blocked-goal activation blocked.

Only resume a blocked goal through an owned notify-wait lease. Never resume a goal that the user or another controller blocked.

## Delivery and Reconciliation

Use a stable logical event UUID and at-least-once delivery. Enforce durable event uniqueness and serialize delivery per originating task. Persist `in_flight`, attempted RPC method, and request-sent time before writing the request.

- Explicit rejection or a proven pre-send failure becomes `retry_due`.
- Loss after the request might have reached app-server becomes `uncertain`.
- A permission, approval, schema, state, or ownership mismatch becomes `blocked`.
- Acceptance is durable only after app-server returns the accepted turn or complete task history contains the exact `clientUserMessageId`.

For uncertain delivery, request `thread/read` with `includeTurns: true` and search `userMessage.clientId`. Retry only when complete authoritative history proves the message absent. Incomplete, stale, or unavailable history cannot prove absence.

Default `research_compatibility` delivery starts an idle root turn or steers the exact active turn. The idle check and `turn/start` remain non-atomic because other clients are outside the notifier's lock. `strict` blocks an idle start. Both policies require `expectedTurnId` for `turn/steer`, stable event IDs, exact authority verification, durable request boundaries, and uncertain-acknowledgment reconciliation.

Keep lifecycle truth separate from delivery state. Record source completion before notification delivery. Delivery failure must never change the operation result.

## Model Ownership

Never include `model` or `effort` in `turn/start` for the user's root conversation. Codex 0.146.0 applies root start overrides to later turns, so a cheap wake override would change the active conversation's model. `turn/steer` retains the active turn's model.

GPT-5.6 Luna with medium reasoning is reserved for:

- read-only scheduled checks;
- dedicated relay tasks or model-selectable subagents that validate durable wake evidence and send a short message to the root agent;
- other explicitly low-value, non-mutating work.

The root model owns goal transitions, launches, recovery, scientific decisions, code changes, and other substantive work. A Luna relay or subagent can summarize an event, but it must not replace direct root delivery as the correctness path. [Codex 0.146.0](https://github.com/openai/codex/releases/tag/rust-v0.146.0) can wake sleeping agents for queued agent mail; use that behavior only as an optimization when supported.

## Adapter Contract

Repository and provider adapters retain these responsibilities:

- `preflight`, `arm`, and exact target registration;
- authoritative observation and attention-predicate evaluation;
- atomic source-event insertion and per-task delivery claims;
- trusted wake prompt construction;
- registered-root validation, retry timing, and bounded controller lifetime;
- source reconciliation and closure.

Persist the v2 contract version; watch, operation, attempt, and event IDs; source and immutable target identity; operation or observation start time; evidence paths; captured task authority; goal-wait lease; lifecycle state; delivery state; request boundary; retry and acceptance metadata.

Every wake input must include `Elapsed before notification: <seconds> seconds`, computed from the registered operation start to its terminal event. For an attached operation whose true start is unavailable, compute from the start of observation and label that limitation in durable state. Keep this value fixed across delivery retries. This elapsed value lets the resumed agent compare actual runtime with the automatic-invocation gate.

Wake input must contain only validated identifiers, status, timestamps, the numeric elapsed value, and evidence locations. Do not include raw logs, stack traces, remote output, artifacts, secrets, or untrusted content. The root task reads and validates durable evidence after wake.

## Cutover and Recovery

Before a v2 cutover, verify that no version-1 watch, run, supervisor, or controller is live. Keep old files in place as inert history. Write one cutover manifest with counts, hashes, disposition, contract version, and canonical source commit. Pending events that are intentionally superseded must be listed; never deliver them through v2.

On restart, scan only an exact registered v2 root. Reconcile each target from its authoritative source and every `in_flight` or `uncertain` delivery from task history. Do not discover, migrate, or claim unrelated or version-1 work.

In planning mode, return:

`Operation | Expected runtime and basis | Target identity | Event source | Adapter | Attention predicate | Watch location | Codex delivery | Fallback | Validation`

In execution mode, report the runtime estimate and basis or explicit user request, armed adapter, immutable target or correlation identity, attention predicate, v2 watch location, timeout, and fallback before returning control.
