---
name: benchmark-optimize
description: Run benchmark-driven optimization on a performance-critical section with evidence-first comparison and clear reporting of measured gains; default to Criterion for Rust and language-appropriate benchmarking in other stacks.
---

# Benchmark-Optimize

## Overview

Use this skill when the user wants performance work to be guided by measurements, not guesswork.

When a target is provided, optimize that target directly.
When no target is provided, pick a target at your discretion by using objective signals (slow tests, profiling traces, hot paths, high fan-out, or known bottlenecks) and favor areas that already have broad, stable coverage.

Runtime performance is primary, but disk I/O, network I/O, and memory usage are explicit optimization dimensions whenever relevant.

## Invocation Contract

Accept either:

1. Explicit target:
   - fully-qualified method/function (`module::type::method`, `package.function`, etc.)
   - process description (example: `request parsing`, `pagination`, `image diff`)
2. No target:
   - choose one target yourself using repo evidence and report why it was chosen.
3. Optional language hints:
   - `rust`, `python`, `typescript`, `javascript`, `go`, `java`, etc.

If required inputs are missing (e.g., language and target is ambiguous), stop with one focused clarifying question before editing code.

Plan-mode checkpoint:
- If invoked in plan mode, do this first:
  1. Propose one concrete optimization target.
  2. Provide a short theoretical justification for why that target is likely a bottleneck and why the proposed optimization should improve performance.
  3. Ask the user to approve proceeding with that target before:
     - designing or editing benchmark harnesses,
     - producing an optimization plan,
     - making code changes.

## Workflow

1. Confirm scope
   - Determine language and execution model of the target (single function vs multi-stage process).
   - Locate existing performance and correctness tests around the area.
2. Choose benchmark target
   - If target is explicit: use it.
   - If target is implicit:
     - rank candidates by expected runtime impact and test coverage;
     - prefer targets with deterministic inputs and strong baseline tests.
3. Baseline capture
   - Create or extend benchmark harness before optimization.
   - Measure with warm-up and stable hardware assumptions where possible.
- Capture:
  - throughput or iteration rate,
  - latency distribution,
  - memory/alloc behavior,
  - disk I/O behavior (read/write throughput, call volume, fsync/fdatasync rate),
  - network I/O behavior (request count, bytes sent/received, retry rate, queue/latency indicators).
4. Optimize only what the data identifies
   - Make focused changes and keep behavior unchanged.
   - If multiple approaches are viable, benchmark each variant and keep the best.
5. Verification
   - Re-run existing tests that cover the target path.
   - Re-run the same benchmark workload and compare directly to baseline.
6. Reporting
   - Summarize results with clear measured deltas and confidence notes.
   - If no measurable improvement exists, explain why and either keep baseline code or pick a different target.

## Benchmarking workflows

### Rust (required: Criterion)

Use `criterion` for production-grade timing and statistical comparison.

- Add/confirm `criterion` in `Cargo.toml` under `dev-dependencies`.
- Add a benchmark file under `benches/`:
  - use `criterion::{black_box, Criterion, criterion_group, criterion_main}`.
  - feed realistic, representative input sets.
  - include baseline and candidate implementations in the same benchmark group when possible.
- Run:
  - `cargo bench` for baseline and post-change comparison.
  - include the exact command and sample size configuration used.

### Non-Rust

- Python: prefer `pytest-benchmark` (or `pyperf` for lower-noise process-level runs).
- TypeScript/JavaScript: prefer Benchmark.js or `node --test --test-name-pattern` with timing hooks and a repeatable runner.
- Go: prefer `testing.B` benchmarks (`go test -bench`), with clear environment notes.
- Java: prefer JMH with warmup/measurement settings pinned in command or annotations.

Adjust benchmark harness for language conventions, but keep comparison methodology identical.

## Output contract

Return a structured summary including:

- Target chosen or explicit target confirmed.
- Benchmark harness added/modified (file paths).
- Baseline metrics:
  - mean/median,
  - variance/uncertainty notes,
  - sample count or confidence settings.
- Optimized metrics:
  - same metric set for the new implementation.
- Resource metrics (if applicable):
  - peak and steady-state memory,
  - disk throughput/ops and sync behavior,
  - network throughput/ops and retry/error profile.
- Computed performance delta:
  - absolute and percentage change,
  - whether result is a true win within observed noise.
- Test impact:
  - list of relevant tests run and status.
- Decision:
  - “ship”, “iterate”, or “stop, no statistically meaningful gain”.
