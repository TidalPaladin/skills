# Engineering Guidance

## Work and Communication

- Be concise. State concrete results, validation, and remaining actions.
- Use ASD-STE100 for technical prose. Preserve a requested nontechnical style.
  Use `$emend` for prose cleanup or review.
- Prefer Rust or Python. Follow the repository's established language and tools.
- Read the files needed for the task. Resolve discoverable facts before asking.
- Finish authorized work, including validation and fixes caused by the change.
  Ask only for missing decisions, expanded scope, or authority outside the task.
- Preserve unrelated user changes. Check mountpoints and likely typos before
  concluding that a supplied path is missing.
- Update affected documentation when behavior or process changes.
  Add durable guidance only when it prevents a concrete recurring mistake.

## Review and Validation

Review against the intended outcome. Focus on correctness, reliability,
maintenance costs, missing cases, and useful design or implementation
simplifications. Skip backward-compatibility review unless requested.

For reproducible bug fixes, add and run a failing regression before the fix.
Use passing characterization tests to protect existing behavior during refactors.
Cover consequential failure modes and I/O boundaries with appropriate tests.

Use repository-defined formatting, linting, type checks, and tests.
Prefer Makefile targets or the same commands used by CI.
Run focused checks during edits and required gates before handoff.
Repeat checks when changes or unresolved failures justify them.
Report blocked checks and remaining failures accurately.

## Tools and Dependencies

- Use `uv` for Python, with `ruff`, `basedpyright`, and `pytest`.
- Use `rustfmt` and `clippy` for Rust. Prefer debug builds for routine validation.
  Build release artifacts when the task or repository gate requires them.
- Pin direct dependencies and retain lockfiles. Honor supported runtime versions.
  Prefer conservative updates under repository policy.
- Prefer `rg` for searches and dedicated tools when they support the operation.
  Use shell commands when no suitable tool is available.
- Batch independent reads. Keep dependent operations and mutations ordered.
- Use TikZ or SVG for LaTeX graphics, and Beamer or Markdown/Pandoc for slides.

## Security and Authority

Keep secrets and protected data out of source, fixtures, logs, and command output.
Validate external input at trust boundaries, including paths, shell execution,
deserialization, and authentication. Avoid Rust `unsafe` code.
Keep user-facing errors concise and internal diagnostics free of secrets.

Keep biological work focused on safety, prevention, analysis, and research support.
Omit operational biological details unnecessary for that purpose.

Task-related GitHub operations on `TidalPaladin` and `medcognetics` have standing
authorization for reads and writes. Prefer the GitHub connector when it supports
the operation. Otherwise use authenticated `gh` without another permission request.
Other owners require authorization in the current request.

Ask before these GitHub actions:

- Direct workflow dispatch or rerun when a GitHub-hosted job is known to exceed
  30 minutes. Self-hosted jobs and indirectly triggered workflows are exempt.
  Unknown runtime does not meet this condition.
- Changes to branch protection or rulesets that implement it.
- Operations with material risk of unrecoverable data or important history loss.

Read-only protection inspection is authorized. Task scope still determines
which authorized operations are needed.

## Specialized Workflows

- Use `$citation-verifier` for academic citation checks.
  Follow its parent-agent assignment contract.
- Use `$manage-pr-lifecycle` for requested PR lifecycle work.
  Follow its reporter assignment and review rules.
- Invoke `$notify-wake` automatically only for operations
  estimated before launch to take strictly more than 10 minutes.
  Explicit invocation bypasses that duration gate. Use ordinary waits for other work.
  Follow the skill's locked CLI, preflight, authority, and owned-wait requirements.
  Never change the active root model for a cheaper wake or relay.

When working in TidalPaladin/skills, read `REPOSITORY.md` from that checkout's root.
