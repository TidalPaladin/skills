---
name: inspect-dataset
description: Explore datasets to inform parsing and manipulation code changes in deep-learning training pipelines. Use when editing training code, dataloaders, preprocessing, augmentation, or label parsing and you need to locate dataset paths from config files and inspect CSV/Parquet structure safely and quickly.
---

# Inspect Dataset

## Overview

Use this skill to identify the active dataset path and inspect tabular metadata before changing training pipeline code.
Prefer shell commands for simple checks, then use the bundled script for repeatable multi-file profiling.

## Invocation Contract

Accept any of these forms:
1. `$inspect-dataset <dataset_dir>`
2. `$inspect-dataset <config_file>`
3. `$inspect-dataset` (auto-discover config with `Makefile.config` first)

When manually invoked, treat dataset exploration as part of the task and validate related code changes against real dataset files when feasible.

## Workflow

1. Resolve dataset root path.
   - If invocation is an existing directory, use it directly.
   - If invocation is a file (or no argument), inspect config content to find dataset paths.
   - Prefer `Makefile.config`, then closely related training config files.
   - Prefer active/uncommented lines over commented lines.
2. Select one dataset path and validate it exists.
   - If missing, check for mountpoint issues and path typos before concluding it is absent.
   - Explicitly tell the user which path is selected before deeper inspection.
3. Perform shell-first quick inspection.
   - Use targeted commands only; avoid untargeted recursive scans.
   - Root-level tabular files:
     - `find "$DATASET_ROOT" -maxdepth 1 -type f \( -name '*.csv' -o -name '*.parquet' \)`
   - Allowlisted shallow subdir scan only when root-level results are insufficient:
     - allowlist: `train`, `val`, `valid`, `validation`, `test`, `metadata`, `labels`, `annotations`
     - run per-subdir scan with small depth (for example `-maxdepth 2`)
   - CSV quick checks:
     - columns: `head -n 1 <file.csv>`
     - row estimate: `wc -l <file.csv>`
     - sample rows: `head -n 5 <file.csv>`
4. Run script-based profiling for richer summary.
   - Prefer project `uv` environment:
     - `uv run inspect-dataset/scripts/inspect_dataset.py --dataset-root "<path>"`
   - For one-off deps in environments without local setup:
     - `uv run --with pyarrow inspect-dataset/scripts/inspect_dataset.py --dataset-root "<path>"`
5. Handle Parquet dependency gaps with non-Python fallbacks.
   - Try `duckdb` first:
     - schema: `duckdb -c "DESCRIBE SELECT * FROM read_parquet('<file.parquet>') LIMIT 0;"`
     - preview: `duckdb -c "SELECT * FROM read_parquet('<file.parquet>') LIMIT 5;"`
   - Fallback to `parquet-tools`:
     - schema: `parquet-tools schema <file.parquet>`
     - preview: `parquet-tools head <file.parquet>`
6. Apply findings to implementation.
   - Update parser/manipulation code with discovered column names, null behavior, and file layout.
   - If feasible, run targeted checks/tests against real files from the selected dataset root.

## Script

- `scripts/inspect_dataset.py`
  - Bounded file targeting for CSV/Parquet.
  - Deterministic schema/sample/null summary.
  - JSON output mode for automation.
  - Actionable Parquet fallback guidance when Python dependencies are unavailable.

## Output Contract

Return:
1. Selected dataset root path.
2. Files inspected and selection rationale.
3. Schema and sample summary for CSV/Parquet targets.
4. Risks and parser/manipulation implications.
5. Any fallback used (for example `duckdb` or `parquet-tools`).

Keep results concise and actionable for immediate training code updates.
