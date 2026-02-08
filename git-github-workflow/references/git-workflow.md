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

## Branch Management

- Check current branch state and tracking status before any operations
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
## Summary
- <1-3 bullet points describing the changes>

## Test plan
- [ ] <testing checklist items>

Generated with <tool name> (Codex, Claude Code, etc.)
```

**Usage examples:** When appropriate, include a brief usage snippet in the PR body showing how to exercise the change, along with sample program output. Keep these concise — a few lines of invocation and output is enough to demonstrate the feature or fix without bloating the PR description.

**Rich formatting:** Where it aids clarity, use markdown tables to present structured data (e.g. before/after comparisons, configuration options, benchmark results) and mermaid diagrams to illustrate flows or architecture changes in the PR body.

**Closing keywords:** When a PR addresses a GitHub issue, include a closing keyword in the PR body (e.g. `Closes #42`, `Fixes #15`) so the issue is automatically closed when the PR merges.

**Pushing and creating:**
- Push with `-u` flag to set upstream tracking
- Create a new branch if needed
- Use `gh pr create --draft` with the title and body passed via HEREDOC — always create as a draft unless otherwise specified

**PR labeling:** When possible, add repository-standard labels that improve triage (for example: `bug`, `enhancement`, `documentation`, `dependencies`, `breaking-change`, `needs-tests`).

```bash
# See available labels in the repository
gh label list --limit 200

# Add labels at PR creation time
gh pr create --draft --title "<title>" --body-file /tmp/pr-body.md \
  --label "bug" --label "needs-tests"

# Add labels to an existing PR
gh pr edit <number> --add-label "bug" --add-label "needs-tests"

# Remove an incorrect label
gh pr edit <number> --remove-label "needs-tests"

# Inspect labels currently applied to a PR
gh pr view <number> --json labels --jq '.labels[].name'
```

Prefer existing labels over creating new ones unless explicitly requested.

## Reading & Responding to PR Reviews

**Fetching review comments:**

```bash
# List PR comments
gh api repos/{owner}/{repo}/pulls/{number}/comments

# List PR reviews
gh api repos/{owner}/{repo}/pulls/{number}/reviews

# List top-level PR conversation comments
gh api repos/{owner}/{repo}/issues/{number}/comments

# Combined view of timeline comments (quick review pass)
gh pr view {number} --comments
```

**Handling feedback:**
- Read and understand each comment in context
- Make the requested changes in the codebase
- Commit fixes as **new commits** (never amend previous commits unless explicitly asked), since amending after a hook failure or during review can destroy prior work

## Resolving Conversations

- Group related fixes into a single commit where appropriate
- New commits are always preferred over amends to preserve review history
- **If implementing the reviewer's suggestion:** make the change, reply to the comment indicating which commit addresses it (optionally with a thumbs up), and mark the conversation as resolved
- **If declining the reviewer's suggestion:** reply with a comment explaining why, and leave the conversation unresolved so the reviewer can follow up

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
