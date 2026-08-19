---
name: autoresearch
description: Run bounded, reproducible, recoverable empirical research studies. Use when Codex must define hypotheses, change code or configuration, launch and monitor experiments, compare or replicate results, record local and external tracking data, recover interrupted work, manage artifacts safely, or react to run completion and crashes.
---

# Autoresearch

Run empirical studies as controlled, recoverable experiments. Treat every result as provisional until its protocol, provenance, and evaluation evidence support the conclusion.

## Operating Contract

Preserve the user's scope and authority:

- Read and inspect within the repository and declared experiment environment.
- Modify code, configuration, state, logs, and managed artifacts only within the study scope.
- Explicit `$autoresearch` invocation authorizes this skill to use `$git-github-workflow no pr`.
- Explicit invocation also authorizes goal inspection, creation, and truthful terminal updates for the current study.
- Use that workflow only for study branches, task-scoped staging, commits, and pushes.
- Do not create a pull request.
- Do not delete artifacts, change protected branches, alter production systems, or exceed recorded resource limits without explicit authorization.
- Escalate when a decision would change the study design, resource use, retention policy, or authorized scope.
- Do not treat invocation as authorization for destructive retention, external tracker writes, or other publication methods.

Allow planning and recovery without an active persistent goal. Before the first study launch:

1. Call `get_goal` before the first study launch. Track whether this skill creates or reuses the goal.
2. If no unfinished goal exists, call `create_goal` with a bounded study objective.
3. Include the outcome, study constraints, and verification evidence in the objective.
4. Reuse a compatible unfinished goal. Do not replace an existing goal.
5. If the unfinished goal does not cover the study, explain the mismatch. Ask the user to edit or clear it.
6. If `create_goal` reports an unfinished goal, call `get_goal` again and reuse that goal when compatible.
7. If goal tools are unavailable, stop before launch. Tell the user how to start the equivalent goal.

Do not set a goal token budget unless the user explicitly supplied one. Goal authority does not expand other permissions or approval limits.

Use a repository research skill or domain adapter for the experiment mechanics. This includes commands, data, metrics, hardware, checkpoints, and events. If none exists, define and validate a minimal repository adapter before launch. Stop when required mechanics remain undefined.

When an issue arises, keep the goal active and continue with the highest-value authorized attempt. Use a retry, checkpoint, preregistered fallback, component isolation, or independent work when the protocol permits it. Do not pause or block only because the preferred approach failed. Ask the user only when an essential choice, authority, or fact is missing. Mark a goal blocked only after the same condition occurs for three consecutive goal turns. Meaningful authorized work must also be unavailable. Do not confuse that condition with an owned `$notify-wake` wait.

## Study Definition

Recover existing state and artifacts before creating a study. Then record:

- the study identifier, research question, falsifiable hypothesis, and proposed mechanism.
- baseline and candidate variants.
- exact code, configuration, dependency, and environment references.
- data source, split, preprocessing, and leakage controls.
- seeds, repetitions, initialization, subsets, and pairing rules.
- primary and secondary metrics.
- convergence definition and common comparison horizons.
- resource limits, timeout, concurrency, and storage budget.
- promotion, replication, rejection, and stopping criteria.
- artifact retention policy.
- local research-log location and publication procedure.
- managed paths for the research log, atomic state, and run artifacts.
- external tracker provider, account, project, mode, authorization, emitted-data manifest, and availability, when applicable.

Mark unknown items explicitly. Resolve each item before launch, or record the limitation and obtain approval when it changes study validity, cost, or recoverability.

## Experimental Discipline

Use this order:

1. Recover existing study state and inspect prior artifacts.
2. State one concrete question and one falsifiable hypothesis.
3. Define the baseline before interpreting variants.
4. Change one mechanism at a time unless the study tests an interaction.
5. Fix the evaluation protocol before inspecting outcomes.
6. Keep training, validation, and test roles distinct.
7. Pair seeds, initialization, subsets, and conditions when the comparison requires it.
8. Use deterministic selection and record every random seed.
9. Record failed, crashed, timed-out, cancelled, censored, and incomplete runs.
10. Record a dated protocol amendment before changing a hypothesis or metric after observing results.

