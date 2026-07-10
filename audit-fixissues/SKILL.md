---
name: audit-fixissues
description: Prioritize issues produced by a codebase audit, prepare concrete remediation plans, implement authorized fixes, and steward one pull request per issue until it is approved and merge-ready without merging it. Use after an audit or with selected issue URLs, numbers, or pasted findings when Codex needs to plan fixes, execute approved work, address issue and review feedback, resolve conflicts and CI failures, or maintain dependent pull requests.
---

# Audit Issue Remediation

## Overview

Turn an approved audit backlog into solution plans and, when authorized, validated pull requests. Continue implementation runs through review and branch maintenance until every selected pull request is merge-ready or genuinely blocked. Never merge a pull request.

Read `references/remediation-playbook.md` completely before planning or implementing an issue. Use `$git-github-workflow` for repository safety, branch publication, GitHub app boundaries, review handling, and recovery. Do not invoke its default publish flow until implementation is authorized.

## Issue Intake

Accept:

1. Explicit issue URLs or numbers.
2. Pasted or attached audit findings.
3. A user-selected subset of the latest completed audit in the active conversation.
4. The complete latest audit when the user says to address all findings.

Explicit inclusions, exclusions, and ordering instructions override defaults. If no issue set can be identified, ask for it rather than selecting arbitrary repository backlog.

For GitHub issues, read the current body, edits, labels, state, and every issue comment before triage. Re-read them before planning, before implementation, and during pull-request stewardship. Incorporate actionable corrections and requirements. Stop that issue for user direction when comments introduce incompatible requirements or material scope expansion, then continue with independent issues.

## Prioritization

Deduplicate the selected set and identify dependencies before ordering work.

1. Bugs, including security vulnerabilities and credible future bug risks.
2. Performance issues.
3. Quality, enhancement, and documentation issues, ordered together by priority.

Within each group, use repository-native priority definitions. Otherwise use the P0-P3 value from the audit. Break ties by dependency order, evidence confidence, affected reach, and maintainer value.

Process parent or prerequisite issues before dependent issues. User guidance always wins.

## Mode Behavior

### Plan Mode

Inspect the issue and repository read-only. Return a decision-complete implementation plan in the active conversation. Do not post issue comments, edit files, create branches, or mutate GitHub.

### Initial Invocation Outside Goal Mode

Prepare a concrete solution plan for each selected issue and stop before implementation. Post the plan as a comment when the input is a filed GitHub issue. Return paste-ready text for unfiled findings or unavailable connector access.

Do not treat an implementation request in the same initial invocation as permission to skip this planning checkpoint when no prior solution plan exists.

### Later Authorized Implementation

A later explicit user request may authorize implementation outside Goal Mode. Implement only the selected issues and continue through pull-request stewardship until each pull request is merge-ready or the issue is genuinely blocked.

### Goal Mode

Triage, plan internally, implement, publish, and steward every selected issue without stopping at the planning checkpoint. Continue until each issue maps to a merge-ready pull request or a documented blocker. Skip blocked issues and keep working through independent ones.

Waiting for a check, reviewer, or target-branch update is not a blocker. Use the available monitoring mechanism and recheck when state changes.

## Authorization Boundary

An authorized implementation run includes repository edits, tests, task-specific branches and commits, pushes, draft pull requests, existing labels, pull-request comments, review-thread replies and resolution for implemented feedback, ready-for-review transitions, and safe base retargeting.

It does not authorize:

- Merging pull requests.
- Filing new issues.
- Creating custom labels.
- Closing issues.
- Adding automatic issue-closing keywords.
- Rebasing or force-pushing a published branch.
- Replacing or closing a pull request solely to repair a dependency stack.

Obtain separate approval for those actions. Link pull requests with `Addresses #N` unless closing semantics are approved.

## Solution Planning

For each issue, use the plan template in `references/remediation-playbook.md`. Resolve:

- Root cause or capability gap.
- Concrete implementation approach and affected boundaries.
- Public interfaces, schemas, data flow, and compatibility effects.
- Failure modes, edge cases, migrations, and rollout needs.
- Regression tests, characterization tests, benchmarks, documentation checks, and quality gates.
- One-issue pull-request boundary and any unavoidable dependency on another issue.

