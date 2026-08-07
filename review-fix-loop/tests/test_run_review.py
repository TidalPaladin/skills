from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

SKILL_ROOT = Path(__file__).resolve().parents[1]
RUNNER_PATH = SKILL_ROOT / "scripts" / "run_review.py"
SCHEMA_PATH = SKILL_ROOT / "references" / "review-result.schema.json"
DEFAULT_MAX_ITERATIONS = 10
FEATURE_FILE = "feature.txt"
BASE_CONTENT = "base\n"
FEATURE_CONTENT = "feature\n"
DIRTY_CONTENT = "dirty\n"


def load_runner() -> ModuleType:
    spec = importlib.util.spec_from_file_location("review_fix_loop_runner", RUNNER_PATH)
    if spec is None or spec.loader is None:
        raise AssertionError(f"Unable to load runner from {RUNNER_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def runner() -> ModuleType:
    return load_runner()


def run_git(repo: Path, *args: str) -> str:
    completed = subprocess.run(
        ["git", *args],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    )
    return completed.stdout.strip()


def create_repository(tmp_path: Path, *, feature_commit: bool = False) -> Path:
    repo = tmp_path / "repo"
    repo.mkdir()
    run_git(repo, "init", "--initial-branch=main")
    run_git(repo, "config", "user.name", "Review Fix Loop Tests")
    run_git(repo, "config", "user.email", "review-fix-loop@example.invalid")
    (repo / FEATURE_FILE).write_text(BASE_CONTENT, encoding="utf-8")
    run_git(repo, "add", FEATURE_FILE)
    run_git(repo, "commit", "-m", "Add base fixture")

    if feature_commit:
        run_git(repo, "switch", "-c", "feature")
        (repo / FEATURE_FILE).write_text(FEATURE_CONTENT, encoding="utf-8")
        run_git(repo, "commit", "-am", "Update feature fixture")

    return repo


def finding(
    *,
    title: str = "[P1] Preserve the invariant",
    body: str = "The changed path violates the invariant.",
    priority: str = "P1",
    confidence: float = 0.8,
) -> dict[str, Any]:
    return {
        "title": title,
        "body": body,
        "priority": priority,
        "confidence": confidence,
        "file": FEATURE_FILE,
        "line_start": 1,
        "line_end": 1,
    }


def review_payload(*findings: dict[str, Any]) -> dict[str, Any]:
    return {
        "status": "findings" if findings else "clean",
        "findings": list(findings),
    }


@pytest.mark.parametrize(
    ("requested_scope", "dirty", "expected_scope"),
    [
        ("auto", True, "uncommitted"),
        ("auto", False, "session"),
        ("uncommitted", False, "uncommitted"),
        ("session", True, "session"),
    ],
)
def test_select_scope(
    runner: ModuleType,
    requested_scope: str,
    dirty: bool,
    expected_scope: str,
) -> None:
    assert runner.select_scope(requested_scope, dirty) == expected_scope


def test_select_scope_rejects_unknown_value(runner: ModuleType) -> None:
    with pytest.raises(runner.ReviewLoopError, match="scope"):
        runner.select_scope("branch", dirty=False)


def test_resolve_base_uses_documented_candidate_order(
    runner: ModuleType, tmp_path: Path
) -> None:
    repo = create_repository(tmp_path, feature_commit=True)

    base_ref, merge_base = runner.resolve_base(repo, explicit_base=None)

    assert base_ref == "main"
    assert merge_base == run_git(repo, "rev-parse", "main")


def test_resolve_base_honors_explicit_ref(runner: ModuleType, tmp_path: Path) -> None:
    repo = create_repository(tmp_path, feature_commit=True)
    base_sha = run_git(repo, "rev-parse", "main")

    base_ref, merge_base = runner.resolve_base(repo, explicit_base=base_sha)

    assert base_ref == base_sha
    assert merge_base == base_sha


def test_resolve_base_rejects_missing_ref(runner: ModuleType, tmp_path: Path) -> None:
    repo = create_repository(tmp_path, feature_commit=True)

    with pytest.raises(runner.ReviewLoopError, match="does not resolve"):
        runner.resolve_base(repo, explicit_base="missing-ref")


def test_resolve_base_requires_override_when_candidates_are_absent(
    runner: ModuleType, tmp_path: Path
) -> None:
    repo = create_repository(tmp_path)
    run_git(repo, "branch", "-m", "feature")

    with pytest.raises(runner.ReviewLoopError, match="provide base=<ref>"):
        runner.resolve_base(repo, explicit_base=None)


def test_resolve_base_rejects_unrelated_history(
    runner: ModuleType, tmp_path: Path
) -> None:
    repo = create_repository(tmp_path)
    run_git(repo, "switch", "--orphan", "unrelated")
    (repo / FEATURE_FILE).write_text("unrelated\n", encoding="utf-8")
    run_git(repo, "add", FEATURE_FILE)
    run_git(repo, "commit", "-m", "Create unrelated history")

    with pytest.raises(runner.ReviewLoopError, match="Cannot resolve merge base"):
        runner.resolve_base(repo, explicit_base="main")


def test_build_review_command_uses_structured_uncommitted_prompt(
    runner: ModuleType, tmp_path: Path
) -> None:
    output_path = tmp_path / "result.json"

    command = runner.build_review_command(
        target="uncommitted",
        schema_path=SCHEMA_PATH,
        output_path=output_path,
        base_ref=None,
        merge_base=None,
    )

    assert command[:2] == ["codex", "exec"]
    assert command[2] != "review"
    assert "staged, unstaged, and untracked" in command[-1]
    assert "--uncommitted" not in command
    assert "--base" not in command
    assert "gpt-5.6-luna" in command
    assert 'model_reasoning_effort="medium"' in command
    assert 'sandbox_mode="read-only"' in command
    assert 'approval_policy="never"' in command
    assert command[command.index("--output-schema") + 1] == str(SCHEMA_PATH)
    assert command[command.index("--output-last-message") + 1] == str(output_path)


def test_build_review_command_uses_pinned_merge_base_prompt(
    runner: ModuleType, tmp_path: Path
) -> None:
    output_path = tmp_path / "result.json"

    command = runner.build_review_command(
        target="base",
        schema_path=SCHEMA_PATH,
        output_path=output_path,
        base_ref="main",
        merge_base="a" * 40,
    )

    assert "main" in command[-1]
    assert "a" * 40 in command[-1]
    assert "--base" not in command
    assert "--uncommitted" not in command
    assert command[-1].startswith("Review all current repository changes")
    assert "staged, unstaged, and untracked" in command[-1]
    assert "Do not include staged" not in command[-1]


def test_build_review_command_rejects_invalid_targets(
    runner: ModuleType, tmp_path: Path
) -> None:
    with pytest.raises(runner.ReviewLoopError, match="requires a pinned base"):
        runner.build_review_command(
            target="base",
            schema_path=SCHEMA_PATH,
            output_path=tmp_path / "result.json",
            base_ref=None,
            merge_base=None,
        )
    with pytest.raises(runner.ReviewLoopError, match="Unsupported review target"):
        runner.build_review_command(
            target="commit",
            schema_path=SCHEMA_PATH,
            output_path=tmp_path / "result.json",
            base_ref=None,
            merge_base=None,
        )


@pytest.mark.parametrize(
    "payload",
    [
        {"status": "clean", "findings": [finding()]},
        {"status": "findings", "findings": []},
        {"status": "findings", "findings": [{**finding(), "priority": "P4"}]},
        {
            "status": "findings",
            "findings": [{**finding(), "line_start": 2, "line_end": 1}],
        },
    ],
)
def test_validate_review_payload_rejects_inconsistent_results(
    runner: ModuleType, payload: dict[str, Any]
) -> None:
    with pytest.raises(runner.ReviewLoopError):
        runner.validate_review_payload(payload)


@pytest.mark.parametrize(
    "payload",
    [
        [],
        {"status": "clean"},
        {"status": "unknown", "findings": []},
        {"status": "findings", "findings": ["not-an-object"]},
        {"status": "findings", "findings": [{**finding(), "title": ""}]},
        {"status": "findings", "findings": [{**finding(), "confidence": True}]},
        {"status": "findings", "findings": [{**finding(), "confidence": 2.0}]},
        {"status": "findings", "findings": [{**finding(), "line_start": True}]},
        {"status": "findings", "findings": [{**finding(), "line_start": 0}]},
    ],
)
def test_validate_review_payload_rejects_malformed_results(
    runner: ModuleType, payload: Any
) -> None:
    with pytest.raises(runner.ReviewLoopError):
        runner.validate_review_payload(payload)


def test_merge_results_deduplicates_and_tracks_sources(runner: ModuleType) -> None:
    lower_confidence = finding(body="First body", priority="P2", confidence=0.6)
    higher_confidence = finding(
        title="[p1] preserve the invariant",
        body="More specific body",
        priority="P1",
        confidence=0.95,
    )

    merged = runner.merge_results(
        [
            ("base", review_payload(lower_confidence)),
            ("uncommitted", review_payload(higher_confidence)),
        ]
    )

    assert merged["status"] == "findings"
    assert len(merged["findings"]) == 1
    assert merged["findings"][0] == {
        **higher_confidence,
        "title": "[P1] preserve the invariant",
        "sources": ["base", "uncommitted"],
    }


def test_merge_results_preserves_highest_priority_across_duplicates(
    runner: ModuleType,
) -> None:
    urgent = finding(title="[P0] Preserve the invariant", priority="P0", confidence=0.5)
    detailed = finding(
        title="[P2] Preserve the invariant",
        body="Detailed body",
        priority="P2",
        confidence=0.9,
    )
    detailed["file"] = f"./{FEATURE_FILE}"

    merged = runner.merge_results(
        [("base", review_payload(urgent)), ("uncommitted", review_payload(detailed))]
    )

    assert merged["findings"][0]["body"] == "Detailed body"
    assert merged["findings"][0]["priority"] == "P0"
    assert merged["findings"][0]["title"] == "[P0] Preserve the invariant"


def test_initialize_state_pins_auto_uncommitted_scope(
    runner: ModuleType, tmp_path: Path
) -> None:
    repo = create_repository(tmp_path)
    (repo / FEATURE_FILE).write_text(DIRTY_CONTENT, encoding="utf-8")

    state = runner.initialize_state(
        repo=repo,
        requested_scope="auto",
        explicit_base=None,
        max_iterations=DEFAULT_MAX_ITERATIONS,
        state_root=tmp_path / "state",
    )

    assert state["selected_scope"] == "uncommitted"
    assert state["base_ref"] is None
    assert state["completed_iterations"] == 0
    assert Path(state["state_file"]).is_file()


def test_initialize_state_rejects_nonpositive_cap(
    runner: ModuleType, tmp_path: Path
) -> None:
    repo = create_repository(tmp_path)

    for invalid_cap in (0, True):
        with pytest.raises(runner.ReviewLoopError, match="positive integer"):
            runner.initialize_state(
                repo=repo,
                requested_scope="auto",
                explicit_base=None,
                max_iterations=invalid_cap,
                state_root=tmp_path / "state",
            )


def test_initialize_state_uses_private_temporary_directory(
    runner: ModuleType, tmp_path: Path
) -> None:
    repo = create_repository(tmp_path)
    (repo / FEATURE_FILE).write_text(DIRTY_CONTENT, encoding="utf-8")

    state = runner.initialize_state(
        repo=repo,
        requested_scope="auto",
        explicit_base=None,
        max_iterations=DEFAULT_MAX_ITERATIONS,
    )

    state_directory = Path(state["state_file"]).parent
    try:
        assert state_directory.stat().st_mode & 0o777 == 0o700
    finally:
        shutil.rmtree(state_directory)


def test_initialize_state_falls_back_to_session_for_clean_feature_branch(
    runner: ModuleType, tmp_path: Path
) -> None:
    repo = create_repository(tmp_path, feature_commit=True)

    state = runner.initialize_state(
        repo=repo,
        requested_scope="auto",
        explicit_base=None,
        max_iterations=DEFAULT_MAX_ITERATIONS,
        state_root=tmp_path / "state",
    )

    assert state["selected_scope"] == "session"
    assert state["base_ref"] == "main"
    assert state["merge_base"] == run_git(repo, "rev-parse", "main")


def test_explicit_uncommitted_scope_does_not_fall_back(
    runner: ModuleType, tmp_path: Path
) -> None:
    repo = create_repository(tmp_path, feature_commit=True)

    state = runner.initialize_state(
        repo=repo,
        requested_scope="uncommitted",
        explicit_base=None,
        max_iterations=DEFAULT_MAX_ITERATIONS,
        state_root=tmp_path / "state",
    )

    assert state["selected_scope"] == "uncommitted"
    assert state["base_ref"] is None


def test_session_round_runs_base_and_uncommitted_reviews(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = create_repository(tmp_path, feature_commit=True)
    (repo / FEATURE_FILE).write_text(DIRTY_CONTENT, encoding="utf-8")
    state = runner.initialize_state(
        repo=repo,
        requested_scope="session",
        explicit_base="main",
        max_iterations=DEFAULT_MAX_ITERATIONS,
        state_root=tmp_path / "state",
    )
    observed_targets: list[str] = []

    def fake_review(**kwargs: Any) -> dict[str, Any]:
        observed_targets.append(kwargs["target"])
        return review_payload()

    monkeypatch.setattr(runner, "run_structured_review", fake_review)

    result = runner.execute_round(Path(state["state_file"]))

    assert observed_targets == ["base", "uncommitted"]
    assert result["status"] == "clean"
    assert result["completed_iterations"] == 1


def test_clean_session_round_runs_only_base_review(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = create_repository(tmp_path, feature_commit=True)
    state = runner.initialize_state(
        repo=repo,
        requested_scope="session",
        explicit_base="main",
        max_iterations=DEFAULT_MAX_ITERATIONS,
        state_root=tmp_path / "state",
    )
    observed_targets: list[str] = []

    def fake_review(**kwargs: Any) -> dict[str, Any]:
        observed_targets.append(kwargs["target"])
        return review_payload()

    monkeypatch.setattr(runner, "run_structured_review", fake_review)

    result = runner.execute_round(Path(state["state_file"]))

    assert result["status"] == "clean"
    assert observed_targets == ["base"]


def test_partial_session_failure_does_not_consume_iteration(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = create_repository(tmp_path, feature_commit=True)
    (repo / FEATURE_FILE).write_text(DIRTY_CONTENT, encoding="utf-8")
    state = runner.initialize_state(
        repo=repo,
        requested_scope="session",
        explicit_base="main",
        max_iterations=DEFAULT_MAX_ITERATIONS,
        state_root=tmp_path / "state",
    )

    def fake_review(**kwargs: Any) -> dict[str, Any]:
        if kwargs["target"] == "uncommitted":
            raise runner.ReviewLoopError("review failed")
        return review_payload()

    monkeypatch.setattr(runner, "run_structured_review", fake_review)

    with pytest.raises(runner.ReviewLoopError, match="review failed"):
        runner.execute_round(Path(state["state_file"]))

    persisted = json.loads(Path(state["state_file"]).read_text(encoding="utf-8"))
    assert persisted["completed_iterations"] == 0


def test_iteration_cap_is_reported_without_extra_review(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = create_repository(tmp_path)
    (repo / FEATURE_FILE).write_text(DIRTY_CONTENT, encoding="utf-8")
    state = runner.initialize_state(
        repo=repo,
        requested_scope="uncommitted",
        explicit_base=None,
        max_iterations=1,
        state_root=tmp_path / "state",
    )
    call_count = 0

    def fake_review(**kwargs: Any) -> dict[str, Any]:
        nonlocal call_count
        call_count += 1
        return review_payload(finding())

    monkeypatch.setattr(runner, "run_structured_review", fake_review)

    first_result = runner.execute_round(Path(state["state_file"]))
    second_result = runner.execute_round(Path(state["state_file"]))

    assert first_result["status"] == "limit_reached"
    assert second_result["status"] == "limit_reached"
    assert call_count == 1


def test_clean_uncommitted_scope_completes_without_reviewer(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = create_repository(tmp_path, feature_commit=True)
    state = runner.initialize_state(
        repo=repo,
        requested_scope="uncommitted",
        explicit_base=None,
        max_iterations=DEFAULT_MAX_ITERATIONS,
        state_root=tmp_path / "state",
    )

    def unexpected_review(**kwargs: Any) -> dict[str, Any]:
        raise AssertionError(f"Unexpected reviewer invocation: {kwargs}")

    monkeypatch.setattr(runner, "run_structured_review", unexpected_review)

    result = runner.execute_round(Path(state["state_file"]))

    assert result["status"] == "clean"
    assert result["completed_iterations"] == 0
    assert result["review_targets"] == []


def test_auto_scope_stays_uncommitted_after_worktree_becomes_clean(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = create_repository(tmp_path)
    (repo / FEATURE_FILE).write_text(DIRTY_CONTENT, encoding="utf-8")
    state = runner.initialize_state(
        repo=repo,
        requested_scope="auto",
        explicit_base=None,
        max_iterations=DEFAULT_MAX_ITERATIONS,
        state_root=tmp_path / "state",
    )
    run_git(repo, "restore", FEATURE_FILE)
    monkeypatch.setattr(
        runner,
        "run_structured_review",
        lambda **kwargs: pytest.fail(f"Unexpected review: {kwargs}"),
    )

    result = runner.execute_round(Path(state["state_file"]))

    assert result["selected_scope"] == "uncommitted"
    assert result["status"] == "clean"


def test_run_structured_review_retries_one_transient_failure(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    attempts = 0

    def fake_process(command: list[str], *, cwd: Path, event_log: Path) -> Any:
        nonlocal attempts
        attempts += 1
        output_path = Path(command[command.index("--output-last-message") + 1])
        if attempts == 1:
            return subprocess.CompletedProcess(
                command,
                returncode=1,
                stdout="",
                stderr="connection timed out",
            )
        output_path.write_text(json.dumps(review_payload()), encoding="utf-8")
        event_log.write_text("{}\n", encoding="utf-8")
        return subprocess.CompletedProcess(
            command,
            returncode=0,
            stdout="",
            stderr="",
        )

    monkeypatch.setattr(runner, "run_process", fake_process)

    result = runner.run_structured_review(
        repo=tmp_path,
        target="uncommitted",
        base_ref=None,
        round_number=1,
        artifact_dir=tmp_path,
    )

    assert result == review_payload()
    assert attempts == 2


def test_run_structured_review_does_not_retry_configuration_failure(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    attempts = 0

    def fake_process(command: list[str], *, cwd: Path, event_log: Path) -> Any:
        nonlocal attempts
        attempts += 1
        return subprocess.CompletedProcess(
            command,
            returncode=1,
            stdout="",
            stderr="unknown model gpt-5.6-luna",
        )

    monkeypatch.setattr(runner, "run_process", fake_process)

    with pytest.raises(runner.ReviewLoopError, match="unknown model"):
        runner.run_structured_review(
            repo=tmp_path,
            target="uncommitted",
            base_ref=None,
            round_number=1,
            artifact_dir=tmp_path,
        )

    assert attempts == 1


@pytest.mark.parametrize(
    ("write_output", "expected_error"),
    [(False, "did not write"), (True, "malformed structured output")],
)
def test_run_structured_review_rejects_missing_or_malformed_output(
    runner: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    write_output: bool,
    expected_error: str,
) -> None:
    def fake_process(command: list[str], *, cwd: Path, event_log: Path) -> Any:
        del cwd, event_log
        if write_output:
            output_path = Path(command[command.index("--output-last-message") + 1])
            output_path.write_text("not json", encoding="utf-8")
        return subprocess.CompletedProcess(command, returncode=0, stdout="", stderr="")

    monkeypatch.setattr(runner, "run_process", fake_process)

    with pytest.raises(runner.ReviewLoopError, match=expected_error):
        runner.run_structured_review(
            repo=tmp_path,
            target="uncommitted",
            base_ref=None,
            round_number=1,
            artifact_dir=tmp_path,
        )


def test_run_structured_review_stops_after_one_transient_retry(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    attempts = 0

    def fake_process(command: list[str], *, cwd: Path, event_log: Path) -> Any:
        nonlocal attempts
        del cwd, event_log
        attempts += 1
        return subprocess.CompletedProcess(
            command, returncode=1, stdout="", stderr="connection timed out"
        )

    monkeypatch.setattr(runner, "run_process", fake_process)

    with pytest.raises(runner.ReviewLoopError, match="after one retry"):
        runner.run_structured_review(
            repo=tmp_path,
            target="uncommitted",
            base_ref=None,
            round_number=1,
            artifact_dir=tmp_path,
        )
    assert attempts == 2


def test_run_process_preserves_stdout(runner: ModuleType, tmp_path: Path) -> None:
    event_log = tmp_path / "events.jsonl"

    completed = runner.run_process(
        [sys.executable, "-c", "print('{}')"], cwd=tmp_path, event_log=event_log
    )

    assert completed.returncode == 0
    assert event_log.read_text(encoding="utf-8") == "{}\n"


def test_execute_round_rejects_bad_state(runner: ModuleType, tmp_path: Path) -> None:
    missing = tmp_path / "missing.json"
    with pytest.raises(runner.ReviewLoopError, match="Cannot read loop state"):
        runner.execute_round(missing)

    unsupported = tmp_path / "state.json"
    unsupported.write_text('{"version": 2}\n', encoding="utf-8")
    with pytest.raises(runner.ReviewLoopError, match="Unsupported loop state"):
        runner.execute_round(unsupported)


def test_main_prints_results_and_errors(
    runner: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setattr(
        runner,
        "initialize_state",
        lambda **kwargs: {"status": "ready", "scope": kwargs["requested_scope"]},
    )
    assert runner.main(["init", "--repo", str(tmp_path)]) == 0
    assert json.loads(capsys.readouterr().out)["status"] == "ready"

    monkeypatch.setattr(
        runner,
        "execute_round",
        lambda state_file: {"status": "clean", "state": str(state_file)},
    )
    assert runner.main(["review", "--state-file", str(tmp_path / "state.json")]) == 0
    assert json.loads(capsys.readouterr().out)["status"] == "clean"

    def fail(**kwargs: Any) -> dict[str, Any]:
        del kwargs
        raise runner.ReviewLoopError("expected failure")

    monkeypatch.setattr(runner, "initialize_state", fail)
    assert runner.main(["init", "--repo", str(tmp_path)]) == 1
    assert "expected failure" in capsys.readouterr().err
