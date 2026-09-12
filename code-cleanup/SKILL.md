---
name: code-cleanup
description: Simplify requested code or active changes while preserving behavior.
---

# Code Cleanup

Accept `$code-cleanup` with optional paths or functions. Use explicit targets
first, then changed files. With neither, select a concrete maintenance problem
with low behavior risk. Use `$deep-code-cleanup` for a requested exhaustive pass.

Remove duplication, dead code, redundant checks, and comments that obscure the
code. Prefer existing utilities and direct control flow. Introduce helpers only
when they clarify responsibility or remove meaningful repetition.

Preserve runtime behavior and public interfaces within the cleanup scope.
Continue safe improvements while reporting changes that need a new behavior or
design decision. Do not ask again for a change already authorized by the task.

Use characterization tests before refactoring weakly covered logic. They should
pass on the baseline. For a reproducible bug within the authorized scope, confirm
a failing regression before the fix.

Run affected tests and repository gates. Finish when the selected cleanup is
complete and validated. Report what became simpler, why behavior is preserved,
and unresolved risks. Include line counts only when they help explain the result.
