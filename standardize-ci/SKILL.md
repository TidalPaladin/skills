---
name: standardize-ci
description: Plan CI initialization, restructuring, or runtime reduction without changing files or remote state.
---

# Standardize CI

Keep this skill planning-only in every mode. Inspect the target and return a
decision-complete plan. Do not edit files, register runners, dispatch workflows,
change settings, or publish branches.

Use the supplied repository or the current one. Honor an existing provider or
an explicit choice. For new CI with no provider selected, default to GitHub Actions.

## Inspect and Decide

Read relevant workflow files, manifests, quality commands, supported runtimes,
and release requirements. Trace job commands through scripts and package hooks
to identify required tools and services. Use available run history for duration,
queue, setup, cache, and artifact evidence.

Reuse established policy and facts. Ask only for unresolved decisions that affect
cost, supported platforms, runner trust, required checks, artifacts, or schedules.
Do not require confirmation of facts already established by the repository.

For GitHub Actions, use the relevant sections of
[planning patterns](references/github-actions-patterns.md):

- Job allocation and runtime controls for workflow splits or latency work.
- Dependency health for advisory and deprecation checks.
- Runner trust and bootstrap for self-hosted execution.
- Security for permissions, action pins, and cache boundaries.
- Scheduled validation for new or changed schedules.

Keep fast, useful feedback on pull requests. Allocate costly jobs from measured
runtime, capacity, and support requirements. Do not invent artifacts or add
release builds to repositories that have no production-build requirement.
Preserve declared runtime and critical-library boundary coverage.

Keep untrusted fork code off persistent self-hosted runners. Define hosted
fallbacks or conclusive aggregate checks where branch protection requires them.
Ask about trust or capacity only when the available policy does not resolve it.

## Plan and Validation

Specify the workflow and job names, commands, runners, setup, pins, triggers,
permissions, caches, artifacts, timeouts, concurrency, and dependencies that apply.
For self-hosted jobs, include bootstrap exceptions and early preflight failures.
Keep required-check transitions explicit.

Use existing schedules when suitable. For new schedules, settle operational
constraints with the user when they matter. Otherwise choose a non-zero UTC minute
and state the proposed cadence and time as defaults.

For new or changed scheduled workflows, include exact-ref dispatch evidence
under [GitHub Actions validation](../git-github-workflow/references/actions-validation.md).
Honor its authorization and notification thresholds.

Return one `<proposed_plan>` block with the changes, job table, validation,
required-check transition, and assumptions. Stop when implementation needs no
unresolved material decision.
