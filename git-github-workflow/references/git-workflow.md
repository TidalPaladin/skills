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

## GitHub App / Connector Boundary

Use local `git` for checkout-local work: branch inspection, branch creation, staging, committing, and pushing.
Use the Codex GitHub app/connector tools for GitHub-side work: repository and issue lookup, PR creation and updates, labels, top-level comments, review comments, review threads, reactions, merge/automerge actions, and workflow metadata when available.

The GitHub plugin is the installable package. The GitHub app/connector tools are the live Codex macOS app interface for GitHub data and actions. Prefer those tools because Codex can track the PRs, comments, commits, and app-backed actions in the desktop app.

If the GitHub app/connector tools are not available, use tool discovery or plugin-install tooling when available to find or request the GitHub plugin/app. If the app still is not available, stop and tell the user to install, enable, or authorize the GitHub plugin/app in the Codex macOS app, then rerun the workflow. Do not silently switch to CLI.

Use `gh` only when the user explicitly requested CLI fallback or after reporting the exact app-tool capability gap and receiving explicit consent.

**Availability check:** Before the first GitHub-side operation, inspect the active tools for a callable GitHub app namespace such as `mcp__codex_apps__github`, or tools covering repository lookup, PR fetch/create/update, issue lookup, labels, comments, reviews, review threads, reactions, merge/automerge, or workflow metadata. If no GitHub app tools are active and `tool_search` is available, search for `GitHub pull request repository connector` and use the returned GitHub tools when they become callable. If app tools remain unavailable and plugin-install tools are available, use `list_available_plugins_to_install` and `request_plugin_install` only for an exact GitHub plugin or connector match. Continue only when the GitHub app tools are callable; otherwise stop with install/enable/authorize instructions. Do not treat `gh auth status` or successful `gh` commands as evidence that the Codex GitHub app/connector is available.

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

**Usage examples:** When appropriate, include a brief usage snippet in the PR body showing how to exercise the change, along with sample program output. Keep these concise — a few lines of invocation and output is enough to demonstrate the feature or fix without bloating the PR description.

**Rich formatting:** Where it aids clarity, use markdown tables to present structured data (e.g. before/after comparisons, configuration options, benchmark results) and mermaid diagrams to illustrate flows or architecture changes in the PR body.

**Closing keywords:** When a PR addresses a GitHub issue, include a closing keyword in the PR body (e.g. `Closes #42`, `Fixes #15`) so the issue is automatically closed when the PR merges.

**Pushing and creating:**
- Before pushing, rerun any relevant code quality checks and unit tests for the final branch state.
- Prefer Makefile-defined quality targets when available.
- Push with `-u` flag to set upstream tracking
- Create a new branch if needed
- After the branch exists remotely, use the GitHub app/connector PR creation tool. Derive:
  - `repository_full_name` from the `origin` remote URL or app-backed repository lookup.
  - `head_branch` from `git branch --show-current`.
  - `base_branch` from explicit user instructions, app-backed repository metadata, or the remote default branch.
- Always create PRs as draft unless otherwise specified.
- If the branch is pushed from a fork, the target repository differs from the push remote, or another cross-repository case is not representable by the app tool, report that app-tool gap and ask before using CLI fallback.
- For PRs that remove or significantly alter unit tests, ensure the PR body includes `## Test suite changes (Required when test coverage changed)` with explicit removed or altered test names and rationale. If no unit tests were removed or altered and coverage intent did not change, this section can be omitted.
- When pushing to an existing PR, use GitHub app/connector tools to update the PR body or post a PR comment with the same required test-suite traceability details before or with the push, including any removed or significantly altered tests.

**PR labeling:** When possible, add repository-standard labels that improve triage (for example: `bug`, `enhancement`, `documentation`, `dependencies`, `breaking-change`, `needs-tests`).

Use GitHub app/connector label tools to inspect, add, and remove PR labels. Prefer existing labels over creating new ones unless explicitly requested. If the app cannot list repository labels, infer conservative labels from existing PRs/issues when already visible through app data, or skip labeling and state that labels were unavailable.

## Reading & Responding to PR Reviews

**Fetching review context:** Use GitHub app/connector tools to fetch PR metadata, changed files or patches, review submissions, inline review comments, review threads with resolution state, and top-level PR conversation comments. Prefer thread-aware app tools when available. Do not treat flat comments as a complete representation of unresolved review-thread state when the task depends on line anchors or resolution status.

If the GitHub app exposes only flat comments and the task depends on unresolved thread state, line anchors, or resolution status, report that app-tool gap and ask before using CLI fallback.

**Handling feedback:**
- Read and understand each comment in context
- Make the requested changes in the codebase
- Commit fixes as **new commits** (never amend previous commits unless explicitly asked), since amending after a hook failure or during review can destroy prior work
- When addressing feedback, use GitHub app/connector tools to reply in the original review comment thread, not as a new top-level PR comment. Keep replies short: one concise paragraph stating what changed and how it addresses the comment.

## Resolving Conversations

- Group related fixes into a single commit where appropriate
- New commits are always preferred over amends to preserve review history
- **If implementing the reviewer's suggestion:** make the change, reply in the original thread with a short paragraph indicating which commit addresses it, and mark the conversation as resolved through the GitHub app when possible.
- **If declining the reviewer's suggestion:** reply in the original thread with a short paragraph explaining why, and leave the conversation unresolved so the reviewer can follow up.

## Explicit CLI Fallback

Use CLI fallback only when the user explicitly requested it, or after you have reported the exact GitHub app/connector capability gap and received explicit consent. State the operation, the app-tool gap, and the command you will run before using fallback.

Fallback-only examples:

```bash
# Create a draft PR only after app PR creation is unavailable and fallback is approved.
gh pr create --draft --title "<title>" --body-file /tmp/pr-body.md

# Fetch review-thread data only after app thread data is unavailable and fallback is approved.
gh api graphql -f query='...'
```

After using CLI fallback, summarize which GitHub-side actions used CLI instead of app tools so Codex app linkage gaps are visible.

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
