from __future__ import annotations

import importlib
import json
import shutil
import subprocess
import sys
from collections.abc import Iterator
from pathlib import Path
from types import ModuleType

import pytest

OVERLAY_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = OVERLAY_ROOT.parents[3]
BASE_SKILL = REPO_ROOT / "review-fix-loop"
CLEAN_PAYLOAD = {"status": "clean", "findings": []}


@pytest.fixture
def runner(tmp_path: Path) -> Iterator[ModuleType]:
    """Compose the exported skill as the Claude sync does, then load its runner."""
    skill = tmp_path / "review-fix-loop"
    shutil.copytree(BASE_SKILL, skill, ignore=shutil.ignore_patterns("__pycache__"))
    shutil.copytree(
        OVERLAY_ROOT,
        skill,
        dirs_exist_ok=True,
        ignore=shutil.ignore_patterns("__pycache__"),
    )
    scripts = str(skill / "scripts")
    sys.path.insert(0, scripts)
    for name in ("run_review", "run_review_claude"):
        sys.modules.pop(name, None)
    try:
        yield importlib.import_module("run_review_claude")
    finally:
        sys.path.remove(scripts)
        for name in ("run_review", "run_review_claude"):
            sys.modules.pop(name, None)


def envelope(**fields: object) -> str:
    return json.dumps(
        {"type": "result", "subtype": "success", "is_error": False, **fields}
    )


def completed(returncode: int, stdout: str = "", stderr: str = ""):
    return subprocess.CompletedProcess(["claude"], returncode, stdout, stderr)


def test_overlay_replaces_skill_and_keeps_base_runner(runner: ModuleType) -> None:
    skill = Path(runner.__file__).resolve().parents[1]
    text = (skill / "SKILL.md").read_text(encoding="utf-8")
    assert "run_review_claude.py" in text
    assert "disable-model-invocation: true" in text
    assert "create_goal" not in text
    assert (skill / "scripts" / "run_review.py").is_file()


def test_command_is_headless_read_only_and_schema_bound(runner: ModuleType) -> None:
    base = sys.modules["run_review"]
    command = runner.build_review_command(
        target="uncommitted",
        schema_path=base.REVIEW_SCHEMA_PATH,
        base_ref=None,
        merge_base=None,
    )
    assert command[:2] == ["claude", "-p"]
    assert command[command.index("--model") + 1] == "sonnet"
    assert command[command.index("--permission-mode") + 1] == "dontAsk"
    assert "--no-session-persistence" in command
    tools = command[command.index("--tools") + 1].split(",")
    assert "Edit" not in tools and "Write" not in tools
    allowed = command[
        command.index("--allowedTools") + 1 : command.index("--disallowedTools")
    ]
    assert all(
        tool in {"Read", "Grep", "Glob"} or tool.startswith("Bash(git ")
        for tool in allowed
    )
    schema = json.loads(command[command.index("--json-schema") + 1])
    assert schema == json.loads(base.REVIEW_SCHEMA_PATH.read_text(encoding="utf-8"))
    assert command[-2] == "--"
    assert "staged, unstaged, and untracked" in command[-1]


def test_base_prompt_requires_pinned_merge_base(runner: ModuleType) -> None:
    base = sys.modules["run_review"]
    with pytest.raises(base.ReviewLoopError):
        runner.build_review_command(
            target="base",
            schema_path=base.REVIEW_SCHEMA_PATH,
            base_ref=None,
            merge_base=None,
        )


def test_extract_prefers_structured_output(runner: ModuleType) -> None:
    payload, detail = runner.extract_payload(
        envelope(structured_output=CLEAN_PAYLOAD, result="ignored"), "uncommitted"
    )
    assert (payload, detail) == (CLEAN_PAYLOAD, None)


def test_extract_falls_back_to_result_text(runner: ModuleType) -> None:
    payload, _ = runner.extract_payload(
        envelope(result=json.dumps(CLEAN_PAYLOAD)), "base"
    )
    assert payload == CLEAN_PAYLOAD


def test_extract_reports_error_result(runner: ModuleType) -> None:
    payload, detail = runner.extract_payload(
        envelope(is_error=True, result="API Error: overloaded"), "base"
    )
    assert payload is None and detail == "API Error: overloaded"


@pytest.mark.parametrize("stdout", ["not json", envelope(result="not json"), "[]"])
def test_extract_rejects_malformed_output(runner: ModuleType, stdout: str) -> None:
    base = sys.modules["run_review"]
    with pytest.raises(base.ReviewLoopError, match="malformed|non-object"):
        runner.extract_payload(stdout, "base")


def test_review_retries_one_transient_failure(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    base = sys.modules["run_review"]
    responses = [
        completed(0, envelope(is_error=True, result="API Error: Overloaded")),
        completed(0, envelope(structured_output=CLEAN_PAYLOAD)),
    ]
    monkeypatch.setattr(base, "run_process", lambda *_args, **_kwargs: responses.pop(0))
    result = runner.run_structured_review(
        repo=tmp_path,
        target="uncommitted",
        base_ref=None,
        round_number=1,
        artifact_dir=tmp_path / "a",
    )
    assert result["status"] == "clean"
    assert not responses
    assert (
        json.loads((tmp_path / "a" / "round-001-uncommitted.json").read_text())
        == CLEAN_PAYLOAD
    )


def test_review_stops_on_configuration_failure(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    base = sys.modules["run_review"]
    calls: list[int] = []

    def fake_process(*_args: object, **_kwargs: object):
        calls.append(1)
        return completed(1, stderr="unknown model sonnet")

    monkeypatch.setattr(base, "run_process", fake_process)
    with pytest.raises(base.ReviewLoopError, match="unknown model"):
        runner.run_structured_review(
            repo=tmp_path,
            target="uncommitted",
            base_ref=None,
            round_number=1,
            artifact_dir=tmp_path,
        )
    assert len(calls) == 1


def test_review_stops_after_second_transient_failure(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    base = sys.modules["run_review"]
    monkeypatch.setattr(
        base,
        "run_process",
        lambda *_a, **_k: completed(1, stderr="rate limit exceeded"),
    )
    with pytest.raises(base.ReviewLoopError, match="after one retry"):
        runner.run_structured_review(
            repo=tmp_path,
            target="uncommitted",
            base_ref=None,
            round_number=1,
            artifact_dir=tmp_path,
        )


def test_invalid_structured_payload_is_rejected(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    base = sys.modules["run_review"]
    bad = {"status": "clean", "findings": [{"title": "x"}]}
    monkeypatch.setattr(
        base,
        "run_process",
        lambda *_a, **_k: completed(0, envelope(structured_output=bad)),
    )
    with pytest.raises(base.ReviewLoopError):
        runner.run_structured_review(
            repo=tmp_path,
            target="uncommitted",
            base_ref=None,
            round_number=1,
            artifact_dir=tmp_path,
        )


def test_rounds_use_the_claude_reviewer(runner: ModuleType) -> None:
    base = sys.modules["run_review"]
    assert base.run_structured_review is runner.run_structured_review
