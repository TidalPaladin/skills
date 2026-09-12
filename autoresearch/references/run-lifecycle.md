# Research Run Lifecycle

Read before launch and during monitoring, recovery, retention, or adapter changes.

## Version Control and Provenance

Before launch:

- Work on a study branch, not a protected branch.
- Keep experiment adapters in the current repository and reusable primitives in the appropriate shared library.
- Run repository formatting, lint, type, and test gates.
- Verify that code and required dependencies are committed, immutable, available, and matched by the execution environment.
- Resolve managed study paths before launch. Reject repository roots, broad parent directories, symlink escapes, and paths that overlap source, configuration, dependencies, or input data.
- Treat changes confined to recorded managed paths as expected research state. Record their exact paths and prelaunch hashes or inventories.
- Refuse unrelated dirty changes unless the user authorizes an exception. Record the exact diff for each exception.
- Correct stale or unpushed study-scoped source with `$git-github-workflow no pr` when safe.
- Refuse a mismatched source environment unless the user authorizes an exception and the exact state is recorded.
- Do not commit or push merely for recoverability. Use the authorized Git workflow only when the study needs immutable provenance or publication.

Record repository commits, branch state, environment hashes, data hashes, seeds, hardware, commands, configuration, runtime versions, tracker identity, and managed paths. Keep uncommitted research records locally recoverable. Publish them only when authorized.

## Resource and Storage Safety

Before each launch, verify that:

- the required execution capacity is available.
- concurrency limits are respected.
- the supervisor enforces the timeout.
- free space covers jobs, checkpoints, logs, temporary files, and atomic replacement.
- storage estimates use a recent artifact size or a recorded fallback.
- output paths resolve to the exact study and run directories.

Never delete legacy or unmanaged artifacts during an autonomous study. Apply managed retention only when the user authorized its policy. Require a terminal run, durable provenance, complete records, and an exact run directory. Log the target and byte count before deletion. State that deleted outputs cannot be recovered.

## Launch and Persistent State

Run jobs under a detached supervisor or another recoverable process. Before launch, persist the originating Codex task identifier when the current surface exposes it.

Write atomic state that contains:

- study phase, run status, attempt, and decision.
- process and supervisor identities.
- immutable operation-start time, check-in, heartbeat, occurrence, and finish times.
- cumulative active runtime and progress counters.
- checkpoint paths and resume state.
- tracker identity and health.
- errors and retryability.
- artifact disposition.
- routine-check count, last interval, and next check time.
- the notification launch decision and its recorded runtime estimate and basis.

Write terminal source truth before you create notification delivery state. Treat the research terminal record as canonical source truth. Record the event identifier, status, occurrence time, elapsed evidence, and evidence path. Resume the same experiment with its domain state, progress counters, random-state policy, tracker identity, and cumulative runtime. Do not reset convergence clocks or the monitoring budget after resume.

## Terminal Notifications

Use `$notify-wake` for qualifying durable event delivery. Follow its strict automatic-invocation threshold and explicit-request exception. For ineligible or unknown estimates, use an ordinary bounded wait or status check.

Keep research event production and attention predicates in the repository adapter. Define whether success needs analysis and whether failure, supervisor loss, or a progress stall needs attention. Persist terminal source truth before queuing any notification.

Delegate wake authority capture, delivery state, reconciliation, retries, root delivery, and owned goal waits to `$notify-wake`. Make each notification reference the canonical event identifier and evidence path. Do not copy or reimplement its app-server transport. Preserve its lifecycle-versus-delivery separation, immutable elapsed evidence, trusted-payload restrictions, authority mismatch behavior, and manual goal blocks.

Keep a sparse watchdog because a supervisor or host failure can prevent event production. Assign watchdog event delivery to the repository `$notify-wake` adapter or controller. A read-only monitor can report stale state but cannot deliver the event. On wake, validate the persisted terminal evidence before acting. Cancel only the terminal run's next routine check. Preserve monitoring for other active runs.

## Monitoring Cadence

Use event-driven terminal notifications with sparse polling as a fallback. A healthy run should need no more than five routine checks, including startup, progress, and planned terminal verification. A terminal wake is not a poll.

At every check, report the timestamp, progress, elapsed wall time, rate, resource status, and next check with its reason. Check shortly after launch to detect startup failures. Use a bounded adapter interval until the first positive progress delta. Require the adapter to define a monotonic scalar progress counter and its planned terminal value. After every positive progress delta, calculate:

```text
rate = elapsed_seconds_since_prior_check / progress_delta
remaining_checks = 5 - routine_check_count
if remaining_checks > 0:
    target_gap = ceil(remaining_progress / remaining_checks)
    next_interval = clamp(target_gap * rate, minimum_interval, maximum_interval)
elif allowed_safety_check:
    next_interval = clamp(adapter_safety_interval, minimum_interval, maximum_interval)
else:
    next_interval = none
```

Do not apply the formula when `remaining_checks <= 0`. Record the reason for any over-budget safety check. Recalculate after each check and preserve the schedule across resume.

A monitor may inspect state, recent logs, metrics, hardware, and storage. It must not launch jobs, reconcile state, or send notifications. It must not change code, Git state, artifacts, or study decisions. Report stale or inconsistent state to the supervisor or recovery controller.

## Domain Adapter Contract

Require an adapter to define:

- `preflight`, `launch`, `status`, `monitor`, `summarize`, `inventory`, and `storage-report` operations.
- checkpoint and resume semantics.
- progress-counter and timeout behavior.
- managed-path classification.
- metric names, convergence calculations, and data-leakage controls.
- tracker behavior and local fallback.
- single-writer research-log and locking semantics.
- promotion and replication thresholds.
- terminal event production and attention predicates.
- the `$notify-wake` integration boundary and bounded fallback.

Provide an automated conformance check for these requirements. The repository can choose its file layout, operation signatures, and exit-code contract. Document and test those choices before launch.

Keep this skill responsible for research discipline, recoverability, and safety. Keep the adapter responsible for domain mechanics.
