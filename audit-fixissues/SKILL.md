---
name: audit-fixissues
description: Prioritize issues produced by a codebase audit, prepare concrete remediation plans, implement authorized fixes, and open one validated draft pull request per issue for lifecycle handoff. Use after an audit or with selected issue URLs, numbers, or pasted findings when Codex needs to plan fixes or execute approved work without beginning pull-request review or merge-readiness management.
---

# Audit Issue Remediation

## Overview

Turn an approved audit backlog into solution plans and, when authorized, validated draft pull requests. End implementation after each selected issue maps to a draft pull request or a documented blocker. Leave every pull request in draft and do not request reviews or attempt to merge it.

Read `references/remediation-playbook.md` completely before planning or implementing an issue. Use `$git-github-workflow` for repository safety, branch publication, GitHub app boundaries, and recovery. Read its `references/git-workflow.md` before publication and treat its pull-request body format as required. Do not invoke its default publish flow until implementation is authorized.

## Issue Intake

Accept:

1. Explicit issue URLs or numbers.
2. Pasted or attached audit findings.
3. A user-selected subset of the latest completed audit in the active conversation.
4. The complete latest audit when the user says to address all findings.

Explicit inclusions, exclusions, and ordering instructions override defaults. If no issue set can be identified, ask for it rather than selecting arbitrary repository backlog.

For GitHub issues, read the current body, edits, labels, state, and every issue comment before triage, planning, and implementation. Incorporate actionable corrections and requirements. Stop that issue for user direction when comments introduce incompatible requirements or material scope expansion, then continue with independent issues.

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

A later explicit user request may authorize implementation outside Goal Mode. Implement only the selected issues and continue until each issue has a validated draft pull request or is genuinely blocked.

### Goal Mode

Triage, plan internally, implement, and publish every selected issue without stopping at the planning checkpoint. Halt after each issue maps to a validated draft pull request or a documented blocker. Skip blocked issues and keep working through independent ones.

Do not wait for reviews or post-publication CI after opening the draft. Those activities belong to `$manage-pr-lifecycle`.

## Authorization Boundary

An authorized implementation run includes repository edits, tests, task-specific branches and commits, pushes, draft pull requests, existing labels, and pull-request body updates required for accurate publication.

It does not authorize:

- Promoting a draft to ready for review.
- Requesting a human or automated review.
- Posting `@codex review`.
- Replying to or resolving pull-request review threads.
- Enabling auto-merge or merging pull requests.
- Filing new issues or closing issues.
- Creating custom labels.
- Rebasing or force-pushing a published branch.
- Replacing or closing a pull request solely to repair a dependency stack.

Obtain separate approval for those actions. Every issue-backed pull request must include a required closing keyword in its body. Use `Closes #N` for an issue in the pull-request repository and `Closes OWNER/REPOSITORY#N` for an issue in another repository. Do not close the issue directly during remediation.

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
5. Synchronize the intended target branch and review the complete branch diff against it.
6. Use `$git-github-workflow` to commit, push, and open one draft pull request whose body follows its complete format and describes the full branch diff.
7. Fetch the created pull request again and verify it is open, remains a draft, contains the required closing keyword, and has `## Motivation`, `## Solution`, `## Changes`, and `## Test plan` sections with the required conditional test-suite disclosure and generation attribution.
8. Stop work on its lifecycle and hand it to `$manage-pr-lifecycle`.

If an issue cannot be reproduced, measured, safely implemented, or validated, record the blocker and continue with the remaining issues.

## Branch and Worktree Isolation

Keep issue branches independent and prefer `main` or `master` as their base.

- Finish local work on one branch before switching when practical.
- Reuse the main checkout when it is clean and safe to switch.
- When the user's checkout contains unrelated work, use one reusable task worktree instead of stashing or disturbing it.
- Add another worktree only when an active dependency stack or concurrent branch state makes it necessary.
- Remove task-created worktrees after their branch no longer needs an isolated checkout.
- Do not create one persistent worktree per issue by default.

A pull request may target another pull-request branch when the child is independently reviewable, depends on the parent, and combining them would obscure review. Keep stacks shallow and rare. Process the parent first and keep the child synchronized before publication.

Before creating a stack, inspect the repository's merge strategy. Avoid stacks that will require history rewriting after a squash merge. When safe publication is impossible, stop for approval before rebasing, force-pushing, replacing, or closing the child pull request.

## Draft Pull-Request Handoff

Before handing off a draft, verify:

- The branch was synchronized with its intended base immediately before final validation.
- Local required checks passed and results are recorded in the pull-request body.
- The body follows the `$git-github-workflow` format, including `## Motivation`, `## Solution`, `## Changes`, and `## Test plan`, plus `## Test suite changes (Required when test coverage changed)` when its condition applies.
- The body describes the complete branch diff, risks, tests, benchmark or security evidence, and issue traceability, and ends with the required generation attribution.
- The body contains a closing keyword for the original issue using the correct same-repository or cross-repository syntax.
- The pull request is open and remains a draft.
- No reviewer was requested and no `@codex review` comment was posted.
- No merge, auto-merge, ready-for-review, direct issue closure, or review-thread action occurred.

Do not interpret post-publication CI, reviews, or target updates as work for this skill. Hand the pull request to `$manage-pr-lifecycle` for later iterations.

## Output Contract

Return:

1. Ordered issue list and dependency relationships.
2. Plans posted to GitHub and paste-ready plans returned locally.
3. For each implemented issue: branch, draft pull request, target branch, commits, and validation.
4. Security results, test coverage changes, and measured performance or resource deltas.
5. Every blocker and the exact approval, evidence, credential, or external change needed.
6. A paste-ready `$manage-pr-lifecycle` invocation containing the draft pull-request targets and any user-specified reviewer mapping.

Map every selected issue to one validated draft pull request or one blocker. State that every opened pull request remains a draft, follows the required body format, contains its closing keyword, has no requested reviews, and was not merged.
