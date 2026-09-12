---
name: autoresearch
description: Run a bounded empirical research study with reproducible results and recoverable state.
---

# Autoresearch

Run controlled experiments with a fixed protocol and verifiable provenance.
Use the repository adapter for domain commands, data, metrics, and hardware.
Do not start unrelated research merely because a task involves experiments.

## Operating Contract

Preserve the user's scope and authority:

- Read and inspect within the repository and declared experiment environment.
- Modify code, configuration, state, logs, and managed artifacts only within the study scope.
- Explicit `$autoresearch` invocation authorizes this skill to use `$git-github-workflow no pr`.
- Explicit invocation also authorizes goal inspection, creation, and truthful terminal updates for the current study.
- Use that workflow only for study branches, task-scoped staging, commits, and pushes.
- Do not create a pull request.
- Do not delete artifacts, change protected branches, alter production systems, or exceed recorded resource limits without explicit authorization.
- Ask when a decision exceeds the accepted study design, resource limits, retention policy, or scope.
- Do not treat invocation as authorization for destructive retention, external tracker writes, or other publication methods.

Allow planning and recovery without an active persistent goal. Before launch:

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


## Read for the Current Phase

- For study design, local records, or external tracking, read
  [study protocol](references/study-protocol.md).
- Before launch, and for monitoring, recovery, retention, or adapter work, read
  [run lifecycle](references/run-lifecycle.md).
- For qualifying wake delivery, use `$notify-wake`. It owns transport,
  authority capture, delivery, reconciliation, and owned goal waits.

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
