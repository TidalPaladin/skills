# AGENTS.md

This file defines my personal/global engineering standards.

## Interaction with user
- Be concise.
- Present key takeaways and important actions near the end of each message.
- Prefer simple lists and tables for readability.
- If a user-provided filepath does not exist, check whether the path is under an unmounted mountpoint and whether the path may contain a typo before concluding it is missing.

## Continuous improvement
- If you struggle with a problem, hit a recurring issue, or encounter a tricky gotcha, consider adding a project-level skill or updating that project's `AGENTS.md` with future-facing guidance.
- Update a project's `AGENTS.md` whenever making significant architectural/process changes or when existing guidance is stale, incomplete, or no longer accurate.
- Keep added guidance specific, actionable, and minimal so it improves future execution without creating noise.

## General coding standards
- Avoid magic numbers and unnamed hardcoded values. Use named constants instead.
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
- Keep CI and local quality commands aligned to avoid “works locally but fails in CI” drift.

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

## Testing scope
- Require unit tests for core logic.
- When fixing a bug, add a regression test that reproduces it; ideally write the test first, verify it fails, then implement the fix and verify it passes.
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
- Prefer performant CLI tools (C/Rust tools over Python, etc.).
- For sufficiently complex one-off scripts/commands, prefer writing them to a file in `/tmp/` and executing from there.
