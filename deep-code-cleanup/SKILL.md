---
name: deep-code-cleanup
description: Perform thorough, iterative code-quality cleanup across a branch diff or repository while preserving behavior. Use when the user asks Codex to inspect code broadly, call out quality issues, create a cleanup plan, and keep refactoring until no safe, in-scope quality improvements remain.
---

# Deep Code Cleanup

## Overview

Use this skill for thorough cleanup passes where Codex should inspect the full in-scope change surface, identify quality issues, plan the work, implement all safe improvements, and repeat the review/fix loop until the remaining improvement opportunities are either resolved, out of scope, or require an explicit behavior/design decision.

This skill is more aggressive than `$code-cleanup`: it does not stop after one local refactor, and it should not pick a single target when a broader diff or repository scope is available.

## Invocation Contract

Supported forms:
- `$deep-code-cleanup`
- `$deep-code-cleanup <path-or-function> ...`
- `$deep-code-cleanup aggressive` when the user explicitly wants broader repo-wide cleanup even with active changes.

Target priority:
1. If the user provides targets, limit the cleanup to those targets and their directly affected tests/docs.
2. Else if the current branch is not `main` or `master`, scope to the diff between the current branch and the best available `main`/`master` base, plus relevant unstaged/staged/untracked working-session files.
3. Else if on `main`/`master` with active changes, scope to active changes and relevant tests/docs.
4. Else if on `main`/`master` with no active changes, treat the entire repository as in scope and perform an aggressive refactor.

Do not include unrelated untracked packages, generated outputs, build artifacts, virtual environments, caches, or vendored dependency trees unless the user explicitly identifies them as part of the work.

## Scope Resolution

Resolve scope before reviewing code.

1. Identify the repository root and branch:
   - `git rev-parse --show-toplevel`
   - `git branch --show-current`
2. Find the comparison base:
   - Prefer `origin/main`, then `origin/master`, then local `main`, then local `master`.
   - Use `git merge-base HEAD <base-ref>` for branch-diff scope.
3. Build the candidate file list from:
   - committed branch diff from merge base to `HEAD`,
   - staged changes,
   - unstaged changes,
   - untracked paths that appear to belong to the current work.
4. If no active changes exist on `main`/`master`, enumerate repository source files with `rg --files`, excluding generated/vendor/cache paths.
5. If an untracked path is large or ambiguous, inspect names and nearby context. Ask the user only when including it would be risky or likely unrelated.

Prefer source files over tests for issue discovery, but include tests when they reveal duplicated setup, brittle assertions, missing coverage, or unclear fixtures.

## Issue Inventory

Before editing, inspect the in-scope code and record concrete issues. Look for:

- unclear names, overloaded responsibilities, long functions, deep nesting, and hidden side effects,
- duplicated logic, repeated literals, magic values, and test fixtures that should share named constants/helpers,
- dead code, stale comments, obvious comments, debug prints, unreachable branches, and redundant wrappers,
- over-defensive checks that duplicate caller guarantees or make errors harder to diagnose,
- avoidable allocations, inefficient data structures, repeated I/O, or algorithmic choices that are unjustified for the task,
- weak error context, inconsistent logging, broad exception catches, swallowed errors, or unsafe user-facing messages,
- inconsistent style relative to the local file or project conventions,
- fragile tests, unclear assertions, excessive mocking, missing edge cases, and uncovered logic that should be characterized before refactor,
- public interfaces or data contracts whose complexity leaks into callers,
- documentation or local scripts that became stale because of the code changes.

For each issue, capture:
- file/function,
- problem,
- why it matters,
- risk level,
- proposed fix,
- test or validation needed.

Skip vague preferences. Every issue should point to a concrete maintainability, correctness, readability, performance, or testability concern.

## Design Smells

Treat repeated local issues as evidence of a possible design problem. If the same kind of cleanup appears across several files, callers must know too much about another module, tests are hard to write because responsibilities are tangled, or small changes require coordinated edits in unrelated places, call this out to the user instead of treating it as ordinary cleanup.

Report design smells with:
- concrete evidence from files/functions,
- the underlying design problem,
- why ordinary cleanup is not enough,
- safe local cleanup that can still proceed,
- suggested remedies, such as extracting a boundary, simplifying the data model, splitting responsibilities, consolidating duplicated policy, introducing a narrow adapter, or adding characterization tests before a larger refactor.

