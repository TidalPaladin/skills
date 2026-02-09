---
name: doc-update
description: Synchronize project documentation with repository truth and active working changes. Use when Codex is asked to update, audit, or validate AGENTS.md, README.md, CONTRIBUTING.md, CHANGELOG.md, docs index pages, or skill documentation (SKILL.md and references) so instructions stay accurate, consistent, and executable.
---

# Doc Update

## Overview

Use this skill to update documentation from current code, configuration, and workflow truth instead of assumptions.
Treat unresolved documentation mismatches as failures, not warnings.

Default to root documentation scope:
- `AGENTS.md`
- `README.md`

Include standard additional documentation when present:
- `CONTRIBUTING.md`
- `CHANGELOG.md`
- `docs/` index pages and top-level navigational docs
- affected skill docs: `SKILL.md` and relevant files in `references/`

If the user requests a narrower or wider scope, honor the request and state the scope explicitly.

## Workflow

1. Explore the project before editing docs.
   - Inventory relevant documentation files.
   - Identify canonical commands, interfaces, and workflows from repository sources (build files, config, scripts, tests, CI files, and current code).
   - Record where each factual claim comes from before editing.
2. Account for working changes.
   - Inspect staged and unstaged changes (`git status`, `git diff --staged`, `git diff`).
   - Map each in-progress change to documentation impact.
   - Document behavior implied by working changes, not only committed history.
3. Update docs from highest priority to lowest.
   - Update root docs first (`AGENTS.md`, `README.md`).
   - Update standard additional docs when present and impacted.
   - Keep terminology, command examples, and path references consistent across all updated docs.
4. Validate with strict fail-on-mismatch behavior.
   - Cross-check all updated docs for contradictions.
   - Confirm referenced files, paths, scripts, and commands exist or are explicitly marked optional.
   - Run referenced quality gates when feasible; if a command cannot run locally, state why and list remaining risk.
   - Do not report completion while unresolved instruction mismatches remain.
5. Report results in a concise audit summary.
   - List files changed.
   - List checks performed.
   - List mismatches fixed.
   - List remaining blockers (if any).

## Validation Rules (Required)

Treat the documentation update as complete only when all conditions are true:
- All in-scope docs align with current repository behavior and working changes.
- Cross-document instructions are consistent (commands, paths, flags, and process order).
- Every newly added instruction is either locally verified or explicitly marked unverified with reason.
- No stale or contradictory guidance remains in in-scope docs.

## Output Contract

Return:
1. Updated file list.
2. Validation results with pass/fail for each check.
3. Open risks or blockers, if present.
4. Key takeaways and immediate actions at the end.

## Reference

- Use `references/doc-audit-checklist.md` as the execution checklist and pass/fail rubric.
