# Audit Issue Remediation Playbook

## Contents

- Solution-plan format
- Common implementation sequence
- Bug and security work
- Performance work
- Quality work
- Enhancement work
- Documentation work
- Review and target-branch updates
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
8. Commit only issue-related paths and publish one draft pull request.
9. Re-read issue comments, reviews, review threads, top-level comments, checks, and mergeability.
10. Address feedback and target updates with new commits until the merge-ready gate passes.

## Bug and Security Work

For a reproducible bug:

1. Add a focused regression test or deterministic reproduction.
2. Run it against the current code and confirm the expected failure.
3. Implement the fix.
4. Confirm the regression passes and adjacent behavior remains covered.

For future bug risk, add a test that demonstrates the missing invariant, failure boundary, or unprotected state transition. Do not alter behavior merely to satisfy a vague risk claim.

For a theoretical bug, attempt to turn the claimed reachable path into a failing test. If repository facts disprove a precondition or no credible failure can be demonstrated, document that result and block the issue rather than guessing.

For a security advisory:

- Refresh primary advisory sources and scanner data before editing.
- Verify the vulnerable version and dependency path in the current lockfile or artifact.
- Determine whether the affected feature executes in shipped, CI, build, or contributor workflows.
- Apply the smallest safe remediation that meets the issue acceptance criteria.
- Re-run the same scanner and confirm the vulnerable version or finding is gone.
- Report advisory IDs, old and new versions, dependency path, scanner provenance, and remaining affected surfaces.

Treat security-driven public API, runtime, schema, or documented-workflow breakage as approval-gated unless the issue already authorizes it.

For a missing security-audit pipeline, choose one or more maintained repository-appropriate scanners, expose a reproducible local command, cover every applicable dependency and artifact surface, run the checks for relevant changes and on a schedule, and make findings visible and actionable. Validate both a clean run and the failure or reporting path without introducing a real vulnerable dependency.

## Performance Work

Create or extend a repeatable benchmark before optimizing. Use the repository's established framework; otherwise use Criterion for Rust, `pytest-benchmark` or `pyperf` for Python, Benchmark.js or a repeatable Node runner for JavaScript, `testing.B` for Go, or JMH for Java.

Capture the applicable metrics with the same workload and environment before and after the change:

- Throughput, mean or median latency, tail latency, sample count, and uncertainty.
- Peak and steady-state memory, allocation count, or retained size.
- Disk bytes, operations, access pattern, temporary storage, and synchronization.
- Persistent storage growth, compression, duplication, or retention.
- Network requests, payload bytes, retries, connections, and queue or round-trip latency.

Use representative inputs, warm-up, and stable environment assumptions. If several designs are plausible, compare them under the same harness. Preserve correctness and public behavior unless the issue says otherwise.

Ship an optimization only when the result exceeds observed noise or provides a justified resource reduction. If no meaningful gain exists, keep useful benchmark coverage only when benchmark coverage is itself part of the issue; otherwise record the evidence and block the optimization.

Include baseline, optimized result, absolute and percentage delta, uncertainty, resource effects, and correctness tests in the pull request.

## Quality Work

Add characterization tests before changing weakly covered behavior. Keep public interfaces and runtime behavior stable unless the issue explicitly requires a contract change.

Prefer direct control flow, clear domain names, immutable values, named constants, narrow errors, and existing project utilities. Remove real duplication and clarify responsibility boundaries. Avoid broad restyling, speculative abstraction, one-caller frameworks, dependency additions, and unrelated generated churn.

When the issue describes a systemic design smell, confirm the repeated evidence before changing architecture. Keep the pull-request boundary reviewable and defer unrelated local cleanup.

For a missing quality-gate finding, use repository-native formatters, linters or quality checks, compilers, and static type checkers where practical. Provide one documented local entry point, run non-mutating checks in CI, include relevant production and test code, and confirm that a representative violation fails the gate. Keep local and CI commands aligned.

## Enhancement Work

Translate the issue's user need and desired behavior into acceptance tests before implementation. Confirm defaults, compatibility, error behavior, configuration, CLI or API changes, and documentation needs.

Keep the common path simple. Avoid optionality and extension points not required by the accepted use cases. Obtain approval before introducing public breaking changes, new persistent formats, migrations, or dependencies not established by the issue.

## Documentation Work

Identify the canonical code, configuration, generated help, CI job, or policy for every changed claim. Update the canonical document first and replace duplicated detail elsewhere with a short summary or link when practical.

Check README files, effective root and nested `AGENTS.md` files, contributor docs, docs indexes, examples, and affected references for contradictions. Run documented commands when feasible. Mark any unverified command with its reason and residual risk.

## Review and Target-Branch Updates

At the start of every stewardship pass, fetch:

- New linked-issue comments and edits.
- Pull-request review submissions.
- Inline comments and thread resolution state.
- Top-level pull-request comments.
- Required checks and failure logs.
- Target-branch head and mergeability.

For accepted feedback, add or update the regression first when the comment describes a bug. Make the change in a new commit, reply in the original thread with the commit or result, and resolve the thread only after the feedback is fully addressed.

For declined feedback, give a concrete repository or scope reason and leave the thread unresolved. Treat unresolved actionable feedback or incompatible requirements as a blocker.

For published branches, preserve review context. Fetch the target and merge it into the issue branch when branch protection, conflicts, or target changes require synchronization. Resolve conflicts against current requirements, rerun affected tests and full quality gates, and push a new commit. Rebase or force-push only with explicit approval.

Mark the draft ready after implementation and initial checks pass. Continue monitoring until required approvals and checks are complete and no conflict or actionable thread remains.

## Dependency Stacks

Use `main` or `master` as the base unless all of these conditions hold:

- The child cannot be implemented or reviewed correctly without the parent.
- The child remains a coherent, independently reviewable change.
- Combining both issues would make review materially harder.
- The expected merge strategy will not force an unsafe rewrite, or the user has approved the required stack maintenance.

Keep stacks one level deep by default. Set the child base to the parent branch and state the dependency in both pull requests. Update the child when the parent changes.

After the parent lands, inspect the child's diff against `main` or `master` before retargeting. If squash merging makes parent commits reappear, do not rewrite, force-push, replace, or close the child without approval.

## Completion Report

For each issue, report:

| Issue | Category and priority | Branch | PR and base | Issue comments addressed | Review state | CI | Merge conflicts | Result |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |

Use `merge-ready` only when the pull request is non-draft, required approvals and checks are complete, actionable threads are resolved, the branch has no conflicts, and the pull-request body matches the current diff.

List test changes, security evidence, benchmark deltas, target-branch updates, and blockers after the table. End by stating that no pull request was merged.
