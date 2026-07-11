# Pull-Request Lifecycle Playbook

## Contents

- Connector and repository boundaries
- Target ordering and state snapshot
- Target synchronization and conflicts
- Review findings
- CI diagnosis and queue control
- Codex review
- Human approval
- Readiness classification
- Completion report

## Connector and Repository Boundaries

Use local `git` for remotes, checkouts, target synchronization, conflict resolution, commits, worktrees, and pushes. Use the Codex GitHub app or connector for pull-request metadata, changed files, comments, reviews, review threads, ready-for-review transitions, reviewer requests, CI metadata, workflow logs, workflow reruns, and pull-request body updates.

Run the `$git-github-workflow` availability check before the first GitHub-side operation. Never silently fall back to `gh`. If a required connector capability is unavailable, report the exact gap and request user direction.

Use one reusable worktree when the main checkout contains unrelated changes or several repositories are involved. Process branches sequentially when practical. Add another worktree only for an active dependency stack or to protect unrelated dirty work, and remove task-created worktrees when no longer needed.

Never invoke connector merge, auto-merge, review-dismissal, or thread-resolution actions. Never rebase or force-push a published branch without explicit approval.

## Target Ordering and State Snapshot

Honor explicit order first. Otherwise identify pull requests whose target is another selected pull-request branch, process parents before children, and order independent targets by ascending pull-request number. Keep this order stable for the iteration.

For every target, fetch:

- Repository, pull-request number, state, draft state, author, title, body, labels, and requested reviewers.
- Target branch, target SHA, head branch, head SHA, fork ownership, and push permission.
- Mergeability, merge conflicts, branch-protection requirements, and whether the target SHA is an ancestor of the head.
- Complete changed-file list and patch where needed to understand findings or substantial changes.
- Combined commit status, required checks, workflow runs, jobs, steps, logs, and artifacts needed to diagnose failures.
- Top-level comments, formal review submissions, inline review comments, and review threads with resolved and outdated state.
- Linked issue bodies and new comments when they define acceptance criteria or report new evidence.

Do not count a review trigger as a completed review. Record the commit or material revision covered by each Codex and human review. Re-fetch all state that may have changed before assigning the final status.

Report merged or closed pull requests as `terminal`. Do not reopen or mutate them.

## Target Synchronization and Conflicts

Synchronize before review or CI work:

1. Fetch the current target and head branches.
2. Verify that the local head matches the published pull-request head before editing.
3. Determine whether the target SHA is already an ancestor of the head.
4. Merge the current target into the published head when it is behind or conflicting.
5. Resolve conflicts against current requirements and inspect every resolution for lost behavior or tests.
6. Run focused checks for conflicted surfaces, then repository-standard formatting, linting, type checks, tests, scans, and benchmarks that the resolution can affect.
7. Commit and push as a new commit. Do not amend, rebase, squash, or force-push.

For a stacked child, use its declared parent branch as the target until the parent lands. After the parent lands, inspect the child diff against the repository default branch. Retarget only when the diff remains correct without rewriting history; otherwise request approval.

Treat missing push permission, unsafe history rewriting, or irreconcilable conflict requirements as blockers. Continue with independent targets.

## Review Findings

Evaluate each current, non-outdated comment in file and patch context. A thread may remain unresolved even after its finding is addressed because this skill never resolves threads.

For an accepted finding:

1. Add a failing regression first when the comment describes a bug or missing invariant.
2. Implement the smallest complete correction.
3. Run focused and repository-standard gates.
4. Commit and push a new follow-up commit.
5. Reply in the original thread with the commit and concise validation result.
6. Leave the thread unresolved.

For an invalid, duplicate, or out-of-scope suggestion, reply with concrete repository evidence or scope rationale and leave the thread unresolved. For an actionable top-level comment, post a concise top-level response that identifies the addressed comment and commit. Treat an incompatible blocking request as a blocker requiring user direction.

After a push, re-fetch reviews and threads. Do not assume a code update changes review state. If branch protection requires conversation resolution, report the reviewer or maintainer action required.

## CI Diagnosis and Queue Control

Associate status and workflow results with the current head SHA. Do not treat a passing or failing run on an older commit as current.

For a failure:

