---
name: code-cleanup
description: Improve conciseness and code quality of existing or new code while preserving behavior.
---

# Code Cleanup

## Overview

Use this skill to perform safe cleanup and readability-focused refactors across code and scripts.

Priority is:
1. User-provided targets.
2. Active code changes (working tree).
3. Discretionary repository targets when no target is provided.

Cleanup work should follow clean code principles: clear naming, reduced complexity, better structure, reduced duplication, and deterministic behavior.

## Invocation Contract

Supported forms:
- `$code-cleanup` (no explicit targets).
- `$code-cleanup <path-or-function> ...` (optional list of targets).

Target priority:
1. If one or more targets are passed, focus only on those.
2. If no targets are passed and there are active changes, focus on changed files.
3. If no targets and no relevant changes, pick targets at your discretion.

When no explicit target is provided (case 3), follow this ranking:
- Main code before tests.
- Modules/functions with stronger existing test coverage first.
- Avoid broad, low-impact churn.

## Objectives

1. Increase readability/understandability.
2. Increase conciseness without reducing clarity.
3. Reduce flakiness where safe and localized.
4. Reduce duplication through shared abstractions:
   - move repeated logic into reusable helper methods,
   - prefer small, explicit helpers over inlined, duplicated control flow,
   - prefer existing standard/library utilities over reimplementing established behavior.
5. Preserve behavior by default.
6. When refactoring low-coverage code, add tests before refactor.

## Behavior and Safety Rules

1. Do not change runtime behavior by default.
2. If cleanup may alter behavior, stop and request explicit user confirmation before editing.
3. For risky areas (parsing, ordering, state transitions, error handling, platform-sensitive behavior), perform a conservative cleanup only.
4. Prefer explicit constants/functions over magic values.
5. Keep local scripts and tests aligned when touched.
6. Never introduce new dependencies without justification.

When coverage for a target is weak:
- Add focused tests first.
- Confirm they fail on baseline (where practical from context).
- Run/execute the new tests after cleanup.

## Execution Workflow

1. Resolve scope:
   - Parse provided targets.
   - Else inspect changed files.
   - Else identify candidate code locations (favor main code and high-coverage modules).
2. Rank candidates by:
   - behavior risk (low to high),
   - maintainability gain,
   - test confidence.
3. For each candidate, classify edits as:
   - safe style cleanup,
   - structural cleanup,
   - potentially behavioral.
4. Reject or defer potentially behavioral edits unless explicitly authorized.
5. Draft a minimal diff that reduces complexity and duplication first.
6. Preserve public interfaces unless the change is approved.
7. If adding new tests, keep them focused and deterministic.
8. After each file, summarize behavior-preservation rationale.
9. Report LOC impact before finalizing.

## Output Contract

Return a concise summary containing:
- Selected targets and why.
- Files changed (or intentionally deferred).
- Per-file and aggregate LOC summary:
  - lines before,
  - lines after,
  - net delta.
- Why behavior was preserved.
- Tests added or run (and what they cover).
- Flakiness and readability improvements delivered.

If exact LOC was not measured, provide an estimate and method note.

## Troubleshooting / Limits

- If a user target seems wrong, ask for confirmation before broadening scope.
- If a path looks missing, verify mountpoint/typo before assuming it is absent.
- If requested changes appear to require functional change, defer and request explicit approval.
- If no strong candidate can be identified, report that to the user and do nothing.

## Deslop Guidance

When cleaning up AI-generated or over-defended code, prioritize removing noise while keeping behavior stable:

1. Remove comments that add no durable signal, are verbose/obvious, or are stylistically inconsistent with the file.
2. Remove unnecessary defensive checks and exception handling when the caller/codepath is already validated or trusted.
3. Inline variables and small helper lambdas/functions that are declared and used once immediately after declaration.
4. Remove redundant casts/types/signature noise and checks that duplicate guarantees already enforced by callers.
5. Eliminate style inconsistencies with the surrounding file, including over-typed locals/annotations where the file does not use them.
6. Do not apply any cleanup that conflicts with repository `AGENTS.md` requirements.
