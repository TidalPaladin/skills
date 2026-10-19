# Git Workflow Reference

Read the sections needed for the current operation.
Use [the skill](../SKILL.md) for invocation and GitHub authorization.

## Commits and Branches

Inspect status, relevant diffs, and branch tracking before changing Git state.
Stage explicit task paths or selected hunks. Preserve unrelated changes.
Write concise imperative commit messages that explain the change.

For reproducible bugs, confirm a failing regression before the fix.
Run relevant repository gates before publication. Reuse passing results when
the validated inputs have not changed. Report checks that cannot run.

Create branches from a current intended base.
Refresh remote state when branch creation or publication requires it.
Avoid switching or updating the user's checkout merely to inspect another branch.

Do not bypass hooks or signing policy without explicit authorization.
Do not commit or push directly to `main` or `master` without task-specific authorization.
Never force-push those protected branches.

## Worktrees and Recovery

Use an isolated worktree when another branch would disturb active work.
Use a persistent location for work that must survive reboot.
Remove only task-created worktrees whose changes are preserved elsewhere.

Inspect `git reflog` to locate lost commits. Prefer a recovery branch or
cherry-pick over destructive resets.
Ask before destructive restore, reset, clean, or deletion that risks user work.

## Pull Request Creation

Inspect the full branch diff against the intended remote base.
Before you create a PR, run `$review-fix-loop` with `scope=session` and the PR base.
Complete at least one round. Create PRs as drafts unless instructed otherwise.
Use a concise title under 70 characters and this body structure:

```markdown
## Motivation
<Concrete user or runtime problem.>

## Solution
<How the change addresses that problem.>

## Changes
<Complete branch changes relative to the target.>

## Test plan
<Validation performed, results, and blocked checks.>

## Test suite changes (Required when test coverage changed)
<Removed or materially altered tests, rationale, and replacement coverage.>

## Review
<Local review-fix-loop rounds, reviewers, fallback, final state, and reviewed head SHA.>

Generated with <tool name>
```

Write the `## Review` section as one line, for example:
`3 rounds of local review-fix-loop (Codex, Claude); clean at abc1234.`
Count the rounds of all loops for the PR. When the loop stopped with open
findings, post one top-level PR comment that lists each open finding with its
priority, location, and disposition. Refer to that comment in the section.

Omit the test-suite section when tests and coverage intent did not materially
change. Cosmetic test edits do not require it. Include only useful examples,
diagrams, or critical deferred work.

For issue-backed changes, include `Closes #N` or
`Closes OWNER/REPOSITORY#N` as appropriate.
Preserve issue traceability in subsequent body updates.

Derive repository, head, and base from current Git or GitHub evidence.
Use existing labels when appropriate. Create labels only when requested.
Fetch the published PR to verify its body, base, and draft state.
Update the body when later commits change the scope, validation, or review evidence.

Do not post `@codex review` or request other GitHub-hosted AI reviews unless
the user explicitly asks for them.

## GitHub Actions Validation

For current-revision CI evidence or scheduled runs, read
[Actions validation](actions-validation.md).

## Reading and Responding to Reviews

Read formal reviews, inline threads, and top-level comments.
Verify findings against the current code and complete diff.
Reply to addressed findings with the fix and relevant validation evidence.

Resolve conversations only when authorized by the current workflow.
The lifecycle skill permits directly addressed Codex threads and preserves
human-authored threads. Follow its narrower rules when it applies.

## Published History

Treat any remotely published branch as published, even before review starts.
Use new follow-up commits. Rebase, amend, squash, or force-push published history
only when explicitly authorized. Use `--force-with-lease` for an authorized rewrite.

Local unpublished work can be rebased or consolidated within task scope.
Follow the repository's merge strategy when merging is requested.
Prefer squash merge by default, or rebase merge when individual commits matter.
