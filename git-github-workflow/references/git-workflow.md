# Git Workflow Reference

How to work with git and GitHub.

## Commit Workflow

**Staging:** Files are staged individually by name rather than using `git add .` or `git add -A`, which can accidentally include sensitive files (`.env`, credentials) or large binaries. Only stage changes relevant to the current task unless otherwise requested. If a file contains a mix of task-related and unrelated changes, use `git add -p` to stage specific hunks rather than the entire file when running interactively. In non-interactive environments, avoid creating mixed files and stage only task-pure files by explicit path.

**Commit messages:**
- Imperative mood, concise (1-2 sentences)
- Focus on the "why" rather than the "what"
- Accurate verb choice: "add" for new features, "update" for enhancements, "fix" for bug fixes
- Passed via HEREDOC to preserve formatting:

```bash
git commit -m "$(cat <<'EOF'
Add dataset validation for parquet files
EOF
)"
```

**Before committing:** `git status`, `git diff`, and `git log` are run to understand the current state, review staged changes, and match the repository's existing commit message style.

**Before pushing:** Run repository-relevant code quality checks and unit tests, and only push when they pass. If a check cannot run locally, document why and what CI job or downstream validation is expected to cover it.
If the repository defines quality targets in a Makefile (for example, `make lint`, `make test`, `make check`, `make quality`), use those targets before equivalent one-off commands.

## Fix Implementation Order

- For any fix, whether prompted by a code review comment or by a bug found through another path, first add a regression test that reproduces the issue.
- Run that new regression test and confirm it fails before changing the main code.
- After implementing the fix, rerun the regression test and relevant quality checks, and confirm they pass before pushing.

## Branch Management

- Check current branch state and tracking status before any operations
- Never commit directly to `main` or `master` unless the user explicitly authorizes it for the current task
- Never push directly to `main` or `master` unless the user explicitly authorizes it for the current task
- Before creating a new branch or worktree, verify the local base branch is not behind `origin/<base>`:

```bash
git fetch origin
git switch <base>
git rev-list --left-right --count origin/<base>...<base>
```

- Treat the first number as "behind" and the second as "ahead"; only continue when behind is `0` (up to date or ahead)
- If behind is non-zero, fast-forward the base branch first (for example: `git pull --ff-only`)
- Never run destructive commands without explicit user approval:
  - `push --force`
  - `reset --hard`
  - `checkout .` / `restore .`
  - `clean -f`
  - `branch -D`
- Never skip hooks with `--no-verify` unless explicitly requested
- Do not bypass commit signing policy with `--no-gpg-sign` unless explicitly requested
- Never force push to `main` or `master`
- If force push is explicitly approved, use `--force-with-lease` instead of `--force`
- Avoid interactive flags (`-i`) in non-interactive environments. Use them only when a TTY is available and they are necessary (for example, `git add -p`).

## Worktrees

Use `git worktree` when you need to work on a separate branch without disrupting in-progress work on the current branch. This avoids stashing uncommitted changes or switching branches in a dirty working tree.

Common scenarios:
- Reviewing or fixing a PR while in the middle of unrelated work
- Running tests on one branch while developing on another
- Comparing behavior across branches side by side

```bash
# Create a worktree for an existing branch
git worktree add /tmp/project-hotfix hotfix/issue-42

# Create a worktree with a new branch from a verified base branch
git worktree add /tmp/project-review -b review/pr-15 <base>

# List active worktrees
git worktree list

# Remove a worktree when done
git worktree remove /tmp/project-hotfix
```

Using `/tmp/` for worktree paths is a good option for short-lived tasks (reviews, quick hotfixes). For long-running branches, large build artifacts, or any work that must survive reboot, prefer a persistent directory (for example, `../worktrees/`). Each worktree is a separate checkout with its own working directory, so builds, venvs, and editor state in the main tree are unaffected.

## GitHub Interface and Authorization

Use local `git` for checkout-local work: branch inspection, branch creation, staging, committing, and pushing.
Prefer the Codex GitHub app/connector tools for GitHub-side work so Codex can track repository and issue lookup, pull requests, reviews, comments, merges, and workflow activity.