If repository evidence invalidates the audit finding, document the evidence and skip the issue. Do not implement a speculative substitute.

## Implementation

Use one branch and draft pull request per non-duplicate issue. Apply the category-specific gates from `references/remediation-playbook.md`.

For every fix:

1. Verify the current issue requirements and checkout state.
2. Add the required failing regression, characterization, acceptance test, or performance baseline before the main change.
3. Implement the smallest complete change that satisfies the issue.
4. Run focused checks, then repository-standard formatting, linting, type checks, tests, security scans, and benchmarks for the changed surfaces.
5. Review the complete branch diff against its target branch.
6. Commit and push through `$git-github-workflow`.
7. Open a draft pull request with full motivation, solution, change, test, risk, and issue traceability.
8. Continue into stewardship. Do not stop merely because the draft exists.

If an issue cannot be reproduced, measured, safely implemented, or validated, record the blocker and continue with the remaining issues.

## Branch and Worktree Isolation

Keep issue branches independent and prefer `main` or `master` as their base.

- Finish local work on one branch before switching when practical.
- Reuse the main checkout when it is clean and safe to switch.
- When the user's checkout contains unrelated work, use one reusable task worktree instead of stashing or disturbing it.
- Add another worktree only when an active dependency stack or concurrent branch state makes it necessary.
- Remove task-created worktrees after their branch no longer needs an isolated checkout.
- Do not create one persistent worktree per issue by default.

A pull request may target another pull-request branch when the child is independently reviewable, depends on the parent, and combining them would obscure review. Keep stacks shallow and rare. Process the parent first and keep the child synchronized with parent updates.

Before creating a stack, inspect the repository's merge strategy. Avoid stacks that will require history rewriting after a squash merge. When a safe retarget is impossible, stop for approval before rebasing, force-pushing, replacing, or closing the child pull request.

## Pull-Request Stewardship

Revisit open pull requests one at a time in priority and dependency order. Complete the current branch's review, CI, and target-sync pass before checking out another branch when practical.

For each open pull request, repeat:

1. Re-read linked issue comments for new evidence or changed requirements.
2. Fetch pull-request metadata, target-branch state, changed files, checks, reviews, thread-aware review comments, top-level comments, and mergeability through the GitHub app or connector.
3. Address actionable in-scope findings with tests and new commits. Reply in the original thread and resolve it only after the feedback is fully implemented. Explain declined suggestions and leave those threads unresolved.
4. Fetch the current target branch. For a published branch, merge target updates into the issue branch when needed to preserve review history and resolve conflicts. Do not rebase or force-push without approval.
5. Diagnose relevant CI failures, implement fixes, rerun local quality gates, and push a follow-up commit.
6. Update the pull-request body when the complete branch diff, tests, risks, benchmark results, or issue traceability changes.
7. Mark the draft ready for review after implementation and initial validation are complete.
8. Recheck after reviews, checks, or target updates until the merge-ready gate passes.

When a stacked parent lands, retarget and revalidate the child against `main` or `master` only when this can be done without unsafe history rewriting.

## Merge-Ready Gate

A pull request is merge-ready only when:

- It is not a draft.
- All required checks pass.
- All required approvals are present, or the repository requires none.
- No actionable review thread remains unresolved.
- The branch has no merge conflicts.
- The pull request targets the intended branch.
- The branch reflects required target updates under repository policy.
- The pull-request body describes the complete diff and current validation.

Never merge the pull request. Missing authorization, credentials, external infrastructure, irreconcilable requirements, an unprovable finding, or required history rewriting without approval is a genuine blocker.

## Output Contract

Return:

1. Ordered issue list and dependency relationships.
2. Plans posted to GitHub and paste-ready plans returned locally.
3. For each implemented issue: branch, pull request, target branch, commits, and validation.
4. New issue and review findings addressed, declined, or blocked.
5. Conflicts resolved, CI failures fixed, approvals, unresolved threads, and merge-ready state.
6. Security results, test coverage changes, and measured performance or resource deltas.
7. Every blocker and the exact approval, evidence, credential, or external change needed.

Map every selected issue to one merge-ready pull request or one blocker. State that no pull request was merged.
