# Audit Issue Remediation Playbook

## Contents

- Solution-plan format
- Common implementation sequence
- Bug and security work
- Performance work
- Quality work
- Enhancement work
- Documentation work
- Draft pull-request publication
- Dependency stacks
- Completion report

## Solution-Plan Format

Use this structure for conversation output or an issue comment:

```markdown
## Proposed implementation plan

### Diagnosis and acceptance target
<Current behavior, root cause, affected surface, and the issue outcome that defines completion.>

### Implementation approach
<Concrete design, boundaries, data flow, interfaces, and files or modules likely to change.>

### Edge cases and compatibility
<Failure modes, ordering, concurrency, persistence, security, public contracts, migrations, and rollout constraints.>

### Verification
<Regression or characterization tests, benchmarks, documentation checks, and repository quality gates.>

### Pull-request boundary
<What belongs in this PR, what remains out of scope, and any dependency on another issue or PR.>
```

Make the plan decision-complete. Do not claim the plan has been implemented. For filed issues, re-read all comments before posting and mention any requirement that came from later discussion.

## Common Implementation Sequence

1. Confirm issue scope, current branch, target branch, remotes, working-tree state, repository instructions, and quality gates.
2. Fetch current issue and pull-request discussion through the GitHub app or connector.
3. Verify the root cause or capability gap against current code.
4. Add the category-specific baseline before editing production behavior.
5. Implement the smallest complete solution without unrelated cleanup.
6. Run the focused baseline again, then all repository checks required for the changed surfaces.
7. Inspect the full diff against the intended base and check for secrets, generated churn, stale docs, and accidental API changes.
8. Commit only issue-related paths and publish one draft pull request using the `$git-github-workflow` body format.
9. Fetch the created pull request again and verify its complete body, closing keyword, open state, and draft state.
10. Stop lifecycle work and hand the draft to `$manage-pr-lifecycle`.

## Bug and Security Work

For a reproducible bug:

1. Add a focused regression test or deterministic reproduction.
2. Run it against the current code and confirm the expected failure.
3. Implement the fix.
4. Confirm the regression passes and adjacent behavior remains covered.

For future bug risk, add a test that demonstrates the missing invariant, failure boundary, or unprotected state transition. Do not alter behavior merely to satisfy a vague risk claim.

For a theoretical bug, attempt a failing test of the claimed path.
If facts disprove it or no credible failure exists, record the evidence and block that issue.

For a security advisory:

- Refresh primary advisory sources and scanner data before editing.
- Verify the vulnerable version and dependency path in the current lockfile or artifact.
- Determine whether the affected feature executes in shipped, CI, build, or contributor workflows.
- Apply the smallest safe remediation that meets the issue acceptance criteria.
- Re-run the same scanner and confirm the vulnerable version or finding is gone.
- Report advisory IDs, old and new versions, dependency path, scanner provenance, and remaining affected surfaces.

Treat security-driven public API, runtime, schema, or documented-workflow breakage as approval-gated unless the issue already authorizes it.

Keep security validation defensive. Prefer scanner evidence, safe regression fixtures, and isolated tests.
Use only the exploit detail needed to confirm applicability or remediation.

For a missing audit pipeline, choose maintained scanners and a reproducible local command.
Cover applicable surfaces and run checks on relevant changes and a schedule.
Validate clean and failure paths with synthetic fixtures.

## Performance Work

Create a repeatable benchmark before optimization. Use the established framework.
Otherwise use the language-specific defaults in `$benchmark-optimize`.

Capture the applicable metrics with the same workload and environment before and after the change:

- Throughput, mean or median latency, tail latency, sample count, and uncertainty.
- Peak and steady-state memory, allocation count, or retained size.
- Disk bytes, operations, access pattern, temporary storage, and synchronization.
- Persistent storage growth, compression, duplication, or retention.
- Network requests, payload bytes, retries, connections, and queue or round-trip latency.
- Clean and incremental compilation or build duration, CI job duration, and end-to-end workflow wall time.

Use representative inputs, warm-up, and stable environment assumptions. If several designs are plausible, compare them under the same harness. Preserve correctness and public behavior unless the issue says otherwise.

For build or CI optimization, hold required tests, security checks, quality gates, and output artifacts constant. Treat skipped validation or reduced coverage as a behavior change, not a performance gain.

