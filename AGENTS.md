# AGENTS.md

This file defines my personal/global engineering standards.

## Interaction with user
- Be concise.
- Present key takeaways and important actions near the end of each message.
- Prefer simple lists and tables for readability.
- If a user-provided filepath does not exist, check whether the path is under an unmounted mountpoint and whether the path may contain a typo before concluding it is missing.

## Prose quality
- Use `$emend` for strict prose cleanup or review.
- Prefer concrete, checkable facts over vague claims of importance or impact.
- Avoid em dashes outside verbatim text, filler openers, empty intensifiers, dramatic headings, and generic marketing phrasing.
- Use plain verbs and concrete nouns. Check `$emend`'s reference list when cleaning long-form prose.
- Attribute only what a source or person actually said or did.
- When contrasting two things, name the part, date, version, mechanism, policy, or supply-chain change that makes the difference real.

## Code review

Use this sequence when reviewing a change:

1. Confirm the change’s underlying goal.
   - Summarize the intended problem being solved and the expected behavioral outcome.
   - Identify assumptions the change appears to make.
2. Evaluate what the change does and why it helps.
   - Explain how the implementation maps to the goal.
   - Call out concrete benefits or improvements achieved.
3. Identify risks and pitfalls.
   - Focus on correctness, reliability, complexity, and maintainability issues.
   - Skip backward-compatibility checks unless explicitly requested.
4. Check for missing pieces.
   - Note obvious edge cases, validation gaps, observability gaps, or test blind spots.
5. Propose high-level design simplifications.
   - Suggest ways to reduce conceptual complexity, improve structure, or better match architecture.
6. Propose implementation simplifications.
   - Suggest concrete, low-risk ways to simplify code, reduce branching/duplication, and improve clarity.

## Continuous improvement
- If you struggle with a problem, hit a recurring issue, or encounter a tricky gotcha, consider adding a project-level skill or updating that project's `AGENTS.md` with future-facing guidance.
- Update a project's `AGENTS.md` whenever making significant architectural/process changes or when existing guidance is stale, incomplete, or no longer accurate.
- If a workflow grows to many repeated tool calls (for example, more than 8) and you discover a more concise approach that achieves the same result, then update the project's `AGENTS.md` with that optimization so future runs are more efficient.
- Keep added guidance specific, actionable, and minimal so it improves future execution without creating noise.

## General coding standards
- Avoid magic numbers and unnamed hardcoded values in code and unit tests; use named constants, and in unit tests prefer constants from the code under test when available.
- Prefer using Rust or Python. Rust is preferred to Python for sufficiently complex code.
- Keep functions simple, reusable, and as general as possible.
- Keep code concise and intuitive.
- Use descriptive variable names.
- Prefer declaring variables as constants or immutable unless mutability is required.
- Choose the most performant data type / data structure that meets the requirements of the task at hand.
- Consider the security and performance implications of every approach.
- Write code that is maintainable far into the future.
- Ask questions when needed to resolve ambiguity.
- Search the web, use a linter, or explore source code as needed to understand usage that is otherwise ambiguous.
- Properly document methods, and add inline comments for code sections that are difficult to follow or have gotchas.
- Follow test-driven development (TDD). Consider writing tests before implementing the main code.
- Aim to achieve >90% test coverage.
- When intentionally leaving code paths untested, add `no-cover`/coverage-ignore annotations or comments (tool-appropriate) with a brief reason.

## Definition of done
- Consider work complete only when formatting, linting, type checking (where applicable), and tests pass locally.
- Run the project-standard quality gates before handoff.
- Prefer running project-defined Makefile quality targets (for example, `make lint`, `make test`, `make check`) over one-off command invocations when those targets exist.
- Keep CI and local quality commands aligned to avoid “works locally but fails in CI” drift.
- Apply formatting and linting checks to both production code and test code (including clippy/rustfmt-equivalent test targets and any test-specific quality gates).

## Dependency and version policy
- Pin direct dependencies and commit lockfiles.
- Prefer conservative dependency upgrades on a regular cadence rather than ad hoc major jumps.
- Define and honor minimum supported tool/runtime versions per project.
- Prefer reproducible environments and deterministic installs.

## Security baseline
- Never commit secrets or sensitive tokens in source, history, logs, or test fixtures.
- Validate and sanitize all external input at trust boundaries.
- Audit dependencies for known vulnerabilities on a regular cadence.
- Treat shell execution, file paths, deserialization, and auth flows as high-risk surfaces requiring explicit review.

## Biological and life-sciences work
- Keep biological and life-sciences work focused on safety, prevention, analysis, research support, or risk mitigation.
- Omit experimental, operational, or procedural biological details that are not necessary for the safety-focused purpose.

## Testing scope
- Require unit tests for core logic.
- When implementing a fix (from code review feedback or any other bug report), first add and run a regression test that reproduces the issue and verify it fails before changing the main code; after the fix, rerun the regression test and verify it passes.
- Add integration tests for cross-module behavior and code paths that involve I/O, network, database, or filesystem interaction.
- Ensure critical paths include failure-mode and edge-case tests, not only happy-path tests.
- Fix or quarantine flaky tests immediately; do not ignore intermittent failures.

