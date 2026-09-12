# Study Protocol and Records

Read when defining a study, recording results, or preparing tracker writes.

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
