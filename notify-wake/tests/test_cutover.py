from __future__ import annotations

import hashlib
from datetime import UTC, datetime
from pathlib import Path

import pytest
from notify_wake.cutover import CutoverError, create_cutover_manifest

NOW = datetime(2026, 7, 29, 19, 0, tzinfo=UTC)
SOURCE_COMMIT = "a" * 40


def test_cutover_refuses_live_legacy_work(tmp_path: Path) -> None:
    manifest = tmp_path / ".notify-wake" / "v2" / "cutover-manifest.json"

    with pytest.raises(CutoverError, match="legacy work is live"):
        create_cutover_manifest(
            manifest,
            source_commit=SOURCE_COMMIT,
            legacy_groups={},
            dispositions={},
            live_identities=("controller:study-a",),
            now=lambda: NOW,
        )

    assert not manifest.exists()


def test_cutover_manifest_hashes_and_preserves_legacy_evidence(tmp_path: Path) -> None:
    first = tmp_path / "legacy" / "first.json"
    second = tmp_path / "legacy" / "second.json"
    first.parent.mkdir()
    first.write_text('{"state":"accepted"}\n', encoding="utf-8")
    second.write_text('{"state":"pending"}\n', encoding="utf-8")
    manifest = tmp_path / ".notify-wake" / "v2" / "cutover-manifest.json"

    payload = create_cutover_manifest(
        manifest,
        source_commit=SOURCE_COMMIT,
        legacy_groups={
            "accepted": (first,),
            "pending_terminal": (second,),
        },
        dispositions={
            "accepted": "inert_historical_evidence",
            "pending_terminal": "intentionally_superseded",
        },
        superseded_ids=("event-2",),
        now=lambda: NOW,
    )

    assert payload["schema_version"] == 2
    assert payload["total_file_count"] == 2
    assert payload["superseded_ids"] == ["event-2"]
    groups = payload["groups"]
    assert (
        groups["accepted"]["files"][0]["sha256"] == hashlib.sha256(first.read_bytes()).hexdigest()
    )
    assert first.exists() and second.exists()
    assert manifest.stat().st_mode & 0o777 == 0o600

    assert (
        create_cutover_manifest(
            manifest,
            source_commit=SOURCE_COMMIT,
            legacy_groups={
                "accepted": (first,),
                "pending_terminal": (second,),
            },
            dispositions={
                "accepted": "inert_historical_evidence",
                "pending_terminal": "intentionally_superseded",
            },
            superseded_ids=("event-2",),
            now=lambda: NOW,
        )
        == payload
    )


def test_cutover_rejects_wrong_namespace_or_existing_different_manifest(
    tmp_path: Path,
) -> None:
    evidence = tmp_path / "legacy.json"
    evidence.write_text("{}\n", encoding="utf-8")
    with pytest.raises(CutoverError, match="exact notify-wake v2 root"):
        create_cutover_manifest(
            tmp_path / "v2" / "cutover-manifest.json",
            source_commit=SOURCE_COMMIT,
            legacy_groups={"legacy": (evidence,)},
            dispositions={"legacy": "inert"},
            now=lambda: NOW,
        )

    manifest = tmp_path / "notify-wake" / "v2" / "cutover-manifest.json"
    create_cutover_manifest(
        manifest,
        source_commit=SOURCE_COMMIT,
        legacy_groups={"legacy": (evidence,)},
        dispositions={"legacy": "inert"},
        now=lambda: NOW,
    )
    with pytest.raises(CutoverError, match="different content"):
        create_cutover_manifest(
            manifest,
            source_commit="b" * 40,
            legacy_groups={"legacy": (evidence,)},
            dispositions={"legacy": "inert"},
            now=lambda: NOW,
        )
