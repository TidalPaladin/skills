---
name: cli-design
description: Design and review command-line interface user experience standards for text and JSON output, color handling, verbosity, progress reporting, stdout/stderr separation, and exit-code semantics. Use when implementing new CLI commands, refactoring CLI output, defining flags such as --color/--format/--quiet/--verbose/--progress, or auditing a tool for Unix composability and automation-safe behavior.
---

# CLI Design

## Overview

Apply consistent CLI UX conventions across output structure, flags, colors, status reporting, and machine-readable formats.
Read `references/cli-design.md` first and treat it as the canonical style guide.

## Workflow

1. Identify command intent and output modes (human text, machine JSON, optional JSONL streaming).
2. Define flags and precedence:
   - `--format {text|json}`
   - `--color {auto|always|never}` and `--no-color`
   - `--quiet` and `--verbose` (mutually exclusive)
   - `--progress {auto|always|never}` where relevant
3. Specify stream ownership:
   - stdout: primary data/report
   - stderr: progress, warnings, diagnostics, runtime errors
4. Design text layout:
   - status header or title variant
   - sectioned blocks with aligned key-value pairs
   - consistent number formatting and deterministic ordering
5. Design machine output:
   - JSON document for non-streaming cases
   - JSONL for streaming or append-only workflows
   - color and progress disabled for JSON mode
6. Define exit code contract (`0`, `1`, `2`) and map all outcomes explicitly.
7. Validate with representative runs:
   - terminal vs piped stdout
   - `--format json` parseability (`jq`)
   - `--quiet` and `--verbose` behavior
   - `--color` and `--progress` precedence

## Deliverables

When asked to implement or review a CLI, provide:
- A concise contract for flags, output modes, and exit codes.
- A concrete output sketch (text and JSON examples if applicable).
- Any gaps or regressions against `references/cli-design.md`.
- Exact code changes needed to enforce the contract.

## Reference

- Primary guide: `references/cli-design.md`