Do not implement a design-level rewrite under this skill unless the user approves the direction. Continue only with safe cleanup that does not conflict with the likely remedy.

## Planning

Create a plan that addresses the inventory in coherent passes rather than one-off edits.

Recommended pass order:
1. Baseline validation: run existing focused tests or quality gates that cover the scope when practical.
2. Characterization tests: add focused tests before refactoring weakly covered logic.
3. Safe simplification: remove noise, dead code, stale comments, redundant locals, and duplicate wrappers.
4. Structural cleanup: extract helpers, collapse duplicated control flow, improve names, and clarify boundaries.
5. Error/test cleanup: improve error context, test clarity, fixture reuse, and edge-case coverage.
6. Final verification: run formatters, linters, type checks, and tests aligned with project standards.

For substantial work, present the issue inventory and plan to the user in a concise progress update, then proceed unless a proposed change would alter behavior or public contracts.

## Safety Rules

Preserve behavior by default.

Require explicit user approval before:
- changing public APIs or serialized formats,
- changing runtime behavior, ordering, parsing semantics, error classes, auth behavior, persistence, or network calls,
- adding, removing, or upgrading dependencies,
- broadening cleanup outside the resolved scope,
- deleting files whose ownership or generation status is unclear.

Use conservative edits in high-risk areas:
- parsing,
- sorting/order-dependent logic,
- state machines,
- concurrency/async behavior,
- persistence and migrations,
- security/auth flows,
- shell execution and filesystem deletion,
- floating-point, time, timezone, randomness, and platform-specific behavior.

When fixing a concrete bug, add a regression test first and confirm it fails when practical. When performing a behavior-preserving refactor of weakly covered logic, add characterization tests first.

## Iteration Loop

Repeat until the stop condition is met:

1. Inspect the current in-scope code and diff.
2. Update the issue inventory.
3. Implement the next planned cleanup pass.
4. Run the smallest meaningful validation for that pass.
5. Re-review the resulting diff for new complexity, stale comments, test gaps, or accidental behavior changes.
6. Continue with the next pass or revise the plan.

After each pass, remove resolved issues from the inventory and record any deferred items with the reason.

Stop only when:
- no concrete, safe, in-scope quality issues remain, or
- remaining issues require behavior/design approval,
- a systemic design smell needs user direction before further refactoring, or
- validation is blocked by missing external services, missing credentials, broken baseline tests, or unavailable tooling.

Do not spin on purely subjective style churn. If an edit does not produce a clear readability, maintainability, reliability, testability, or performance improvement, leave it alone.

## Cleanup Heuristics

Prefer:
- simple names that match domain concepts,
- small helpers only when they remove real duplication or clarify responsibilities,
- existing project utilities over new abstractions,
- immutable values and named constants,
- direct control flow over clever composition,
- narrow exceptions and actionable errors,
- table-driven tests where they reduce duplication without hiding intent,
- deterministic tests with minimal mocking,
- repo-standard tools and Makefile targets.

Avoid:
- broad rewrites that only restyle code,
- abstractions created for one caller,
- speculative extensibility,
- comments that restate code,
- logging or error messages that leak secrets,
- large generated diffs,
- formatting churn outside touched scope unless a formatter requires it.

## Verification

Use project-defined quality gates first:
- `make check`, `make test`, `make lint`, or equivalent Makefile targets,
- language-native formatters, linters, type checks, and tests,
- focused test commands for changed modules when full gates are expensive.

If a full gate is too slow or blocked, run focused checks and state exactly what was skipped and why.

For each behavior-preserving change, be able to explain why behavior stayed the same:
- pure rename,
- extracted helper with identical inputs/outputs,
- removed unreachable or duplicated logic,
- replaced hand-written code with equivalent standard/project utility,
- moved tests/fixtures without changing assertions.

## Output Contract

Return a concise summary with:
- resolved scope and comparison base,
- quality issues found and fixed,
- files changed and any intentional deferrals,
- validation commands run and results,
- behavior-preservation rationale,
- systemic design smells found, with remedy options,
- remaining risks or blocked checks,
- optional LOC summary when cleanup materially changes file size.

If no concrete quality issues remain, say that directly. If issues remain but are deferred, name the approval, design decision, larger refactor direction, or external blocker needed to proceed.
