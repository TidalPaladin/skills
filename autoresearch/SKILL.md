---
name: autoresearch
description: Run bounded, reproducible, recoverable empirical research studies. Use when Codex must define hypotheses, change code or configuration, launch and monitor experiments, compare or replicate results, record local and external tracking data, recover interrupted work, manage artifacts safely, or react to run completion and crashes.
---

# Autoresearch

Run empirical studies as controlled, recoverable experiments. Treat every result as provisional until its protocol, provenance, and evaluation evidence support the conclusion.

## Operating contract

Preserve the user's scope and authority:

- Read and inspect within the repository and declared experiment environment.
- Modify code, configuration, state, logs, and managed artifacts only within the study scope.
- Do not publish, push, delete artifacts, change protected branches, alter production systems, or exceed recorded resource limits without explicit authorization.
- Escalate when a decision would change the study design, resource use, retention policy, or authorized scope.
- Do not treat invocation of this skill as authorization for Git publication or destructive retention.

Allow planning and recovery without an active persistent goal. Before launching any experiment, require an active goal whose completion criteria cover the study. If none is active, stop before launch and ask the user to start one.

Use a repository's research skill or domain adapter for commands, configuration, datasets, metrics, training, evaluation, schedulers, hardware, checkpoints, and notifications. Do not invent missing domain mechanics.

## Study definition

Recover existing state and artifacts before creating a new study. Then record:

- study identifier, research question, falsifiable hypothesis, and proposed mechanism;
- baseline and candidate variants;
- exact code, configuration, dependency, and environment references;
- data source, split, preprocessing, and leakage controls;
- seeds, repetitions, initialization, subsets, and pairing rules;
- primary and secondary metrics;
- convergence definition and common comparison horizons;
- resource limits, timeout, concurrency, and storage budget;
- promotion, replication, rejection, and stopping criteria;
- artifact retention policy;
- local research-log location and publication procedure;
- managed study paths for the research log, atomic state, and run artifacts;
- external tracker provider, account, project, authorization, approved data classes, and availability, when applicable.

Mark unknown items explicitly. Resolve each one before launch or record the limitation and obtain approval when it changes study validity, cost, or recoverability.

## Experimental discipline

Use this order:

1. Recover existing study state and inspect prior artifacts.
2. State one concrete question and one falsifiable hypothesis.
3. Define the baseline before interpreting variants.
4. Change one mechanism at a time unless the study tests an interaction.
5. Fix the evaluation protocol before inspecting outcomes.
6. Keep training, validation, and test roles distinct.
7. Pair seeds, initialization, subsets, and training conditions when the comparison requires it.
8. Use deterministic selection and record every random seed.
9. Record failed, crashed, timed-out, cancelled, censored, and incomplete runs.
10. Record a new study or dated protocol amendment before changing a hypothesis or metric after seeing results.

Prefer common-horizon comparisons. Report endpoint quality and the cost or time needed to reach meaningful targets. Report effect sizes, uncertainty, paired differences, and limitations. Do not claim statistical significance from a sample size that cannot support it.

## Local research log

Maintain a local Markdown log for every study. Treat it as the canonical study index, decision record, and recovery entry point. Use a repository-defined location when one exists. Otherwise use `research/<study-id>/research-log.md`.

Create the study header before the first launch. Include:

- question, hypothesis, and proposed mechanism;
- baseline, variants, seeds, repetitions, and evaluation protocol;
- code, environment, dataset, split, and preprocessing provenance;
- primary and secondary metrics;
- resource, promotion, replication, stopping, and retention rules.

Append one terminal entry for every run attempt. Include:

- run, attempt, and terminal-event identifiers, variant, seed, status, and timestamps;
- exact code, configuration, dependency, environment, data, and hardware references;
- primary results, convergence or progress result, uncertainty, and resource cost;
- tracker provider, run identifier, and URL when present;
- local artifact paths and retention disposition;
- decision, limitations, and follow-up.

Use the study coordinator as the single writer for the shared Markdown log. Supervisors and monitors may write per-run state but must not edit the shared log. Assign every log update a stable operation identifier before writing, including header creation, terminal entries, exceptional events, and amendments. Reuse that identifier across retries and recovery. Serialize each update as follows:

1. Acquire an exclusive lock at a stable sibling path that is not replaced with the log.
2. Re-read the log after acquiring the lock.
3. Deduplicate every log update by its stable operation identifier. For terminal entries, also deduplicate by study, run, and attempt identifiers even if a retry presents a different event identifier.
4. Render the prior bytes plus one complete update into a temporary file in the same directory.
5. Flush and sync the temporary file, replace the log atomically, sync the directory, and release the lock.

If the update cannot complete, leave the operation pending and do not mark it recorded. Order concurrent entries by lock acquisition, and use recorded terminal timestamps rather than append order to establish chronology.

Never change historical entry content during atomic replacement. Correct mistakes with a dated amendment that identifies the prior entry and explains the correction. Keep routine polling details in atomic runtime state. Append exceptional events that affect interpretation, including stalls, retries, tracker loss, protocol amendments, and incomplete runs.

