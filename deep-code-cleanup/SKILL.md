---
name: deep-code-cleanup
description: Perform an exhaustive, iterative cleanup of a requested scope while preserving behavior.
---

# Deep Code Cleanup

Accept `$deep-code-cleanup`, optional paths or functions, and `aggressive` for
repository-wide scope even when active changes exist.

## Select the Scope

Explicit targets include their affected tests and documentation. Otherwise:

- On a feature branch, inspect the branch diff plus relevant working changes.
- On `main` or `master`, use active changes, or the repository when clean.
- Resolve the base from `origin/main`, `origin/master`, `main`, then `master`.
  Use the merge base for the comparison.

Exclude unrelated untracked packages, generated files, caches, and vendored
trees unless requested. Preserve unrelated work.

## Complete the Cleanup

Inspect the whole scope for concrete maintenance costs. Group shared causes,
such as duplicated policy, tangled responsibilities, or brittle tests.
Describe substantial changes in a progress update and proceed with authorized work.

Preserve behavior, public interfaces, dependency versions, and data formats.
Report design problems with evidence and continue safe local improvements.
Ask only when a necessary change exceeds the accepted scope or requires a
material behavior decision.

Add characterization coverage before refactoring weakly tested behavior.
For an authorized bug fix, confirm a failing regression first.
Make coherent passes and run the smallest useful validation after each.
Reinspect the diff for accidental behavior changes and new complexity.

Continue until no concrete, safe, in-scope improvements remain. Do not stop at
the first refactor or iterate on subjective style changes. Resolve routine
tooling and test failures caused by the work. Report external blockers and
continue independent work.

Run required repository gates on the final state. Report the comparison base,
improvements, behavior-preservation evidence, validation, and deferred decisions.
