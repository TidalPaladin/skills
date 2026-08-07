"""One-way version-2 cutover manifest support."""

from __future__ import annotations

import hashlib
import json
import os
import re
import tempfile
from collections.abc import Callable, Mapping, Sequence
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from .models import SCHEMA_VERSION, normalize_datetime, validate_text

CONTRACT_NAME = "notify-wake-v2"


class CutoverError(RuntimeError):
    """A safe version-2 cutover cannot be recorded."""


def create_cutover_manifest(
    manifest_path: Path,
    *,
    source_commit: str,
    legacy_groups: Mapping[str, Sequence[Path]],
    dispositions: Mapping[str, str],
    superseded_ids: Sequence[str] = (),
    live_identities: Sequence[str] = (),
    now: Callable[[], datetime] = lambda: datetime.now(UTC),
) -> dict[str, Any]:
    """Write one immutable audit manifest after a clean live-state check."""

    selected_path = manifest_path.expanduser()
    if not selected_path.is_absolute():
        raise CutoverError("cutover manifest path must be absolute")
    resolved_parent = selected_path.parent.resolve(strict=False)
    if resolved_parent.name != "v2" or resolved_parent.parent.name not in {
        "notify-wake",
        ".notify-wake",
    }:
        raise CutoverError("cutover manifest must be inside an exact notify-wake v2 root")
    if selected_path.name != "cutover-manifest.json":
        raise CutoverError("cutover manifest filename must be cutover-manifest.json")
    if selected_path.is_symlink():
        raise CutoverError("cutover manifest must not be a symlink")
    if not re.fullmatch(r"[0-9a-f]{40}", source_commit):
        raise CutoverError("source_commit must be an exact lowercase Git SHA")
    if live_identities:
        selected = ", ".join(
            sorted(validate_text(value, "live identity") for value in live_identities)
        )
        raise CutoverError(f"cutover refused while legacy work is live: {selected}")
    if set(legacy_groups) != set(dispositions):
        raise CutoverError("every legacy group requires one disposition")

    group_payloads: dict[str, object] = {}
    total_file_count = 0
    for group_name in sorted(legacy_groups):
        validated_name = validate_text(group_name, "legacy group")
        disposition = validate_text(dispositions[group_name], "disposition")
        entries: list[dict[str, str]] = []
        aggregate = hashlib.sha256()
        resolved_paths = sorted(
            {Path(os.path.abspath(path.expanduser())) for path in legacy_groups[group_name]},
            key=str,
        )
        for path in resolved_paths:
            if path.is_symlink() or not path.is_file():
                raise CutoverError(f"legacy evidence is not a regular file: {path}")
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            aggregate.update(f"{path}\0{digest}\n".encode())
            entries.append(
                {
                    "path": str(path),
                    "sha256": digest,
                    "disposition": disposition,
                }
            )
        total_file_count += len(entries)
        group_payloads[validated_name] = {
            "file_count": len(entries),
            "aggregate_sha256": aggregate.hexdigest(),
            "disposition": disposition,
            "files": entries,
        }

    selected_now = normalize_datetime(now(), "now")
    payload: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "contract": CONTRACT_NAME,
        "source_commit": source_commit,
        "created_at": selected_now.isoformat(),
        "live_legacy_identities": [],
        "total_file_count": total_file_count,
        "superseded_ids": sorted(
            validate_text(value, "superseded identity") for value in superseded_ids
        ),
        "groups": group_payloads,
    }
    serialized = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    if selected_path.exists():
        try:
            current = selected_path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            raise CutoverError(f"could not read existing cutover manifest: {error}") from error
        if current != serialized:
            raise CutoverError("cutover manifest already exists with different content")
        return payload

    resolved_parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(resolved_parent, 0o700)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".cutover-manifest.",
        dir=resolved_parent,
    )
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write(serialized)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_path, selected_path)
        directory_descriptor = os.open(resolved_parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    except BaseException:
        temporary_path.unlink(missing_ok=True)
        raise
    return payload
