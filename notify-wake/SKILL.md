---
name: notify-wake
description: Set up or inspect durable task wakeups. Use automatically only for operations estimated before launch to take strictly more than 10 minutes, or on explicit request.
---

# Notify and Wake

Wake the originating task when an exact operation requires attention.
Keep source completion independent of Codex availability.

## Invocation and Boundaries

Automatic use requires a defensible prelaunch estimate of strictly more than 10 minutes.
Exactly 10 minutes and unknown runtimes use ordinary waits or bounded status checks.
Explicit requests bypass the duration gate. Design and debugging need no runtime threshold.

Invocation does not authorize the underlying operation, credentials, services,
or wider permissions. Honor existing task authority without asking again.

For a local Unix command or Linux PID, use the locked CLI below.
For another provider or adapter changes, read
[design patterns](references/design-patterns.md).
Read that reference for delivery, owned goal waits, recovery, or cutover diagnosis.

## Source and Runtime Contract

The canonical source is `notify-wake/` in [TidalPaladin/skills](https://github.com/TidalPaladin/skills).
Resolve the exact containing commit with `git rev-parse HEAD`.
Repository adapters must pin package version `1.0.0` from that full SHA.
They may own events, trusted prompts, registered roots, controllers, and retry timing.
Keep transport, authority capture, goal lifecycle, delivery, and reconciliation in the shared runtime.

The runtime supports Python 3.11 through 3.14 and requires Codex app-server 0.146.0 or a later schema-conforming release. It exposes:

- `WakeContext`, `WakeRequest`, `DeliveryOutcome`, and `NotifyWaitLease`.
- app-server socket discovery, transport, authority capture, delivery, and reconciliation.
- `DeliveryPolicy.RESEARCH_COMPATIBILITY`, which is the default.
- explicit `DeliveryPolicy.STRICT`.
- `enter_notify_wait()` and `deliver_wake()`.

`research_compatibility` permits the non-atomic transitions documented in
[design patterns](references/design-patterns.md).
It does not permit old state or response formats.

State contract version 2 is mandatory. Global watches live under `${CODEX_HOME:-$HOME/.codex}/notify-wake/v2/`. Research queues live under the registered root's `.notify-wake/v2/`. Do not parse, migrate, requeue, or conditionally support version-1 contexts, notifications, ledgers, or response shapes. Preserve old files only as inert audit evidence. Report version mismatches as `unsupported notify-wake contract; cutover required`.


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

For a watched `uv` command in another project, prefix it with `env -u VIRTUAL_ENV`.
This prevents notifier-environment leakage.

Use `--format json` for automation. The CLI returns `0` for success, `1` when durable state requires attention, and `2` for a runtime or state error.


## Completion and Recovery

Before launch, define the exact target, attention predicate, deadline, and fallback.
Let the bundled controller capture authority, persist the watch, bind the target,
and reconcile registration races. Return control only after the controller is durable.
Enter an owned goal wait when no immediate work remains and the goal API permits it.

Keep `research_compatibility` as the default. Preserve authority-mismatch blockers,
manual goal blocks, and uncertain delivery state. Never retry an uncertain
request until authoritative history proves it absent.

Never set `model` or `effort` on a root `turn/start`.
The root model owns launches, recovery, goal changes, and substantive decisions.
Use Luna 5.6 medium only for read-only checks or dedicated relays.

Every wake must report `Elapsed before notification: <seconds> seconds`.
Measure from operation start to the terminal event, or from observation start
when the earlier start is unavailable. Keep this value fixed across retries.
Send validated identifiers, status, times, and evidence paths only.
Keep secrets, logs, remote content, and artifacts out of wake input.

If no reliable event source or exact watcher exists, report the missing capability.
Do not promise automatic continuation or substitute model polling without authorization.

Report the runtime estimate, exact target, armed adapter, watch location,
attention predicate, deadline, and fallback.