The GitHub plugin is the installable package. The GitHub app/connector tools are the live Codex macOS app interface for GitHub data and actions. Prefer those tools because Codex can track the PRs, comments, commits, and app-backed actions in the desktop app.

For task-related operations on repositories owned by `TidalPaladin` or `medcognetics`, the user grants standing authorization to use authenticated `gh` for reads and writes. This includes issues, pull requests, reviews, releases, repository administration, workflow dispatch and reruns, run management, job and step inspection, and log reads. The owner match is case-insensitive.

Before the first GitHub-side operation, resolve the repository owner and inspect the active tools for an app operation that covers the task. Use the app when it is available and adequate. If it is unavailable, incomplete, or fails because of an app-specific capability or authentication gap, verify authenticated `gh` access and continue with `gh`. Do not stop to request app installation or permission to use `gh`. For another repository owner, require authorization in the current user request.

Ask before an operation on a standing-authorized repository only when:

- directly dispatching or rerunning a workflow where user-provided information or prior-run evidence shows that any GitHub-hosted job runs longer than 30 minutes;
- changing branch protection rules or GitHub rulesets that implement branch protection; or
- the operation has substantial destructive potential, meaning a material risk of unrecoverable data loss or destruction of important repository history.

The workflow approval gate does not apply to self-hosted jobs or to workflows triggered indirectly by a push, pull request, merge, or another authorized operation. An unknown runtime does not satisfy the known-runtime condition. Read-only inspection of branch protection and rulesets is authorized. These gates apply whether the app or `gh` performs the operation.

## Pull Request Creation

**Preparation:** Before creating a PR, sync remotes and analyze the full commit history on the branch (all commits since diverging from the base branch, not just the latest):

```bash
git fetch origin
git log origin/<base-branch>..HEAD
git diff origin/<base-branch>...HEAD
```

**PR structure:**
- Title: under 70 characters, concise summary
- Body uses this format:

```
## Motivation
<a few sentences on why this change is needed>
`Motivation` should describe the end-user/runtime problem being solved (impact and urgency), not branch, sequencing, or process context.
If scope isolation was important for delivery, include that under `## Changes`.

## Solution
<a few sentences on how the problem was solved at a high level>

## Changes
- <a few bullet points describing the changes in concrete detail>

## Test plan
<a few sentences or bullets describing unit/integration coverage for changed pathways and regression checks>
- [ ] <testing checklist items>

## Test suite changes (Required when test coverage changed)
If this PR did not remove tests, materially alter tests, or change coverage intent, omit this section from the PR body.

- [ ] List unit tests that were removed and explain why.
- [ ] List unit tests that were significantly altered and explain what behavior changed.
- [ ] If coverage intent changed, include replacement tests or replacement strategy.

**Definition of “significantly altered”:** a test is significantly altered when assertions, setup, or coverage intent change in a way that materially changes what behavior the test protects. Cosmetic edits (formatting, variable names, or message text) are not sufficient.

<If the number of tests is large (5+), optionally include this collapsed section:>
<details>
<summary>Detailed test coverage (optional expand)</summary>

- `test_name_1`: <what behavior/path it validates>
- `test_name_2`: <what behavior/path it validates>
</details>

## Deferred Changes (Optional)
<only critical follow-up work needed to close glaring holes in this PR; exclude minor next steps, polish, and nice-to-haves>

Generated with <tool name> (Codex, Claude Code, etc.)
```

When there are fewer than 5 relevant tests, the collapsed test-details section can be omitted.

The PR body should provide traceability: if a regression occurs, the Motivation, Solution, Changes, and Test plan sections should help identify likely root-cause areas quickly.
When creating or updating the PR body, describe the **complete set of changes in the branch relative to the target base branch** (`git diff origin/<base-branch>...HEAD`), not just the last conversational change. If multiple fixes, refactors, docs updates, test updates, or risk-reducing cleanups were made during the session, include the full picture so reviewers can infer intent and impact across the entire patch set.

**Usage examples:** When appropriate, include a brief usage snippet in the PR body showing how to exercise the change, along with sample program output. Keep these concise; a few lines of invocation and output is enough to demonstrate the feature or fix without bloating the PR description.

**Rich formatting:** Where it aids clarity, use markdown tables to present structured data (e.g. before/after comparisons, configuration options, benchmark results) and mermaid diagrams to illustrate flows or architecture changes in the PR body.

**Closing keywords:** When a PR addresses a GitHub issue, include a closing keyword in the PR body (e.g. `Closes #42`, `Fixes #15`) so the issue is automatically closed when the PR merges.