## Error handling and logging
- Return structured, actionable errors with enough context to debug root causes.
- Keep user-facing errors concise and safe; keep internal logs detailed but free of secrets.
- Use consistent logging conventions that support filtering, correlation, and automated analysis.
- Avoid temporary debug prints in committed code.

## Python
- Use `uv` to manage dependencies and execute Python code.
- Prefer executing Python from a local virtual environment if one exists.
- Use `ruff` for style checks and `basedpyright` for type checking.
- Use `pytest` for unit testing and `pytest-mock` for mocking.
- Configure as much as possible through `pyproject.toml`.

## Rust
- Use `rustfmt` for style and `clippy` for quality checks.
- Use debug builds during development and testing.
- Create a release build only when handing the session back to the user.
- Avoid `unsafe` regions.

## LaTeX
- Prefer TikZ for generating graphics.
- Prefer including SVGs via `\includesvg`, and be mindful of how text scales.
- Use Beamer for producing slideshows, or write slides in Markdown and use Pandoc to generate a slideshow.

## Makefile
- Prefer non-phony recipes.
- Avoid overly complex make recipes.
- Create make recipes for sufficiently complex execution steps that will be run regularly.

## Terminal use
- Prefer `rg` for text search and `rg --files` for file discovery; if `rg` is unavailable, use the best available alternative.
- Prefer performant CLI tools (C/Rust tools over Python, etc.).
- For sufficiently complex one-off scripts/commands, prefer writing them to a file in `/tmp/` and executing from there.

## Tool usage
- If a dedicated tool exists for an action, use it instead of raw shell commands.
- Strictly avoid raw `cmd`/terminal calls when a dedicated tool can perform the action.
- Default solver tools: `git` (all git actions), `rg` (search), `read_file`, `list_dir`, `glob_file_search`, `apply_patch`, and `todo_write`/`update_plan`.
- Use `cmd`/`run_terminal_cmd` only when no listed tool can perform the action.
- When calls are independent, run tool calls in parallel (for example todo updates, file searches, or reading multiple files) instead of sequentially.
- Before starting machine-observable work that would otherwise require another model turn only to check status, use `$notify-wake`. Arm a native event, trusted relay, or exact-target non-model watcher instead of spending model turns polling.
- For local Unix commands and existing Linux PIDs, use the locked CLI bundled under `notify-wake/` instead of writing a one-off watcher. Run `preflight` first and preserve its strict idle-task, persistent-goal, and authority-mismatch blockers.

## GitHub authorization

- For task-related GitHub operations on repositories owned by `TidalPaladin` or `medcognetics`, the user grants standing authorization to use authenticated `gh` for reads and writes. This includes issues, pull requests, reviews, releases, repository administration, and GitHub Actions operations.
- Prefer the Codex GitHub app/connector when it supports the operation so Codex can track the result. This is a tool preference, not a permission gate. If the app is unavailable or lacks the required capability, use `gh` without asking for permission.
- Ask before a GitHub operation on these repositories only when:
  - directly dispatching or rerunning a workflow where any GitHub-hosted job is known to run longer than 30 minutes;
  - changing branch protection rules or GitHub rulesets that implement branch protection; or
  - the operation has substantial destructive potential, meaning a material risk of unrecoverable data loss or destruction of important repository history.
- The workflow approval gate does not apply to self-hosted jobs or to workflows triggered indirectly by a push, pull request, merge, or other already-authorized operation. An unknown runtime does not satisfy the known-runtime condition.
- Read-only inspection of branch protection and rulesets is authorized. Repositories owned by other accounts require authorization in the current user request.

## Codex agent definitions

- In `/home/chase/skills`, store project-scoped custom agents as standalone TOML files under `.codex/agents/` and keep shared project agent limits in `.codex/config.toml`.
- Use `scripts/sync_codex_to_repo.sh` to preview or apply AGENTS.md, skill, and custom-agent updates to `${CODEX_HOME:-$HOME/.codex}`. The default is a non-mutating dry run.
- Run `scripts/test_sync_codex_to_repo.sh` and strict Codex configuration validation after changing agent definitions or sync behavior.
- Run `scripts/ci.sh` before handoff; it installs the exact Codex version from `package-lock.json`, and GitHub Actions runs the same gate on Linux x64 and macOS Arm64 with the aggregate `Required` job reserved for branch protection. `CODEX_INSTALL_MODE=existing` is reserved for the independent `Codex Latest Canary` workflow, which tests the newest stable release without joining the required gate.
- Run `scripts/audit_dependencies.sh` for local npm and Python vulnerability checks. The independent `Dependency Health` workflow runs the same locked audit weekly, while Dependabot proposes stable dependency updates.
- When invoking `pr_lifecycle_reporter`, assign exactly one pull request to each instance, establish fixed lifecycle order before fan-out, and preserve its local read-only permission mode. Process additional targets in waves of at most eight reporter instances. Require each reporter to verify `$git-github-workflow` body conformance and closing-linked issue state, including confirmed issue closure after a default-branch merge. After all waves finish, consolidate lifecycle rows by assigned queue position rather than worker completion order.
- For every citation-verification task, the parent agent must invoke `citation_verifier` and assign exactly one citation occurrence to each instance. Include the source path, line or unique context, citation key, complete surrounding claim, and bibliography entry in each assignment. Preserve each instance's read-only permission mode. Process additional occurrences in waves of at most eight instances, then consolidate citation reports in source order rather than worker completion order.
