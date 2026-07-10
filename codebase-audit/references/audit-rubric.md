# Codebase Audit Rubric

## Contents

- Finding admission
- Bugs and future bug risk
- Code quality and design
- Performance
- Enhancements
- Documentation
- Cross-vector review

## Finding Admission

Admit a finding only when all conditions hold:

- Evidence points to specific code, configuration, tests, runtime behavior, or documentation.
- The effect is material to users, maintainers, reliability, security, resource use, or delivery speed.
- The desired outcome is bounded and testable without prescribing how to implement it.
- The finding is not a duplicate or a symptom of a broader admitted root cause.
- A maintainer is likely to accept the work relative to its cost and repository goals.

Record an evidence confidence for triage:

- `confirmed`: reproduced, measured, scanner-confirmed, or contradicted by an authoritative source.
- `high-confidence theoretical`: a reachable path and violated invariant establish the failure or cost without a practical reproduction.
- `risk`: no current defect is established, but a fragile high-impact path lacks a critical control or test.

Reject pure style preferences, single-use abstraction requests, speculative extensibility, low-impact defensive changes, minor wording polish, and performance claims without measurements or a sound resource argument.

## Bugs and Future Bug Risk

Look for:

- Incorrect results, crashes, hangs, corruption, unsafe defaults, security failures, and contract violations.
- Boundary errors in parsing, validation, indexing, ordering, state transitions, retries, time, randomness, persistence, concurrency, authentication, filesystem access, shell execution, and deserialization.
- Errors that are swallowed, stripped of necessary context, misclassified, leaked to users, or logged with secrets.
- Partial writes, missing rollback, non-idempotent retries, race conditions, deadlocks, resource leaks, and cleanup that fails after an intermediate error.
- Input validation gaps at trust boundaries and assumptions not enforced by callers or types.
- Critical branches with no failure-mode, negative, or regression tests.
- Fragile code where a small routine change could bypass an important invariant.

For a current bug, supply a minimal deterministic reproduction or test whenever practical. Include inputs, command, observed behavior, expected behavior, and environment details that affect the result.

For a theoretical bug, trace the reachable path from input or state to failure. Name each necessary precondition and the violated invariant. Do not call unreachable or purely hypothetical code a bug.

For future bug risk, describe the credible regression scenario, why existing controls would miss it, and the test or invariant coverage needed. Do not imply the defect already occurs.

Run the current security workflow in `security-audit.md`. Classify applicable vulnerabilities as bugs even when the vulnerable path has not yet been exploited.

## Code Quality and Design

Look for concrete maintenance costs:

- Unclear names, overloaded responsibilities, long functions, deep nesting, hidden side effects, and policy spread across unrelated modules.
- Duplicated control flow, validation, literals, fixtures, or business rules that can drift.
- Magic values, unexplained state transitions, ambiguous ownership, and public interfaces that leak internal complexity to callers.
- Dead code, stale comments, debug output, redundant wrappers, repeated conversions, and one-use helpers that obscure direct control flow.
- Broad exception handling, inconsistent logging, weak error context, unsafe user-facing errors, and unnecessary defensive checks that hide caller mistakes.
- Tight coupling, cyclic knowledge, hard-to-test boundaries, or small changes that require coordinated edits across unrelated files.
- Brittle assertions, excessive mocking, unclear fixtures, nondeterministic tests, untested edge cases, and tests that duplicate implementation details.
- Inconsistent local style that makes behavior harder to understand, excluding harmless formatting preferences.

Treat repeated local smells as one design finding when they share an architectural cause. State the responsibility, coupling, or policy-boundary problem and its effects. Do not prescribe a replacement architecture, helper layout, or refactor sequence.

Prefer findings that reduce cognitive load, defect risk, change amplification, or test difficulty. Do not request behavior changes under a quality label unless the current behavior is itself the problem.

## Performance

Review five resource dimensions when relevant:

1. Computational throughput and latency: algorithmic complexity, repeated computation, serialization, locking, scheduling, vectorization, batching, and hot-loop work.
2. Memory: peak resident size, steady-state growth, allocations, copies, retention, cache size, and data representation.
3. Disk I/O: read and write volume, syscall count, random access, repeated scans, synchronization, temporary files, and cache behavior.
4. Disk storage: duplicate artifacts, retention, compression, indexing overhead, generated outputs, and unbounded growth.
5. Network: request count, payload volume, round trips, connection reuse, retries, backoff, batching, queueing, and tail latency.

Use objective signals such as profiles, slow tests, production traces, benchmark regressions, high fan-out, large representative inputs, or known hot paths. When measurement is unavailable, require a clear complexity or resource argument tied to realistic scale.

Review benchmark coverage for important pathways. A benchmark-gap issue must name the workload, input sizes, metrics, environment controls, warm-up or sampling method, and comparison needed to detect regressions. A benchmark design may be concrete; the optimization design may not.

Reject micro-optimizations that are outside a consequential path or are likely to disappear within measurement noise.

## Enhancements

Look for improvements supported by repository evidence:

- Repeated user friction, missing common workflows, awkward composition, inaccessible capabilities, or manual steps repeated in docs, issues, scripts, or tests.
- Small extensions that broaden useful inputs or environments without making the primary path harder to understand.
- Missing automation for frequent, error-prone maintenance or release work.
- New Codex skills when repository contributors repeatedly perform a specialized workflow that benefits from stable instructions or tools.

Describe the user need, current limitation, representative use cases, and desired behavior. Preserve simplicity, predictable defaults, and Unix or ecosystem conventions where relevant.

Reject features based only on imagined future use, broad platform ambitions, or abstraction for its own sake.

## Documentation

Inspect:

- Root and package README files.
- Root and nested `AGENTS.md` files, including which instructions apply to each path.
- `CONTRIBUTING.md`, changelogs, release guides, docs indexes, API references, examples, and key Markdown files.
- Commands, paths, flags, environment variables, versions, public interfaces, schemas, and workflows named in documentation.

Map material claims to code, configuration, scripts, tests, CI, or generated help. Run documented commands when feasible. Identify:

- Stale or contradictory instructions.
- Multiple documents claiming authority for the same fact.
- Missing links between an overview and the canonical detailed source.
- Examples that no longer run or use obsolete interfaces.
- Required setup or failure recovery that maintainers and users cannot discover.

Prefer one canonical source with short links or summaries elsewhere. Do not demand a README or `AGENTS.md` solely because a conventional filename is absent. File an issue only when missing guidance causes concrete user or contributor friction.

## Cross-Vector Review

After the five passes:

- Revisit high-risk modules with their tests, benchmarks, docs, and dependency surfaces together.
- Consolidate candidates with the same root cause.
- Check whether a quality smell creates a bug risk or performance cost and choose the primary vector based on the dominant impact.
- Check whether a proposed enhancement already exists behind an undocumented interface.
- Check whether documentation mismatch explains reported user friction.
- Record inspected areas with no findings so Goal Mode can detect audit saturation.