Prefer common-horizon comparisons. Report endpoint quality and the cost or time needed to reach meaningful targets. Report effect sizes, uncertainty, paired differences, and limitations. Do not claim statistical significance from a sample size that cannot support it.

## Local Research Log

Maintain a local Markdown log for every study. Treat it as the canonical study index, decision record, and recovery entry point. Use a repository-defined location when one exists. Otherwise, use `research/<study-id>/research-log.md`.

Create the study header before the first launch. Include the protocol, provenance, metrics, resource limits, decision rules, and retention rules. Append one terminal entry for every run attempt. Include:

- run, attempt, and terminal-event identifiers, variant, seed, status, and timestamps.
- exact code, configuration, dependency, environment, data, and hardware references.
- primary results, progress or convergence result, uncertainty, and resource cost.
- tracker provider, run identifier, and URL when present.
- local artifact paths and retention disposition.
- decision, limitations, and follow-up.

Use the study coordinator as the only writer for the shared Markdown log. Supervisors and monitors may write per-run state but must not edit the shared log. The core skill defines the locking invariants below. The repository adapter supplies the platform-specific locking and atomic-write mechanics. Assign every log update a stable operation identifier before writing. Reuse it across retries and recovery. Serialize each update:

1. Acquire an exclusive lock at a stable sibling path that is not replaced with the log.
2. Re-read the log after acquiring the lock.
3. Deduplicate by the stable operation identifier. Also deduplicate terminal entries by study, run, and attempt identifiers.
4. Render the prior bytes plus one complete update into a temporary file in the same directory.
5. Flush and sync the temporary file, replace the log atomically, sync the directory, and release the lock.

If the update cannot complete, leave the operation pending and do not mark it recorded. Never change historical content during atomic replacement. Correct mistakes with a dated amendment that identifies the prior entry. Keep routine polling details in atomic runtime state. Append exceptional events that affect interpretation, including stalls, retries, tracker loss, protocol amendments, and incomplete runs.

## External Tracking

Treat external trackers as optional telemetry stores. They do not replace the local research log.

Before any external write, require an approved destination and explicit authorization. Record an authorization evidence identifier and timestamp. Verify the account, project, mode, controls, retention policy, and emitted-data manifest. Apply repository data-classification and consent rules. Exclude sensitive data unless the transfer has explicit approval. Sensitive data includes secrets, credentials, protected data, raw samples, source files, logs, and error text. Use local-only tracking when approval or classification is missing or ambiguous.

When a tracker is available, store detailed curves, tables, and telemetry there when useful. Keep local provenance, headline results, uncertainty, decisions, and artifact disposition. When no tracker is available, preserve local raw metrics and logs needed to reproduce the summary.

If tracking fails, record the outage. Continue only when local records still satisfy the recovery and evaluation protocol. Otherwise, mark the run incomplete or censored. Record any later backfill as a dated amendment instead of editing the original entry.

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

## Analysis and Promotion

After a run becomes terminal:

1. Validate artifacts, provenance, and notification state.
2. Compute the predefined metrics and convergence measures.
3. Compare against the baseline at the predefined horizons and thresholds.
4. Promote no more candidates than the study specification permits.
5. Replicate only candidates that meet the recorded promotion rule.
6. Report means, dispersion, paired differences, censored runs, costs, and limitations.
7. Mark a candidate confirmed only after it meets the replication rule.

If no candidate qualifies, record that result and stop unless the trial budget authorizes another experiment.

## Completion and Handoff

Complete a study only when all permitted runs are terminal or censored. Require complete evaluation, replication, provenance, logs, retention, and authorized publication. Stored artifacts must reproduce the comparisons.

Call `update_goal` with `status=complete` only when the goal objective is complete. Complete a goal that this skill created after all required work finishes. Leave a reused broader goal active unless its complete objective is also achieved. Keep the existing three-turn rule for `status=blocked`.

Report identifiers, terminal-state counts, record locations, metrics, uncertainty, resources, provenance, artifact retention, notification status, limitations, and next actions.

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
