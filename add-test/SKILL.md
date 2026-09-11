---
name: add-test
description: Add or improve tests for requested code or meaningful coverage gaps.
---

# Add Test Coverage

Accept `$add-test` with optional paths or functions. Use explicit targets first,
then changed files. With neither, choose a concrete gap in critical or bug-prone
behavior. Report a no-op when no useful gap exists.

Preserve production behavior. Production changes require scope that includes them.
Continue independent test work if another target needs a scope decision.

Use existing fixtures and test utilities. Cover observable behavior, failure
modes, and boundaries that existing assertions miss. Avoid tests that merely
repeat the implementation or add unstable timing and network dependencies.

Run affected tests and applicable repository gates. For a reported bug, confirm
the regression fails on the baseline before fixing it. Characterization tests
for correct behavior should pass before and after a refactor.

Report the coverage gained, validation results, and any remaining gap.