Retain optimization changes only when improvement exceeds noise or justifies a resource reduction.
Keep benchmark-only changes when benchmark coverage is part of the issue.
Otherwise record the evidence and block the optimization.

Include baseline, optimized result, absolute and percentage delta, uncertainty, resource effects, and correctness tests in the pull request.

## Quality Work

Add characterization tests before changing weakly covered behavior. Keep public interfaces and runtime behavior stable unless the issue explicitly requires a contract change.

Prefer direct control flow, clear domain names, immutable values, named constants, narrow errors, and existing project utilities. Remove real duplication and clarify responsibility boundaries. Avoid broad restyling, speculative abstraction, one-caller frameworks, dependency additions, and unrelated generated churn.

When the issue describes a systemic design smell, confirm the repeated evidence before changing architecture. Keep the pull-request boundary reviewable and defer unrelated local cleanup.

For missing quality gates, use repository-native formatters, linters, compilers, and type checks where applicable.
Provide one local entrypoint and non-mutating CI checks for relevant production and test code.
Confirm that a representative violation fails the gate.

## Enhancement Work

Translate the issue's user need and desired behavior into acceptance tests before implementation. Confirm defaults, compatibility, error behavior, configuration, CLI or API changes, and documentation needs.

Keep the common path simple. Avoid optionality and extension points not required by the accepted use cases. Obtain approval before introducing public breaking changes, new persistent formats, migrations, or dependencies not established by the issue.

## Documentation Work

Identify the canonical code, configuration, generated help, CI job, or policy for every changed claim. Update the canonical document first and replace duplicated detail elsewhere with a short summary or link when practical.

Check README files, effective root and nested `AGENTS.md` files, contributor docs, docs indexes, examples, and affected references for contradictions. Run documented commands when feasible. Mark any unverified command with its reason and residual risk.

## Draft Pull-Request Publication

Synchronize the intended target branch before final validation. For a published dependency branch, preserve history and do not rebase or force-push without approval.

Read the Pull Request Creation section of `$git-github-workflow` before drafting the body. Create the pull request as a draft through the GitHub app or connector and follow that format in full:

- Use `## Motivation`, `## Solution`, `## Changes`, and `## Test plan` in that order.
- Describe the runtime problem under Motivation. Cover the complete branch diff under Solution and Changes.
- Record focused and repository-wide validation under Test plan.
- Include `## Test suite changes (Required when test coverage changed)` when tests were removed, significantly altered, or changed in coverage intent. Otherwise omit it.
- Include concise usage examples, tables, or diagrams when they materially improve review, and include only critical deferred work.
- End with the required `Generated with <tool name>` attribution.

Include the issue traceability, risks, security evidence, benchmark results, and test-suite changes required by the branch. Add `Closes #N` for the original same-repository issue or `Closes OWNER/REPOSITORY#N` for a cross-repository issue. A non-default target does not remove this body requirement.

Fetch the created pull request again and verify its complete body.
Correct missing sections, conditional test disclosure, generation attribution, and closing keywords. Re-fetch the result.
Treat an uncorrectable body as a blocker.

Verify the PR is open, targets the intended base, and remains a draft.
Do not wait for CI or perform review, promotion, thread, or merge actions.
Hand the draft to `$manage-pr-lifecycle`.

## Dependency Stacks

Use `main` or `master` as the base unless all of these conditions hold:

- The child cannot be implemented or reviewed correctly without the parent.
- The child remains a coherent, independently reviewable change.
- Combining both issues would make review materially harder.
- The expected merge strategy will not force an unsafe rewrite, or the user has approved the required stack maintenance.

Keep stacks one level deep by default. Set the child base to the parent branch and state the dependency in both pull requests. Update the child when the parent changes.

Leave post-publication parent updates and retargeting to `$manage-pr-lifecycle`.
If safe publication requires later history rewriting, block publication until that rewrite is authorized.

## Completion Report

For each issue, report:

| Issue | Category and priority | Branch | Draft PR and base | Validation | Result |
| --- | --- | --- | --- | --- | --- |

Report test changes, security evidence, benchmark deltas, and blockers.
Provide a `$manage-pr-lifecycle` handoff for each draft.
Confirm body conformance, closing keywords, draft status, and the absence of review or merge actions.