**Pushing and creating:**
- Before pushing, rerun any relevant code quality checks and unit tests for the final branch state.
- Prefer Makefile-defined quality targets when available.
- Push with `-u` flag to set upstream tracking
- Create a new branch if needed
- After the branch exists remotely, use the GitHub app/connector PR creation tool when available or `gh pr create` otherwise. Derive:
  - `repository_full_name` from the `origin` remote URL or app-backed repository lookup.
  - `head_branch` from `git branch --show-current`.
  - `base_branch` from explicit user instructions, app-backed repository metadata, or the remote default branch.
- Always create PRs as draft unless otherwise specified.
- If a fork, different push remote, or another cross-repository case is not representable by the app tool, use `gh` without additional permission when the target repository is standing-authorized. For another owner, require authorization in the current user request.
- For PRs that remove or significantly alter unit tests, ensure the PR body includes `## Test suite changes (Required when test coverage changed)` with explicit removed or altered test names and rationale. If no unit tests were removed or altered and coverage intent did not change, this section can be omitted.
- When pushing to an existing PR, use GitHub app/connector tools or `gh` to update the PR body or post a PR comment with the same required test-suite traceability details before or with the push, including any removed or significantly altered tests.

**PR labeling:** When possible, add repository-standard labels that improve triage (for example: `bug`, `enhancement`, `documentation`, `dependencies`, `breaking-change`, `needs-tests`).

Use GitHub app/connector tools when available or `gh` to inspect, add, and remove PR labels. Prefer existing labels over creating new ones unless explicitly requested.

## GitHub Actions Validation

Apply this section when GitHub Actions is the repository's CI provider. Do not keep a Codex turn open while waiting for CI.

### Pull-request runs

Identify the workflows and jobs expected for the current pull-request revision from repository workflow files and branch-protection policy. Record:

`PR head SHA | Run head SHA | Run ID | Run attempt | Run URL | Event | Expected jobs`

Discover runs through the GitHub connector when available or `gh` otherwise, and accept a run only when its head SHA matches the current PR head SHA and its event is the intended pull-request event. Fetch all job conclusions and compare the observed jobs with the expected set. Do not infer success from elapsed time, a summary label, or a prior revision.

### Scheduled workflow runs

For every new or changed scheduled workflow, require a successful `workflow_dispatch` run from the exact branch or tag under review. The workflow file must exist on the default branch before GitHub enables manual dispatch. This default-branch rule is an eligibility gate; GitHub runs the workflow version present at the event's associated ref and SHA. A brand-new scheduled workflow therefore needs a two-stage introduction that first lands a safe dispatchable harness, or it must use an existing default-branch manual harness that exercises the same scheduled entry point.

Prefer the GitHub connector when it exposes workflow dispatch. If dispatch is not exposed, use:

```bash
gh workflow run <workflow-file-or-id> --ref <exact-branch-or-tag>
```

Before directly dispatching or rerunning a workflow through either interface, ask only when any GitHub-hosted job is known to run longer than 30 minutes. Self-hosted jobs are exempt, and an unknown runtime does not satisfy this condition. This gate does not apply to workflows triggered indirectly by a push, pull request, merge, or another authorized operation.

Register the run ID returned by the dispatch operation. Record:

`Workflow file and blob SHA at run head | Run ID and URL | Run attempt | Event | Requested ref | Run head SHA | Expected jobs | Job conclusions | Artifact or smoke-test evidence`

