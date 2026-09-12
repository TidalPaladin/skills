---
name: inspect-dataset
description: Inspect dataset paths and CSV or Parquet metadata to guide data-pipeline changes.
---

# Inspect Dataset

Accept `$inspect-dataset <dataset_dir>`, a configuration file, or no argument.
For configuration discovery, prefer active settings in `Makefile.config`, then
related training configuration. Honor an explicit dataset directory.

Resolve the dataset root and check mountpoints or typos if it is absent.
State the selected root before deeper inspection.
Use bounded scans of relevant metadata directories, not recursive data dumps.

Prefer schema, counts, null behavior, and aggregate summaries.
Inspect sample values only when needed and authorized for the task.
Keep protected data out of conversation output and test fixtures.

Use the bundled profiler for repeatable CSV or Parquet inspection:

```bash
uv run inspect-dataset/scripts/inspect_dataset.py --dataset-root "<path>"
```

Resolve the script path relative to this skill. Use the project's environment
when available. Read `--help` for bounded selection and JSON options.
If Parquet support is missing, use an available DuckDB or parquet-tools command,
or an authorized temporary environment with pyarrow.

Apply findings to the requested parser or training changes. Validate against
the selected data when feasible without modifying source datasets.
Report the root, inspected files, schema implications, and evidence limitations.