## External experiment tracking

Treat W&B and other trackers as optional telemetry stores. They do not replace the local research log.

Before any external write, require an approved external tracker destination and record the user's explicit authorization. Verify the provider, account, project, access controls, and retention policy. Apply the repository's data classification and consent rules. Exclude secrets, credentials, personal or protected data, proprietary data, and raw samples unless their transfer is explicitly approved. Use local-only tracking when approval or classification is missing or ambiguous.

When a tracker is available:

- Store complete curves, tables, logs, and large telemetry there when useful.
- Keep local provenance, headline results, uncertainty, decisions, and artifact disposition even when the Markdown entry is concise.
- Record the provider, project, run identifier, and URL.

When no tracker is available:

- Record complete evaluation metrics, aggregate statistics, convergence results, local artifact paths, and analysis commands in the Markdown log.
- Preserve local raw metrics and logs needed to reproduce the summary.

If tracking fails during a run, record the outage. Continue only when local logs and artifacts still satisfy the recovery and evaluation protocol. Otherwise mark the run incomplete or censored. If a run is later backfilled into a tracker, append a dated amendment that includes the tracker identity and a stable operation identifier instead of editing the original entry.

Require `summarize` to produce a Markdown-ready terminal summary and state whether complete detail is local or stored in an external tracker.

## Version control and provenance

Before launch:

- Work on a study branch, not a protected branch.
- Keep experiment adapters in the current repository and reusable primitives in the appropriate shared library.
- Run repository formatting, lint, type, and test gates.
- Verify that code and required dependencies are committed, immutable, available, and matched by the execution environment.
- Resolve managed study paths before launch. Reject repository roots, broad parent directories, symlink escapes, and paths that overlap source, configuration, dependency, or input-data files.
- Treat changes confined to the study specification's managed study paths as expected research state, not dirty source. Record their exact paths and prelaunch hashes or inventories.
- Refuse unrelated dirty source, configuration, dependency, or data changes unless the user authorizes an exception and the exact diff is recorded.
- Refuse a stale, unpushed, or mismatched source environment unless the user authorizes an exception and the exact state is recorded.
- Do not commit or push merely because this skill requires recoverability. Obtain authorization and use `$git-github-workflow` for Git publication.

Record at minimum:

- repository, dependency, and imported-source commits;
- branch names and dirty states;
- lockfile or environment hash;
- dataset and split hashes;
- seed and hardware identity;
- complete command and copied configuration;
- hostname, runtime versions, and package versions;
- tracker identity and URL, when present;
- local state, log, and artifact paths.

Keep uncommitted research records locally recoverable. Publish them only when authorized.

## Resource and storage safety

Before each launch, verify:

- hardware or execution capacity is available;
- concurrency limits are respected;
- the timeout is enforced by the supervisor;
- free space covers active jobs, checkpoints, logs, temporary files, and atomic replacement;
- storage estimates use a recent checkpoint size or a recorded fallback;
- output paths resolve to the exact study and run directories.

Never delete legacy or unmanaged artifacts during an autonomous study. Apply managed retention only when the user authorized the policy and all of these conditions hold:

- the run is terminal;
- its decision and provenance are recorded;
- required local records are durable and any authorized publication is complete;
- the resolved target is the exact run directory;
- the retention policy permits deletion;
- the target and byte count are logged before deletion.

Keep artifacts needed for the baseline, confirmed results, retries, audits, and reproduction. State that deleted weights and outputs cannot be recovered.

## Launch and persistent state

Run jobs under a detached supervisor or another recoverable process. Before launch, persist the originating Codex thread identifier when the current surface exposes one.

Write atomic state containing:

- study phase, run status, attempt, and decision;
- process and supervisor identities;
- start, check-in, heartbeat, and finish times;
- cumulative active runtime;
- current and planned epochs or another progress counter;
- checkpoint paths;
- tracker identity and health;
- errors and retryability;
- artifact disposition;
- routine check count, last interval, and next check time;
- notification event, attempts, errors, acceptance time, and delivery state.

Write terminal state atomically on completion, failure, crash, timeout, or cancellation. Resume the same experiment with model, optimizer or scheduler, progress counters, random-state policy, tracker identity, and cumulative active runtime. Do not reset convergence clocks or the monitoring budget after resuming.

## Terminal notifications

Require the supervisor to write terminal state before notifying Codex. Add a domain-adapter `notify` operation with this logical input:

- unique event identifier;
- study, run, and attempt identifiers;
- terminal status and ISO 8601 occurrence time with UTC offset;
- terminal-state path;
- originating Codex thread identifier.