Reject the run as validation evidence when the requested ref or run head SHA differs from the revision under review, or when the workflow file blob at that SHA differs from the reviewed definition. Workflow syntax validation and ordinary pull-request checks do not prove that the scheduled path ran.

### Failures and replacement runs

Use the GitHub connector when available or `gh` to fetch the registered run's job conclusions, steps, and exact failing logs. If the failure is in scope, fix it on the existing branch in a new commit, push that commit, dispatch or observe the replacement run, and append a watch record for the replacement run ID. Preserve the completed run evidence. If job or log reads fail through both interfaces, report the gap and do not claim that the run was validated.

Literal `success` is necessary but not sufficient for successful validation. The run identity, event, ref and head SHA, expected jobs and their conclusions, and required artifact or smoke-test evidence must also match the registered validation contract. Treat `failure`, `cancelled`, `timed_out`, `startup_failure`, `action_required`, `stale`, `neutral`, unexpected `skipped`, unknown outcomes, and incomplete or mismatched validation evidence as requiring attention.

GitHub requires a manually dispatched workflow file to exist on the default branch, accepts a branch or tag as the dispatch ref, uses the workflow version at the event's associated ref and SHA, and emits `workflow_run.completed` regardless of the prior workflow's conclusion. See the official [`workflow_dispatch` event rules](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_dispatch), [workflow dispatch API](https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event), [workflow execution model](https://docs.github.com/en/actions/concepts/workflows-and-actions/workflows), and [`workflow_run` event rules](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run).

### Post-run validation and failure-only wake

Apply this wake path only when the user explicitly requests it or the exact run is defensibly estimated before dispatch to take strictly more than 10 minutes. Exactly 10 minutes and unknown runtimes do not qualify for automatic invocation. Use the ordinary bounded provider wait/status flow for those runs.

For a qualifying run, use `$notify-wake` as the authoritative contract for registration, source and delivery state, reconciliation, retries, and Codex task delivery. Before dispatching or registering a run, extend its shared watch record with:

`Repository and ID | Workflow file and blob SHA | Run ID | Run attempt | Event | Ref | Head SHA | URL | Expected jobs | Required artifact or smoke evidence | Origin task ID | Permission profile | Approval policy`

Prefer a verified GitHub App webhook ingress for `workflow_run.completed`. A repository `workflow_run` relay is acceptable only when the relay workflow exists on the default branch, has least privilege, checks out and executes no untrusted code, and sends authenticated run identifiers to a trusted ingress. Because a `workflow_run` workflow can receive privileges that the triggering workflow lacked, never pass pull-request content, workflow output, artifact contents, branch names as commands, or other untrusted values into the relay.

Before applying the attention predicate, require a trusted non-model verifier to record the observed event, ref and head SHA, workflow-file blob SHA, complete job set and conclusions, and required artifact or smoke-test evidence. The verifier may read authenticated provider metadata and predeclared job or step conclusions, but it must not download, execute, or interpret untrusted artifacts. Close literal `success` silently only when that record fully matches the registered contract. If the adapter cannot collect or prove any required evidence, if evidence needs agent inspection, or if any value is missing or mismatched, require attention so the resumed task can complete validation through the GitHub connector or `gh`. Every non-success terminal conclusion also requires attention.

Deduplicate completion events by repository ID, run ID, run attempt, and completion event. Limit wake input to trusted repository and run identifiers, ref and SHA, conclusion, validation-status code, run URL, and elapsed seconds from run start to terminal event. The resumed task must fetch jobs, logs, artifacts, and other required evidence through the GitHub connector or `gh` before diagnosis or validation.

If secure ingress is unavailable, use a bounded local non-model watcher that observes only the registered run ID and follows the same attention predicate. If no such watcher exists, report that automatic wake is unavailable instead of promising notification.

### Acceptance cases

| Scenario | Required result |
|---|---|
| Pull-request run succeeds | Verify the matching revision and complete expected-job set, persist the evidence, and close without a wake |
| Pull-request run does not succeed | Accept one wake for the completion identity, then fetch jobs and exact logs through the connector |
| Scheduled dispatch succeeds | Verify and preserve exact-ref, head-SHA, expected-job, and artifact or smoke-test evidence, then close without a wake |
| Scheduled dispatch does not succeed | Accept one wake and fetch the failing job and step log through the connector |
| GitHub reports success but evidence is missing or mismatched | Accept one wake for the validation gap and retrieve authoritative evidence |
| Completion is delivered again | Return the stored delivery result without another wake |
| Codex app-server is unavailable | Keep delivery pending and retry without changing terminal CI state |
| New scheduled workflow is absent from the default branch | Reject dispatch until a two-stage introduction or existing manual harness is available |
| Requested ref or run head SHA does not match | Reject the run as validation evidence |

## Reading & Responding to PR Reviews

**Fetching review context:** Use GitHub app/connector tools when available or `gh` to fetch PR metadata, changed files or patches, review submissions, inline review comments, review threads with resolution state, and top-level PR conversation comments. Prefer thread-aware app tools when available. Do not treat flat comments as a complete representation of unresolved review-thread state when the task depends on line anchors or resolution status.

If the GitHub app exposes only flat comments and the task depends on unresolved thread state, line anchors, or resolution status, use authenticated `gh api graphql` without additional permission for a standing-authorized repository.

**Handling feedback:**
- Read and understand each comment in context
- Make the requested changes in the codebase
- Commit fixes as **new commits** (never amend previous commits unless explicitly asked), since amending after a hook failure or during review can destroy prior work
- When addressing feedback, use GitHub app/connector tools or `gh` to reply in the original review comment thread, not as a new top-level PR comment. Keep replies short: one concise paragraph stating what changed and how it addresses the comment.

## Resolving Conversations

- Group related fixes into a single commit where appropriate
- New commits are always preferred over amends to preserve review history
- **If implementing the reviewer's suggestion:** make the change, reply in the original thread with a short paragraph indicating which commit addresses it, and mark the conversation as resolved through the GitHub app or `gh`.
- **If declining the reviewer's suggestion:** reply in the original thread with a short paragraph explaining why, and leave the conversation unresolved so the reviewer can follow up.

## Authorized `gh` Use

For task-related operations on repositories owned by `TidalPaladin` or `medcognetics`, authenticated `gh` is pre-authorized. Use it without announcing an app gap or requesting permission when the preferred app interface is unavailable or inadequate. Apply the three approval gates in `GitHub Interface and Authorization` before either interface performs the operation.

Examples:

```bash
# Create a draft PR when app PR creation is unavailable.
gh pr create --draft --title "<title>" --body-file /tmp/pr-body.md

# Fetch review-thread data when app thread data is unavailable.
gh api graphql -f query='...'
```

Before a `gh` write, resolve the repository owner and exact target. Do not print authentication tokens or other secrets. After using `gh`, summarize the GitHub-side actions performed so the user can verify the result.

## Recovery & Safety Nets

Use recovery commands to undo mistakes safely without destructive resets.

```bash
# Inspect recent HEAD and branch movements
git reflog --date=iso

# Recover a lost commit by creating a branch at that SHA
git switch -c recovery/<topic> <sha>

# Bring a recovered commit onto your working branch
git cherry-pick <sha>
```

## Rebase & Squash Policy

- **Unpublished branch (local or not yet reviewed):**
  - Rebase freely onto latest base before PR (`git fetch origin && git rebase origin/main`).
  - Squash/fixup noisy WIP commits into logical commits.
- **Published PR branch (review started):**
  - Do **not** rebase, amend, or squash by default.
  - Address feedback in **new commits** to preserve review context.
  - Rewrite history only if explicitly requested by maintainer/reviewer.
- **If history rewrite is explicitly approved:**
  - Use `git push --force-with-lease` (never plain `--force`).
  - Post a note in the PR that commit SHAs changed and why.
- **Merge strategy:**
  - Default: **Squash and merge** for most feature/fix PRs.
  - Use **Rebase and merge** only when commit-by-commit history is intentionally meaningful.
  - Avoid merge commits unless the repo explicitly requires them.
- **Non-interactive environments:**
  - Avoid `git rebase -i` unless a TTY is available and interactive use is intended.
