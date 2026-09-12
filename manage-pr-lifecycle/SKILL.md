---
name: manage-pr-lifecycle
description: Advance selected pull requests through one review and CI lifecycle pass without merging.
---

# Manage PR Lifecycle

Accept PR URLs, repository-qualified numbers, or an unambiguous set from the task.
Honor explicit order, exclusions, and named reviewer mappings.
Otherwise process parent PRs first, then independent PRs by ascending number.

Complete one iteration across all targets. Refresh their state and report
merge readiness, waiting, blockers, or terminal state. Do not monitor indefinitely.
In Plan Mode, inspect read-only and return the proposed actions.

## Reporter Assignment

When using `pr_lifecycle_reporter`, establish fixed lifecycle order before fan-out.
Assign exactly one pull request per instance and preserve its read-only permission mode.
Use waves of at most eight reporter instances.
Require body conformance and closing-linked issue state checks, including closure after a default-branch merge.
Then consolidate lifecycle rows by assigned queue position.
Keep local changes and cross-target decisions with the parent.
Reporters retain only the remote actions allowed by their agent definition.

## Authority

Invocation authorizes target synchronization when needed, conflict resolution,
scoped fixes, tests, new commits, pushes, body corrections, and CI diagnosis.
It also authorizes the review and post-merge issue actions below under their
detailed conditions.

Do not merge, enable auto-merge, dismiss reviews, reopen issues, or close PRs.
Do not resolve human-authored threads or unresolve any thread.
Resolve Codex threads only after directly addressing their findings.
Do not rewrite published history, delete unrelated worktrees or branches,
or choose an unspecified reviewer.

Use `$git-github-workflow` for GitHub authority and connector fallback.
An invoked reporter must also follow its narrower agent permissions.

## Current-State Pass

Use the relevant sections of
[the lifecycle playbook](references/lifecycle-playbook.md):

- Build the target snapshot, then inspect conflicts and required target updates.
- Check the complete PR body and correct it using the Git workflow format.
- Address valid findings and branch-caused CI failures with new commits.
- Apply Codex review significance rules and named-human request limits.
- Apply readiness classification after refreshing changed state.

Required CI evidence must match the current head. Do not merge the target
solely because the PR is behind when repository policy permits that state.
Do not create empty commits or use skip directives to manipulate CI.

For a PR confirmed merged into the repository default branch, verify closing links.
Exclude references with a `pull_request` field.
Close remaining open linked issues with state reason `completed`, then re-fetch them.
Do not change issues for a closed, unmerged PR or a non-default-branch merge.

Continue independent targets when one needs an unresolved decision or external action.
Use the playbook's completion table and report material actions and blockers.
Do not classify pending reviews or checks as complete.
