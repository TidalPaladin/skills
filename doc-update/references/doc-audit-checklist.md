# Documentation Audit Checklist

Use this checklist when executing `doc-update`.
Mark each item as `pass` or `fail`.
Do not mark the task complete while any required item is `fail`.

## 1. Scope And Discovery

- `pass` if in-scope docs are explicitly listed before edits.
- `pass` if default scope starts with `AGENTS.md` and `README.md` when not overridden.
- `pass` if additional standard docs are included when present: `CONTRIBUTING.md`, `CHANGELOG.md`, `docs/` index pages, and affected `SKILL.md`/`references` docs.
- `fail` if scope is implicit or ambiguous.

## 2. Working Tree Awareness

- `pass` if `git status --short` is reviewed before doc edits.
- `pass` if both staged and unstaged diffs are reviewed when present.
- `pass` if in-progress code/process changes are reflected in updated docs.
- `fail` if docs only reflect committed history and ignore working changes.

## 3. Source-Of-Truth Mapping

- `pass` if each material documentation claim maps to an inspectable source (code, config, script, CI workflow, or command output).
- `pass` if command examples match current project entry points and flags.
- `fail` if claims are copied from outdated docs without verification.

## 4. Update Consistency

- `pass` if terminology is consistent across all in-scope docs.
- `pass` if command snippets, paths, and process steps are consistent across all in-scope docs.
- `pass` if stale or contradictory instructions are removed or corrected.
- `fail` if any doc conflicts with another in-scope doc.

## 5. Execution Validation

- `pass` if referenced files and paths exist, or are explicitly labeled optional.
- `pass` if referenced commands are executed when feasible.
- `pass` if non-runnable checks are documented with reason and explicit residual risk.
- `fail` if unverifiable instructions are presented as verified.

## 6. Completion Gate

- `pass` if all required checklist items are `pass`.
- `pass` if final report includes:
  - files changed
  - checks executed
  - mismatches fixed
  - remaining blockers or `none`
- `fail` if unresolved mismatches remain without blocker status.
