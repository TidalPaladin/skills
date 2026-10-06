"""Check capability resolution and bounded app-server discovery."""

from __future__ import annotations

import copy
import json
import os
import sys
from pathlib import Path

import pytest

from scripts.resolve_codex_models import (
    discover_models,
    load_model_list,
    resolve_models,
)


def catalog() -> dict:
    return {
        "capabilities": {
            "efficient": {"family": "luna"},
            "balanced": {"family": "sol"},
            "frontier": {"family": "astra"},
        },
        "classes": {
            "reviewer": {"capability": "efficient", "model_reasoning_effort": "medium"},
            "editor": {"capability": "efficient", "model_reasoning_effort": "xhigh"},
            "worker": {"capability": "balanced", "model_reasoning_effort": "xhigh"},
            "consultant": {
                "capability": "frontier",
                "model_reasoning_effort": "medium",
            },
        },
    }


def model(
    name: str, *, hidden: bool = False, efforts: tuple[str, ...] = ("medium", "xhigh")
) -> dict:
    return {
        "id": name,
        "model": name,
        "hidden": hidden,
        "supportedReasoningEfforts": [
            {"reasoningEffort": effort} for effort in efforts
        ],
    }


def model_list(*extra: dict) -> dict:
    return {
        "data": [model("gpt-6-luna"), model("gpt-6-sol"), model("gpt-6-astra"), *extra],
        "nextCursor": None,
    }


def test_numeric_versions_and_major_upgrades() -> None:
    result = resolve_models(
        catalog(),
        model_list(
            model("gpt-6.9-sol"),
            model("gpt-6.10-sol"),
            model("gpt-99-sol-preview"),
            model("gpt-99-sol-20261006"),
            model("gpt-99-sol", hidden=True),
            model("gpt-99-other"),
        ),
    )
    assert result == {
        "efficient": "gpt-6-luna",
        "balanced": "gpt-6.10-sol",
        "frontier": "gpt-6-astra",
    }
    assert (
        resolve_models(catalog(), model_list(model("gpt-7-sol")))["balanced"]
        == "gpt-7-sol"
    )


def test_latest_model_must_support_all_assigned_efforts() -> None:
    with pytest.raises(ValueError, match="xhigh"):
        resolve_models(catalog(), model_list(model("gpt-7-luna", efforts=("medium",))))


def test_pin_selects_older_model_for_one_invocation() -> None:
    evidence = model_list(model("gpt-6.1-sol"))
    assert (
        resolve_models(catalog(), evidence, ["balanced=gpt-6-sol"])["balanced"]
        == "gpt-6-sol"
    )
    assert resolve_models(catalog(), evidence)["balanced"] == "gpt-6.1-sol"


@pytest.mark.parametrize(
    "pins",
    [
        ["balanced=gpt-6-sol", "balanced=gpt-6.1-sol"],
        ["missing=gpt-6-sol"],
        ["balanced=gpt-6-luna"],
        ["balanced=gpt-7-sol"],
        ["balanced"],
        ["balanced=gpt-99-sol"],
    ],
)
def test_invalid_pins_are_rejected(pins: list[str]) -> None:
    with pytest.raises(ValueError):
        resolve_models(catalog(), model_list(model("gpt-99-sol", hidden=True)), pins)


def test_missing_family_is_rejected() -> None:
    evidence = model_list()
    evidence["data"] = evidence["data"][:2]
    with pytest.raises(ValueError, match="frontier"):
        resolve_models(catalog(), evidence)


@pytest.mark.parametrize(
    "change",
    [
        {"nextCursor": "more"},
        {"data": {}},
        {"data": [{"model": 42}]},
    ],
)
def test_saved_input_requires_complete_well_formed_evidence(
    tmp_path: Path, change: dict
) -> None:
    evidence = copy.deepcopy(model_list())
    evidence.update(change)
    path = tmp_path / "models.json"
    path.write_text(json.dumps(evidence))
    with pytest.raises(ValueError):
        load_model_list(path)


def fake_server(tmp_path: Path, mode: str) -> tuple[str, ...]:
    script = tmp_path / "server.py"
    script.write_text("""import json, os, signal, sys, time
from pathlib import Path
Path(sys.argv[2]).write_text(str(os.getpid()))
mode = sys.argv[1]
if mode == "ignore-term":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
for line in sys.stdin:
    request = json.loads(line)
    if request.get("method") not in ("initialize", "initialized", "model/list"):
        sys.exit(9)
    if request.get("method") == "initialized":
        continue
    if mode == "exit":
        sys.exit(1)
    if mode in ("timeout", "ignore-term"):
        time.sleep(10)
    if mode == "error":
        print(json.dumps({"id": request["id"], "error": {"code": -1, "message": "private-secret"}}), flush=True)
        continue
    if mode == "malformed":
        print("{broken", flush=True)
        continue
    if mode == "oversized":
        print("x" * 2048, flush=True)
        continue
    if request["method"] == "initialize":
        result = {}
    else:
        cursor = request["params"].get("cursor")
        if mode == "pages":
            name = "gpt-6-sol" if cursor is None else "gpt-6.1-sol"
            result = {"data": [{"model": name, "hidden": False, "supportedReasoningEfforts": [{"reasoningEffort": "xhigh"}]}], "nextCursor": "next" if cursor is None else None}
        else:
            result = {"data": [], "nextCursor": "next"}
    print(json.dumps({"id": request["id"], "result": result}), flush=True)
""")
    return (sys.executable, "-u", str(script), mode, str(tmp_path / "pid"))


def test_discovery_paginates_and_returns_complete_input(tmp_path: Path) -> None:
    result = discover_models(command=fake_server(tmp_path, "pages"))
    assert result["nextCursor"] is None
    assert [entry["model"] for entry in result["data"]] == ["gpt-6-sol", "gpt-6.1-sol"]
    with pytest.raises(ProcessLookupError):
        os.kill(int((tmp_path / "pid").read_text()), 0)


@pytest.mark.parametrize(
    "mode,options",
    [
        ("exit", {}),
        ("timeout", {"timeout": 0.1}),
        ("malformed", {}),
        ("oversized", {"message_limit": 1024}),
        ("repeat", {}),
        ("repeat", {"max_pages": 1}),
        ("ignore-term", {"timeout": 0.2}),
        ("error", {}),
    ],
)
def test_discovery_failures_are_bounded(
    tmp_path: Path, mode: str, options: dict
) -> None:
    with pytest.raises(ValueError) as raised:
        discover_models(command=fake_server(tmp_path, mode), **options)
    assert "private-secret" not in str(raised.value)
    with pytest.raises(ProcessLookupError):
        os.kill(int((tmp_path / "pid").read_text()), 0)


def test_saved_input_size_and_invalid_json(tmp_path: Path) -> None:
    path = tmp_path / "models.json"
    path.write_text("{broken-private-secret")
    with pytest.raises(ValueError, match="invalid JSON") as raised:
        load_model_list(path)
    assert "private-secret" not in str(raised.value)
    with path.open("wb") as output:
        output.truncate(16 * 1024 * 1024 + 1)
    with pytest.raises(ValueError, match="exceeds"):
        load_model_list(path)


def test_duplicate_model_entries_are_rejected() -> None:
    with pytest.raises(ValueError, match="duplicate"):
        resolve_models(catalog(), model_list(model("gpt-6-sol")))
