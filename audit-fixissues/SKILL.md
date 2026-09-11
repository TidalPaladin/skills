---
name: audit-fixissues
description: Plan fixes for selected audit findings and publish validated draft PRs when implementation is requested.
---

# Audit Issue Remediation

Accept selected issue URLs, numbers, pasted findings, or the latest audit
identified by the user. Preserve exclusions and order.
Ask when no issue set can be determined. Do not select unrelated backlog.

Read current issue bodies and discussion. Deduplicate findings and order
prerequisites first. Otherwise prioritize bugs, performance, then remaining
categories by repository priority, evidence, and impact.

## Plan or Implement

In Plan Mode, inspect read-only and return a decision-complete plan.
For a planning request, produce plans without implementation or publication.
Post a plan comment only when requested.

For an implementation request, plan as needed and continue through validation
and draft publication. An initial invocation does not require another approval
after planning. Continue independent issues when one is blocked.

Use [the remediation playbook](references/remediation-playbook.md) for the current phase.
Read planning guidance for unresolved designs and category-specific validation for implementation.
Read publication or dependency-stack guidance when needed.

## Boundaries

Authorized implementation includes issue-scoped branches, edits, tests, commits,
pushes, draft PRs, existing labels, and accurate body updates.
Use `$git-github-workflow` for those operations and its authorization exceptions.

Leave PRs in draft. Do not request reviews, post `@codex review`, resolve review
threads, promote drafts, merge, enable auto-merge, or directly close issues.
New issues, custom labels, and published-history rewrites require separate scope.
Do not repeat approval when the user already authorized an action.

Use one branch and draft PR per non-duplicate issue. Prefer the repository
default branch as the base. Reuse an isolated worktree when needed to protect
unrelated changes. Keep dependency stacks shallow and independently reviewable.

## Verify and Hand Off

Establish the category-specific baseline before the main change.
Confirm a failing regression for reproducible bugs.
Implement the smallest complete solution and run applicable repository gates.

Before publication, inspect the full diff against the intended base.
Follow the required body format in `$git-github-workflow`.
Include the required closing keyword for the issue.
Use `Closes #N` or `Closes OWNER/REPOSITORY#N` as applicable.

Fetch the published PR and verify its full body, base, open state, and draft state.
Do not wait for reviews or post-publication CI in this skill.
Hand drafts to `$manage-pr-lifecycle`.

Finish when each selected issue has a validated draft PR or a concrete blocker.
Report the mapping, validation, unresolved evidence, and lifecycle handoff.