1. Inspect the failed workflow, job, step, and relevant logs.
2. Classify it as branch-caused, flaky, cancelled, infrastructure, permission, quota, or external-service failure.
3. Fix branch-caused failures with tests and a new commit.
4. Rerun only failed jobs when evidence supports a transient failure and the connector exposes a narrow rerun.
5. Report external failures with the required owner or infrastructure action.

Do not use reruns to hide deterministic failures. Run local equivalents before pushing a CI fix.

For fewer than five targets, allow normal CI on each pushed commit. For five or more targets:

1. Keep the fixed target order.
2. Select the first non-terminal, non-blocked target that can advance as the active CI target.
3. Inspect repository workflows and every relevant CI provider before using skip directives.
4. Use `[skip ci]` only for lifecycle-generated commits on later queued targets when all relevant providers honor it and local affected gates pass.
5. If skip behavior or required-check consequences are uncertain, do not skip CI.
6. Mark current, reviewed downstream heads with intentionally deferred CI as `queue-ready`.
7. When a queued target becomes active, reuse current passing CI if it covers the current head. Otherwise create and push `git commit --allow-empty -m "Run CI"`.

When skip behavior is verified, only the active target should receive an intentional fresh CI trigger. If skip support is absent, allow normal CI to run on queued commits. A queue-ready target is not merge-ready.

## Codex Review

Inspect top-level comments and review submissions for:

- A completed public Codex review covering the current material revision.
- An `@codex review` trigger posted after the last completed review.
- Codex findings and the commits or replies that address them.

When a pull request is still a draft, promote it only after implementation is complete, local checks pass, the target is synchronized, no known branch-caused CI failure remains, and known findings are addressed. Deferred CI for a later large-queue target does not prevent promotion.

Post exactly `@codex review` as a top-level comment when the pull request is ready and neither a completed current review nor a pending trigger exists.

Do not request another Codex review for target-only merges, formatting, test-only updates, or narrow fixes responding to existing review findings. Request one additional review only after a material change to behavior, public interfaces, architecture, security posture, schemas, or a substantial portion of the patch. Record why the new review was necessary.

## Human Approval

Wait until a completed Codex review exists and all its findings are addressed before requesting a human review.

If the invocation names a reviewer:

1. Confirm that the login is not a bot and can be requested when the connector exposes that check.
2. Avoid duplicate requests when the reviewer is already requested or has a current approval.
3. Request the named reviewer through the connector.

If no reviewer is named and no current human approval exists, report `waiting` and state that a reviewer login or independent human approval is needed. Never choose a reviewer.

Count only a current, non-bot `APPROVED` review. Treat dismissed approvals and approvals followed by substantial changes as stale. After a substantial change, complete the new Codex review cycle before requesting renewed human approval.

## Readiness Classification

Use these statuses:

- `merge-ready`: Every readiness gate passes for the current head.
- `queue-ready`: Every non-CI gate passes, but fresh CI is intentionally deferred until the pull request reaches the front of a large queue.
- `waiting`: External review, approval, CI completion, or reviewer identity is pending and no corrective action is currently available.
- `blocked`: Credentials, permissions, incompatible requirements, branch protection, unsafe history rewriting, persistent infrastructure failure, or another concrete impediment prevents progress.
- `terminal`: The pull request is merged or closed.

Require all of the following for `merge-ready`:

- The pull request is open and non-draft.
- The intended target SHA is an ancestor of the current head and no conflicts exist.
- Required checks pass on the current head.
- A completed public Codex review covers the current material revision and all findings are addressed.
- A current non-bot approval exists and all human findings are addressed.
- The pull-request body matches the complete current diff, validation, risks, and issue traceability.
- Branch-protection requirements pass.

Addressed threads may remain unresolved. If resolution is a branch-protection requirement, classify the pull request as blocked on reviewer or maintainer resolution rather than resolving the thread.

## Completion Report

Return:

| PR | Base sync | CI | Codex review | Human approval | Ready for merge |
| --- | --- | --- | --- | --- | --- |

Use compact values that identify current SHA coverage, such as `pass`, `fail`, `running`, `deferred`, `pending`, `approved`, `stale`, `yes`, `no`, `queue-ready`, `waiting`, `blocked`, or `terminal`.

After the table:

1. List each blocker and the exact user, reviewer, maintainer, permission, or infrastructure action required.
2. List the next expected lifecycle step for every non-terminal target.
3. State which conflicts, review findings, and CI failures were addressed during the iteration.
4. State that no pull request was merged and no review thread was resolved.
