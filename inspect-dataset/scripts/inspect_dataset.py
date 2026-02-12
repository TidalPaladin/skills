#!/usr/bin/env python3
"""Inspect CSV/Parquet files in a dataset root with bounded traversal."""

from __future__ import annotations

import argparse
import csv
import json
import shlex
import shutil
import sys
from collections import deque
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

DEFAULT_MAX_FILES = 12
DEFAULT_SAMPLE_ROWS = 200
DEFAULT_SUBDIR_MAX_DEPTH = 2
TABULAR_SUFFIXES = (".csv", ".parquet")
ALLOWED_SUBDIRECTORIES = (
    "train",
    "val",
    "valid",
    "validation",
    "test",
    "metadata",
    "labels",
    "annotations",
)
EMPTY_CELL_VALUE = ""
TEXT_PREVIEW_COLUMN_LIMIT = 10
TEXT_NULL_PREVIEW_LIMIT = 8


@dataclass(frozen=True)
class InspectionWarning:
    code: str
    message: str


@dataclass(frozen=True)
class CsvSummary:
    kind: str
    path: str
    columns: list[str]
    sampled_rows: int
    null_counts: dict[str, int]


@dataclass(frozen=True)
class ParquetSummary:
    kind: str
    path: str
    status: str
    columns: list[dict[str, str]]
    sampled_rows: int | None
    null_counts: dict[str, int] | None
    fallback: dict[str, Any] | None
    error: str | None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Inspect CSV/Parquet structure with bounded filesystem traversal."
    )
    parser.add_argument("--dataset-root", required=True, help="Dataset root directory path.")
    parser.add_argument(
        "--max-files",
        type=int,
        default=DEFAULT_MAX_FILES,
        help=f"Maximum number of CSV/Parquet files to inspect (default: {DEFAULT_MAX_FILES}).",
    )
    parser.add_argument(
        "--sample-rows",
        type=int,
        default=DEFAULT_SAMPLE_ROWS,
        help=f"Rows to sample per file (default: {DEFAULT_SAMPLE_ROWS}).",
    )
    parser.add_argument(
        "--subdir-max-depth",
        type=int,
        default=DEFAULT_SUBDIR_MAX_DEPTH,
        help=(
            "Max depth for allowlisted subdirectory traversal "
            f"(default: {DEFAULT_SUBDIR_MAX_DEPTH})."
        ),
    )
    parser.add_argument(
        "--output",
        choices=("text", "json"),
        default="text",
        help="Output format.",
    )
    return parser.parse_args()


def is_tabular_file(path: Path) -> bool:
    return path.is_file() and path.suffix.lower() in TABULAR_SUFFIXES


def list_root_tabular_files(dataset_root: Path) -> list[Path]:
    files = []
    for child in sorted(dataset_root.iterdir(), key=lambda item: item.name):
        if is_tabular_file(child):
            files.append(child)
    return files


def list_allowlisted_directories(dataset_root: Path) -> list[Path]:
    allowed = []
    for name in ALLOWED_SUBDIRECTORIES:
        path = dataset_root / name
        if path.is_dir():
            allowed.append(path)
    return allowed


def bounded_scan_directory(root: Path, max_depth: int, limit: int) -> list[Path]:
    if limit <= 0:
        return []
    discovered: list[Path] = []
    queue: deque[tuple[Path, int]] = deque([(root, 0)])

    while queue and len(discovered) < limit:
        current_dir, depth = queue.popleft()
        try:
            entries = sorted(current_dir.iterdir(), key=lambda item: item.name)
        except OSError:
            continue

        for entry in entries:
            if len(discovered) >= limit:
                break
            if is_tabular_file(entry):
                discovered.append(entry)
            elif entry.is_dir() and depth < max_depth:
                queue.append((entry, depth + 1))

    return discovered


