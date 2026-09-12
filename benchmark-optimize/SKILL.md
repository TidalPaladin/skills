---
name: benchmark-optimize
description: Measure and optimize a performance bottleneck with reproducible before-and-after comparisons.
---

# Benchmark Optimize

Accept a function, process, optional language hint, or no target. With no
target, choose a bottleneck supported by profiles, slow tests, or realistic
resource costs. Resolve material workload ambiguity before optimization.

Define the metric, representative inputs, environment, and acceptance criterion.
Capture a baseline before changing the implementation. Measure only resources
relevant to the target, such as latency, throughput, memory, disk, or network use.

Use the repository's benchmark framework. Otherwise use a language-appropriate tool:
Criterion for Rust, pytest-benchmark or pyperf for Python, and a repeatable Node runner for JavaScript.
Use testing.B for Go and JMH for Java. Record the command and sampling settings.

Keep correctness and public behavior stable unless the task authorizes a change.
Compare candidates with the same workload and environment. Run correctness tests
and applicable quality gates on the selected result.

Continue until a measured improvement satisfies the target or evidence rules
out the attempted approaches. Discard unsuccessful optimization edits while
preserving unrelated work. Report baseline and final metrics, uncertainty,
resource tradeoffs, validation, and the decision to retain or reject the change.

In Plan Mode, inspect existing evidence and define the benchmark and approach
without changing tracked files. No extra target-approval checkpoint is required.