When supported, resume the recorded thread with the Codex SDK or app-server and inspect its runtime status. App-server clients may use `thread/resume` and `thread/read`; see [Codex App Server](https://developers.openai.com/codex/app-server/). Deliver the wake input according to thread state:

- If the thread is idle, use `turn/start`.
- If a turn is active, use `turn/steer` with the expected active turn identifier.
- If status is unknown or changes during delivery, keep the event queued and retry after reading status again. Do not start a second concurrent turn.

Serialize wake delivery per thread. Mark an event accepted only after `turn/start` or `turn/steer` accepts it. Prefer the SDK, stdio, or a Unix socket. Do not depend on the experimental non-loopback WebSocket transport.

Keep wake prompts small. Include identifiers and the terminal-state path, not raw logs, stack traces, or other untrusted run output. Re-read and validate persisted state before acting.

Use at-least-once delivery:

- persist a pending event before sending;
- retry failures with bounded exponential backoff and jitter;
- record attempts, last error, acceptance time, and final delivery state;
- deduplicate by event identifier;
- make repeated delivery safe.

On receipt, cancel only the terminal run's next routine poll. Preserve or recompute the study watchdog and routine polls for remaining active runs. Report the wake time, validate artifacts and provenance, update the research log, and continue the study decision flow.

Treat child exit, nonzero exit status, fatal signal, timeout, and cancellation as terminal events handled by an outer supervisor. A supervisor or host failure can prevent notification. Preserve a sparse watchdog that detects stale heartbeats and missed terminal events. When the current surface supports scheduled tasks, return to the same chat so monitoring retains its context; see [Scheduled tasks](https://learn.chatgpt.com/docs/automations). If thread resume is unavailable, record the limitation and use the watchdog as the primary monitor.

## Monitoring cadence

Use event-driven terminal notifications with sparse polling as a fallback. A healthy run should need no more than five routine checks, including startup, progress, and planned terminal verification. A terminal wake event is not a poll.

At every check-in, report:

- the current check time as an ISO 8601 timestamp with UTC offset;
- the prior and current epoch or progress counter;
- progress since the prior check;
- elapsed wall time and observed progress rate;
- run, tracker, hardware, and storage status;
- the next planned check time and scheduling reason.

Check shortly after launch to catch startup failures. Use the next check to obtain a progress-rate estimate. After every positive epoch delta, calculate:

```text
seconds_per_epoch = elapsed_seconds / epoch_delta
remaining_checks = 5 - routine_check_count
if remaining_checks > 0:
    target_epoch_gap = ceil(remaining_epochs / remaining_checks)
    next_interval = clamp(target_epoch_gap * seconds_per_epoch, minimum_interval, maximum_interval)
elif allowed_safety_check:
    next_interval = clamp(adapter_safety_interval, minimum_interval, maximum_interval)
else:
    next_interval = none
```

Do not apply the formula when `remaining_checks <= 0`. For an allowed over-budget safety check, use a separate adapter-defined interval clamped to the polling bounds and enforced timeout, and record the exception reason. Recalculate after each check and preserve the schedule across resume. If epochs are unavailable, use the adapter's equivalent progress counter or bounded wall-clock estimate and record the fallback.

Allow extra short safety checks after startup failure, a stall, retry, phase change, counter reset, notification failure, or unexpected overrun. Record why each check exceeded the routine budget. A monitor may inspect state, recent logs, metrics, hardware, and storage. It must not launch jobs, write or reconcile run state, send terminal notifications, change code or Git state, choose winners, summarize final results, delete artifacts, or alter study decisions. Report stale or inconsistent state so the supervisor or recovery controller can reconcile it.

## Analysis and promotion

After a run becomes terminal:

1. Validate artifacts, provenance, and notification state.
2. Compute the predefined metrics and convergence measures.
3. Compare against the baseline at the predefined horizons and thresholds.
4. Promote no more candidates than the study specification permits.
5. Replicate only candidates that meet the recorded promotion rule.
6. Report means, dispersion, paired differences, censored runs, costs, and limitations.
7. Mark a candidate confirmed only after it meets the replication rule.

If no candidate qualifies, record that result and stop unless the trial budget authorizes another experiment.

## Completion and handoff

Complete a study only when:

- all permitted runs are terminal or marked censored;
- required evaluation and replication are complete;
- stored artifacts reproduce the metrics and comparisons;
- provenance and the local research log are complete;
- authorized retention has been applied;
- authorized publication is complete;
- the study identifier recovers the final state.

Report:

- study and run identifiers;
- active, completed, failed, crashed, timed-out, cancelled, and censored runs;
- local log path and tracker URLs;
- primary metrics, uncertainty, convergence, and resource results;
- code, environment, data, and hardware references;
- retained and deleted artifacts;
- notification delivery status;
- unresolved limitations and the next authorized action.

## Domain adapter contract

Require an adapter to define:

- `preflight`
- `launch`
- `status`
- `monitor`
- `notify`
- `summarize`
- `inventory`
- `storage-report`
- checkpoint and resume semantics;
- current and planned epochs or another progress-counter contract;
- polling bounds and timeout behavior;
- managed study path classification;
- metric names and convergence calculations;
- data split and leakage rules;
- tracker behavior and local fallback;
- single-writer research-log and locking semantics;
- promotion and replication thresholds;
- per-thread notification queue and active-turn handling;
- terminal-state and notification delivery behavior.

Keep this skill responsible for research discipline, recoverability, and safety. Keep the adapter responsible for domain mechanics.
