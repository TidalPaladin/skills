---
name: add-test
description: Improve test coverage by adding or upgrading tests for high-impact, bug-prone code paths.
---

# Add Test Coverage

## Overview

Use this skill to add or improve tests across the target codebase while keeping behavior unchanged.

Priority is:
1. User-provided targets.
2. Active code changes (working tree).
3. Discretionary repository targets when no target is provided.

The focus is on reducing risk, increasing confidence, and preventing plausible regressions.

## Invocation Contract

Supported forms:
- `$add-test` (no explicit targets).
- `$add-test <path-or-function> ...` (optional list of targets).

Target priority:
1. If one or more targets are passed, focus only on those.
2. If no targets are passed and there are active changes, focus on changed files.
3. If no targets and no relevant changes, pick candidates at your discretion.

When no explicit target is provided (case 3), follow this ranking:
- Bug-prone and critical logic before peripheral utility code.
- Weak or missing coverage for edge cases and failure modes.
- Modules with recent regressions or explicit TODO/FIXME around correctness.
- Avoid broad, low-impact churn.

If there is no strong candidate to test from the available scope, report that clearly and do nothing.

## Objectives

1. Raise coverage on high-risk control flow, parsing, validation, error handling, ordering, and state transitions.
2. Add regression tests for plausible failure modes before changing behavior.
3. Improve existing tests to better lock in invariants and boundary conditions.
4. Keep tests actionable and meaningful; avoid trivial tests with little behavioral value.
5. Preserve production code behavior by default.

## Behavior and Safety Rules

1. Do not modify non-test code unless the user explicitly allows it.
2. Prefer small, deterministic, and fast tests.
3. Use existing fixtures, fakes, and test utilities where available.
4. Avoid adding flaky tests (timing, network, ordering nondeterminism).
5. For low-coverage or high-risk code, add focused tests before any refactor.
6. Prefer named constants over hardcoded values in tests when intent depends on shared values.
7. If critical correctness cannot be tested cleanly, report the blocker and defer.

## Execution Workflow

1. Resolve scope:
   - Parse provided targets.
   - Else inspect changed files.
   - Else identify candidate targets by risk and coverage gaps.
2. For each candidate, verify test value:
   - Can it catch a plausible bug?
   - Does it reduce ambiguity in current assertions?
   - Does it improve failure diagnosis?
3. If no strong candidate is found, report that to the user and do nothing.
4. Add one or more focused regression or behavior tests.
5. If editing existing tests, keep names and structure consistent with local conventions.
6. Summarize risk area covered and why the new tests are non-trivial.
7. If tests are deferred, document exact blockers and what signal would permit proceeding.

## Output Contract

Return a concise summary containing:
- Selected targets and why.
- Files changed (tests only, unless user approved otherwise).
- Tests added or modified and coverage gaps addressed.
- Why these tests are high-signal (not trivial).
- Repro risk reduction (what future bug class this test guards).
- Explicitly note when no strong candidate existed and no edits were made.

## Troubleshooting / Limits

- If a user target seems wrong, request confirmation before broadening scope.
- If a path looks missing, verify mountpoint/typo before concluding it is absent.
- If a requested area is hard to test without production changes, ask for approval to expand scope.
- If coverage improvement is low value or redundant, skip and report rationale.
- If requested tests risk flakiness, redesign them or decline with reason.
- If no strong candidate exists in current scope, report that outcome and stop.