def discover_tabular_files(
    dataset_root: Path,
    max_files: int,
    subdir_max_depth: int,
) -> tuple[list[Path], list[InspectionWarning]]:
    warnings: list[InspectionWarning] = []
    discovered = list_root_tabular_files(dataset_root)

    if len(discovered) >= max_files:
        return discovered[:max_files], warnings

    remaining = max_files - len(discovered)
    allowlisted_dirs = list_allowlisted_directories(dataset_root)
    if not allowlisted_dirs:
        warnings.append(
            InspectionWarning(
                code="no_allowlisted_dirs",
                message=(
                    "No allowlisted subdirectories were found; "
                    "inspected only root-level tabular files."
                ),
            )
        )
        return discovered, warnings

    for subdir in allowlisted_dirs:
        if remaining <= 0:
            break
        newly_found = bounded_scan_directory(
            root=subdir,
            max_depth=subdir_max_depth,
            limit=remaining,
        )
        discovered.extend(newly_found)
        remaining = max_files - len(discovered)

    if remaining <= 0:
        warnings.append(
            InspectionWarning(
                code="max_files_reached",
                message=f"Stopped after reaching --max-files={max_files}.",
            )
        )
    elif not discovered:
        warnings.append(
            InspectionWarning(
                code="no_tabular_files_found",
                message="No CSV/Parquet files were found with the current bounded scan rules.",
            )
        )

    return discovered, warnings


def inspect_csv_file(path: Path, sample_rows: int) -> CsvSummary:
    with path.open("r", encoding="utf-8", errors="replace", newline="") as handle:
        reader = csv.DictReader(handle)
        columns = [field for field in (reader.fieldnames or []) if field is not None]
        null_counts = {column: 0 for column in columns}
        sampled_rows = 0

        for row in reader:
            if sampled_rows >= sample_rows:
                break
            sampled_rows += 1
            for column in columns:
                value = row.get(column)
                if value is None or value.strip() == EMPTY_CELL_VALUE:
                    null_counts[column] += 1

    return CsvSummary(
        kind="csv",
        path=str(path),
        columns=columns,
        sampled_rows=sampled_rows,
        null_counts=null_counts,
    )


def build_parquet_fallback(path: Path) -> dict[str, Any]:
    shell_quoted_path = shlex.quote(str(path))
    sql_quoted_path = str(path).replace("'", "''")
    options: list[dict[str, Any]] = []

    if shutil.which("duckdb"):
        options.append(
            {
                "tool": "duckdb",
                "commands": [
                    (
                        "duckdb -c \"DESCRIBE SELECT * FROM "
                        f"read_parquet('{sql_quoted_path}') LIMIT 0;\""
                    ),
                    (
                        "duckdb -c \"SELECT * FROM "
                        f"read_parquet('{sql_quoted_path}') LIMIT 5;\""
                    ),
                ],
            }
        )

    if shutil.which("parquet-tools"):
        options.append(
            {
                "tool": "parquet-tools",
                "commands": [
                    f"parquet-tools schema {shell_quoted_path}",
                    f"parquet-tools head {shell_quoted_path}",
                ],
            }
        )

    options.append(
        {
            "tool": "uv",
            "commands": [
                "uv run --with pyarrow "
                "inspect-dataset/scripts/inspect_dataset.py "
                f"--dataset-root {shlex.quote(str(path.parent))}",
            ],
        }
    )

    return {"options": options}


def inspect_parquet_file(path: Path, sample_rows: int) -> ParquetSummary:
    try:
        import pyarrow as pa
        import pyarrow.parquet as pq
    except ImportError:
        return ParquetSummary(
            kind="parquet",
            path=str(path),
            status="fallback-required",
            columns=[],
            sampled_rows=None,
            null_counts=None,
            fallback=build_parquet_fallback(path),
            error="pyarrow is not installed in the active Python environment.",
        )

    try:
        parquet_file = pq.ParquetFile(path)
    except Exception as error:  # noqa: BLE001
        return ParquetSummary(
            kind="parquet",
            path=str(path),
            status="read-error",
            columns=[],
            sampled_rows=None,
            null_counts=None,
            fallback=build_parquet_fallback(path),
            error=f"pyarrow failed to open file: {error}",
        )

    columns = [
        {"name": field.name, "type": str(field.type)}
        for field in parquet_file.schema_arrow
    ]

    sampled_rows = 0
    null_counts: dict[str, int] = {}

    try:
        first_batch = next(parquet_file.iter_batches(batch_size=sample_rows), None)
    except Exception as error:  # noqa: BLE001
        return ParquetSummary(
            kind="parquet",
            path=str(path),
            status="read-error",
            columns=columns,
            sampled_rows=None,
            null_counts=None,
            fallback=build_parquet_fallback(path),
            error=f"pyarrow failed while reading sample rows: {error}",
        )

    if first_batch is not None:
        table = pa.Table.from_batches([first_batch])
        sampled_rows = table.num_rows
        for column_name in table.column_names:
            null_counts[column_name] = int(table[column_name].null_count)

    return ParquetSummary(
        kind="parquet",
        path=str(path),
        status="ok",
        columns=columns,
        sampled_rows=sampled_rows,
        null_counts=null_counts,
        fallback=None,
        error=None,
    )


def inspect_file(path: Path, sample_rows: int) -> dict[str, Any]:
    if path.suffix.lower() == ".csv":
        return asdict(inspect_csv_file(path, sample_rows))
    return asdict(inspect_parquet_file(path, sample_rows))


def render_text_report(report: dict[str, Any]) -> str:
    lines: list[str] = []
    lines.append(f"Dataset root: {report['dataset_root']}")
    lines.append(
        "Traversal: root-only scan + allowlisted dirs "
        f"({', '.join(ALLOWED_SUBDIRECTORIES)}) "
        f"with subdir depth <= {report['subdir_max_depth']}"
    )
    lines.append(
        "Files inspected: "
        f"{len(report['inspections'])}/{report['max_files']}"
    )

    for warning in report["warnings"]:
        lines.append(f"Warning [{warning['code']}]: {warning['message']}")

    for item in report["inspections"]:
        lines.append("")
        lines.append(f"- {item['path']} ({item['kind']})")
        if item["kind"] == "csv":
            columns = item["columns"]
            preview = columns[:TEXT_PREVIEW_COLUMN_LIMIT]
            lines.append(
                f"  Columns ({len(columns)}): {', '.join(preview)}"
                + (" ..." if len(columns) > len(preview) else "")
            )
            lines.append(f"  Sampled rows: {item['sampled_rows']}")
            null_items = list(item["null_counts"].items())[:TEXT_NULL_PREVIEW_LIMIT]
            lines.append(
                "  Null/empty counts (sample): "
                + ", ".join(f"{name}={count}" for name, count in null_items)
            )
        else:
            lines.append(f"  Status: {item['status']}")
            if item["status"] == "ok":
                schema_preview = item["columns"][:TEXT_PREVIEW_COLUMN_LIMIT]
                schema_text = ", ".join(
                    f"{field['name']}:{field['type']}" for field in schema_preview
                )
                lines.append(f"  Schema ({len(item['columns'])}): {schema_text}")
                lines.append(f"  Sampled rows: {item['sampled_rows']}")
            else:
                lines.append(f"  Error: {item['error']}")
                lines.append("  Fallback options:")
                for option in item["fallback"]["options"]:
                    lines.append(f"    {option['tool']}:")
                    for command in option["commands"]:
                        lines.append(f"      {command}")

    return "\n".join(lines)


def validate_inputs(args: argparse.Namespace) -> tuple[Path, list[InspectionWarning]]:
    warnings: list[InspectionWarning] = []
    dataset_root = Path(args.dataset_root).expanduser().resolve()

    if not dataset_root.exists():
        raise ValueError(f"Dataset root does not exist: {dataset_root}")
    if not dataset_root.is_dir():
        raise ValueError(f"Dataset root is not a directory: {dataset_root}")
    if args.max_files <= 0:
        raise ValueError("--max-files must be greater than zero.")
    if args.sample_rows <= 0:
        raise ValueError("--sample-rows must be greater than zero.")
    if args.subdir_max_depth < 0:
        raise ValueError("--subdir-max-depth must be zero or greater.")

    if args.subdir_max_depth == 0:
        warnings.append(
            InspectionWarning(
                code="subdir_scan_disabled",
                message="Subdirectory scanning disabled; only root-level files are inspected.",
            )
        )

    return dataset_root, warnings


def main() -> int:
    args = parse_args()

    try:
        dataset_root, input_warnings = validate_inputs(args)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2

    discovered_files, discovery_warnings = discover_tabular_files(
        dataset_root=dataset_root,
        max_files=args.max_files,
        subdir_max_depth=args.subdir_max_depth,
    )

    inspections = [inspect_file(path, args.sample_rows) for path in discovered_files]
    report = {
        "dataset_root": str(dataset_root),
        "max_files": args.max_files,
        "sample_rows": args.sample_rows,
        "subdir_max_depth": args.subdir_max_depth,
        "inspections": inspections,
        "warnings": [asdict(warning) for warning in (input_warnings + discovery_warnings)],
    }

    if args.output == "json":
        print(json.dumps(report, indent=2))
    else:
        print(render_text_report(report))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
