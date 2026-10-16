from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
import sys
import threading
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

SKILL_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = SKILL_ROOT.parent
RUNNER_PATH = SKILL_ROOT / "scripts" / "run_review.py"
SCHEMA_PATH = SKILL_ROOT / "references" / "review-result.schema.json"
CLAUDE_SKILL_PATH = (
    REPO_ROOT / ".claude" / "overlays" / "skills" / "review-fix-loop" / "SKILL.md"
)
DEFAULT_MAX_ITERATIONS = 5
FEATURE_FILE = "feature.txt"
OTHER_FILE = "other.txt"
BASE_CONTENT = "base\n"
FEATURE_CONTENT = "feature\n"
DIRTY_CONTENT = "dirty\n"
CLEAN_PAYLOAD = {"status": "clean", "findings": []}


def load_runner() -> ModuleType:
    spec = importlib.util.spec_from_file_location("review_fix_loop_runner", RUNNER_PATH)
    if spec is None or spec.loader is None:
        raise AssertionError(f"Unable to load runner from {RUNNER_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def runner(monkeypatch: pytest.MonkeyPatch) -> ModuleType:
    module = load_runner()
    monkeypatch.setattr(module, "cli_available", lambda reviewer: True)
    return module


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


def init_state(
    runner: ModuleType, repo: Path, tmp_path: Path, **overrides: Any
) -> dict[str, Any]:
    arguments: dict[str, Any] = {
        "repo": repo,
        "requested_scope": "auto",
        "explicit_base": None,
        "max_iterations": DEFAULT_MAX_ITERATIONS,
        "host": "codex",
        "state_root": tmp_path / "state",
    }
    arguments.update(overrides)
    return runner.initialize_state(**arguments)


def finding(
    *,
    title: str = "[P1] Preserve the invariant",
    body: str = "The changed path violates the invariant.",
    priority: str = "P1",
    confidence: float = 0.8,
    file: str = FEATURE_FILE,
    line_start: int = 1,
    line_end: int = 1,
) -> dict[str, Any]:
    return {
        "title": title,
        "body": body,
        "priority": priority,
        "confidence": confidence,
        "file": file,
        "line_start": line_start,
        "line_end": line_end,
    }


def review_payload(*findings: dict[str, Any]) -> dict[str, Any]:
    return {
        "status": "findings" if findings else "clean",
        "findings": list(findings),
    }


def envelope(**fields: object) -> str:
    return json.dumps(
        {"type": "result", "subtype": "success", "is_error": False, **fields}
    )


def completed_process(
    returncode: int, stdout: str = "", stderr: str = ""
) -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess(["reviewer"], returncode, stdout, stderr)


def frontmatter(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    assert text.startswith("---\n")
    return text[4 : text.index("\n---\n", 4)]


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


def test_review_prompt_targets_uncommitted_changes(runner: ModuleType) -> None:
    prompt = runner.build_review_prompt(
        target="uncommitted", base_ref=None, merge_base=None
    )

    assert "staged, unstaged, and untracked" in prompt
    assert "Do not review committed branch changes" in prompt
    assert "Do not modify files" in prompt


def test_review_prompt_uses_pinned_merge_base(runner: ModuleType) -> None:
    prompt = runner.build_review_prompt(
        target="base", base_ref="main", merge_base="a" * 40
    )

    assert prompt.startswith("Review all current repository changes")
    assert "main" in prompt
    assert "a" * 40 in prompt
    assert "staged, unstaged, and untracked" in prompt


def test_review_prompt_rejects_invalid_targets(runner: ModuleType) -> None:
    with pytest.raises(runner.ReviewLoopError, match="requires a pinned base"):
        runner.build_review_prompt(target="base", base_ref=None, merge_base=None)
    with pytest.raises(runner.ReviewLoopError, match="Unsupported review target"):
        runner.build_review_prompt(target="commit", base_ref=None, merge_base=None)


def test_codex_command_is_structured_read_only_and_uses_configured_model(
    runner: ModuleType, tmp_path: Path
) -> None:
    output_path = tmp_path / "result.json"

    command = runner.build_review_command(
        reviewer="codex",
        target="uncommitted",
        schema_path=SCHEMA_PATH,
        output_path=output_path,
        base_ref=None,
        merge_base=None,
    )

    assert command[:2] == ["codex", "exec"]
    assert command[2] != "review"
    assert "--model" not in command
    assert "--uncommitted" not in command
    assert "--base" not in command
    assert "--ephemeral" in command
    assert 'model_reasoning_effort="high"' in command
    assert 'sandbox_mode="read-only"' in command
    assert 'approval_policy="never"' in command
    assert command[command.index("--output-schema") + 1] == str(SCHEMA_PATH)
    assert command[command.index("--output-last-message") + 1] == str(output_path)
    assert "staged, unstaged, and untracked" in command[-1]


def test_codex_command_passes_model_override(
    runner: ModuleType, tmp_path: Path
) -> None:
    command = runner.build_review_command(
        reviewer="codex",
        target="uncommitted",
        schema_path=SCHEMA_PATH,
        output_path=tmp_path / "result.json",
        base_ref=None,
        merge_base=None,
        model="gpt-test",
    )

    assert command[command.index("--model") + 1] == "gpt-test"


def test_claude_command_is_headless_read_only_and_schema_bound(
    runner: ModuleType, tmp_path: Path
) -> None:
    command = runner.build_review_command(
        reviewer="claude",
        target="uncommitted",
        schema_path=SCHEMA_PATH,
        output_path=tmp_path / "result.json",
        base_ref=None,
        merge_base=None,
    )

    assert command[:2] == ["claude", "-p"]
    assert command[command.index("--model") + 1] == "opus"
    assert command[command.index("--effort") + 1] == "high"
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
    expected = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    # The Claude CLI rejects the draft 2020-12 `$schema` meta-schema reference.
    assert "$schema" not in schema
    assert schema == {key: value for key, value in expected.items() if key != "$schema"}
    assert command[-2] == "--"
    assert "staged, unstaged, and untracked" in command[-1]


def test_claude_command_passes_model_override(
    runner: ModuleType, tmp_path: Path
) -> None:
    command = runner.build_review_command(
        reviewer="claude",
        target="uncommitted",
        schema_path=SCHEMA_PATH,
        output_path=tmp_path / "result.json",
        base_ref=None,
        merge_base=None,
        model="sonnet",
    )

    assert command[command.index("--model") + 1] == "sonnet"


def test_build_review_command_rejects_unknown_reviewer(
    runner: ModuleType, tmp_path: Path
) -> None:
    with pytest.raises(runner.ReviewLoopError, match="Unsupported reviewer"):
        runner.build_review_command(
            reviewer="gemini",
            target="uncommitted",
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
            ("codex:base", review_payload(lower_confidence)),
            ("codex:uncommitted", review_payload(higher_confidence)),
        ]
    )

    assert merged["status"] == "findings"
    assert len(merged["findings"]) == 1
    assert merged["findings"][0] == {
        **higher_confidence,
        "title": "[P1] preserve the invariant",
        "sources": ["codex:base", "codex:uncommitted"],
        "reviewers": ["codex"],
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
        [
            ("codex:base", review_payload(urgent)),
            ("claude:base", review_payload(detailed)),
        ]
    )

    assert merged["findings"][0]["body"] == "Detailed body"
    assert merged["findings"][0]["priority"] == "P0"
    assert merged["findings"][0]["title"] == "[P0] Preserve the invariant"
    assert merged["findings"][0]["reviewers"] == ["codex", "claude"]


def test_merge_results_marks_overlapping_findings_from_both_families(
    runner: ModuleType,
) -> None:
    codex_finding = finding(title="[P1] Off-by-one in loop", line_start=3, line_end=6)
    claude_finding = finding(
        title="[P1] Loop skips the last element", line_start=5, line_end=9
    )
    separate = finding(title="[P2] Unrelated", priority="P2", file=OTHER_FILE)

    merged = runner.merge_results(
        [
            ("codex:base", review_payload(codex_finding, separate)),
            ("claude:base", review_payload(claude_finding)),
        ]
    )

    reviewers = {item["title"]: item["reviewers"] for item in merged["findings"]}
    assert reviewers == {
        "[P1] Off-by-one in loop": ["codex", "claude"],
        "[P1] Loop skips the last element": ["codex", "claude"],
        "[P2] Unrelated": ["codex"],
    }


def test_merge_results_keeps_adjacent_ranges_separate(runner: ModuleType) -> None:
    merged = runner.merge_results(
        [
            ("codex:base", review_payload(finding(line_start=1, line_end=2))),
            (
                "claude:base",
                review_payload(finding(title="[P1] Other", line_start=3, line_end=4)),
            ),
        ]
    )

    assert [item["reviewers"] for item in merged["findings"]] == [
        ["codex"],
        ["claude"],
    ]


def test_initialize_state_pins_auto_uncommitted_scope(
    runner: ModuleType, tmp_path: Path
) -> None:
    repo = create_repository(tmp_path)
    (repo / FEATURE_FILE).write_text(DIRTY_CONTENT, encoding="utf-8")

    state = init_state(runner, repo, tmp_path)

    assert state["selected_scope"] == "uncommitted"
    assert state["base_ref"] is None
    assert state["completed_iterations"] == 0
    assert Path(state["state_file"]).is_file()


def test_initialize_state_records_host_reviewers_and_models(
    runner: ModuleType, tmp_path: Path
) -> None:
    repo = create_repository(tmp_path)

    state = init_state(
        runner, repo, tmp_path, host="claude", models={"codex": "gpt-test"}
    )

    assert state["version"] == 2
    assert state["host"] == "claude"
    assert state["active_reviewers"] == ["claude", "codex"]
    assert state["models"] == {"codex": "gpt-test"}
    assert state["fallback"] == []


def test_initialize_state_accepts_host_only_reviewers(
    runner: ModuleType, tmp_path: Path
) -> None:
    repo = create_repository(tmp_path)

    state = init_state(runner, repo, tmp_path, reviewers=("codex",))

    assert state["active_reviewers"] == ["codex"]
    assert state["fallback"] == []


@pytest.mark.parametrize(
    ("overrides", "message"),
    [
        ({"host": "gemini"}, "host"),
        ({"reviewers": ("claude",)}, "must include the host"),
        ({"reviewers": ("codex", "gemini")}, "Unsupported reviewer"),
        ({"models": {"gemini": "x"}}, "Unsupported reviewer"),
        ({"models": {"codex": " "}}, "model"),
    ],
)
def test_initialize_state_rejects_invalid_reviewer_configuration(
    runner: ModuleType, tmp_path: Path, overrides: dict[str, Any], message: str
) -> None:
    repo = create_repository(tmp_path)

    with pytest.raises(runner.ReviewLoopError, match=message):
        init_state(runner, repo, tmp_path, **overrides)


def test_initialize_state_falls_back_when_other_family_cli_is_missing(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = create_repository(tmp_path)
    monkeypatch.setattr(runner, "cli_available", lambda reviewer: reviewer == "codex")

    state = init_state(runner, repo, tmp_path)

    assert state["active_reviewers"] == ["codex"]
    assert len(state["fallback"]) == 1
    assert state["fallback"][0]["reviewer"] == "claude"
    assert state["fallback"][0]["round"] == 0
    assert "not found" in state["fallback"][0]["reason"]


def test_initialize_state_fails_when_host_cli_is_missing(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = create_repository(tmp_path)
    monkeypatch.setattr(runner, "cli_available", lambda reviewer: reviewer == "codex")

    with pytest.raises(runner.ReviewLoopError, match="claude CLI"):
        init_state(runner, repo, tmp_path, host="claude")


def test_cli_available_checks_path(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    module = load_runner()
    executable = tmp_path / "codex"
    executable.write_text("#!/bin/sh\n", encoding="utf-8")
    executable.chmod(0o755)
    monkeypatch.setenv("PATH", str(tmp_path))

    assert module.cli_available("codex")
    assert not module.cli_available("claude")


def test_initialize_state_rejects_nonpositive_cap(
    runner: ModuleType, tmp_path: Path
) -> None:
    repo = create_repository(tmp_path)

    for invalid_cap in (0, True):
        with pytest.raises(runner.ReviewLoopError, match="positive integer"):
            init_state(runner, repo, tmp_path, max_iterations=invalid_cap)


def test_initialize_state_uses_private_temporary_directory(
    runner: ModuleType, tmp_path: Path
) -> None:
    repo = create_repository(tmp_path)
    (repo / FEATURE_FILE).write_text(DIRTY_CONTENT, encoding="utf-8")

    state = init_state(runner, repo, tmp_path, state_root=None)

    state_directory = Path(state["state_file"]).parent
    try:
        assert state_directory.name.startswith("review-fix-loop-")
        assert state_directory.stat().st_mode & 0o777 == 0o700
    finally:
        shutil.rmtree(state_directory)


def test_initialize_state_falls_back_to_session_for_clean_feature_branch(
    runner: ModuleType, tmp_path: Path
) -> None:
    repo = create_repository(tmp_path, feature_commit=True)

    state = init_state(runner, repo, tmp_path)

    assert state["selected_scope"] == "session"
    assert state["base_ref"] == "main"
    assert state["merge_base"] == run_git(repo, "rev-parse", "main")


def test_explicit_uncommitted_scope_does_not_fall_back(
    runner: ModuleType, tmp_path: Path
) -> None:
    repo = create_repository(tmp_path, feature_commit=True)

    state = init_state(runner, repo, tmp_path, requested_scope="uncommitted")

    assert state["selected_scope"] == "uncommitted"
    assert state["base_ref"] is None


def test_session_round_runs_every_target_for_every_reviewer(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = create_repository(tmp_path, feature_commit=True)
    (repo / FEATURE_FILE).write_text(DIRTY_CONTENT, encoding="utf-8")
    state = init_state(
        runner,
        repo,
        tmp_path,
        requested_scope="session",
        explicit_base="main",
        models={"claude": "sonnet"},
    )
    observed: list[tuple[str, str, str | None]] = []
    lock = threading.Lock()

    def fake_review(**kwargs: Any) -> dict[str, Any]:
        with lock:
            observed.append((kwargs["reviewer"], kwargs["target"], kwargs["model"]))
        return review_payload()

    monkeypatch.setattr(runner, "run_structured_review", fake_review)

    result = runner.execute_round(Path(state["state_file"]))

    assert sorted(observed) == [
        ("claude", "base", "sonnet"),
        ("claude", "uncommitted", "sonnet"),
        ("codex", "base", None),
        ("codex", "uncommitted", None),
    ]
    assert result["status"] == "clean"
    assert result["completed_iterations"] == 1
    assert result["review_targets"] == ["base", "uncommitted"]
    assert result["active_reviewers"] == ["codex", "claude"]
    assert result["fallback"] == []


def test_clean_session_round_runs_only_base_review(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = create_repository(tmp_path, feature_commit=True)
    state = init_state(
        runner, repo, tmp_path, requested_scope="session", explicit_base="main"
    )
    observed_targets: list[str] = []
    lock = threading.Lock()

    def fake_review(**kwargs: Any) -> dict[str, Any]:
        with lock:
            observed_targets.append(kwargs["target"])
        return review_payload()

    monkeypatch.setattr(runner, "run_structured_review", fake_review)

    result = runner.execute_round(Path(state["state_file"]))

    assert result["status"] == "clean"
    assert observed_targets == ["base", "base"]


def test_round_findings_record_reviewer_sources(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = create_repository(tmp_path)
    (repo / FEATURE_FILE).write_text(DIRTY_CONTENT, encoding="utf-8")
    state = init_state(runner, repo, tmp_path)

    def fake_review(**kwargs: Any) -> dict[str, Any]:
        return review_payload(finding(title=f"[P1] From {kwargs['reviewer']}"))

    monkeypatch.setattr(runner, "run_structured_review", fake_review)

    result = runner.execute_round(Path(state["state_file"]))

    sources = sorted(item["sources"][0] for item in result["findings"])
    assert sources == ["claude:uncommitted", "codex:uncommitted"]
    assert all(item["reviewers"] == ["codex", "claude"] for item in result["findings"])


def test_other_family_failure_falls_back_to_host_reviewer(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = create_repository(tmp_path)
    (repo / FEATURE_FILE).write_text(DIRTY_CONTENT, encoding="utf-8")
    state = init_state(runner, repo, tmp_path)
    calls: list[str] = []
    lock = threading.Lock()

    def fake_review(**kwargs: Any) -> dict[str, Any]:
        with lock:
            calls.append(kwargs["reviewer"])
        if kwargs["reviewer"] == "claude":
            raise runner.ReviewLoopError("claude uncommitted review failed: bad model")
        return review_payload(finding())

    monkeypatch.setattr(runner, "run_structured_review", fake_review)

    first = runner.execute_round(Path(state["state_file"]))
    second = runner.execute_round(Path(state["state_file"]))

    assert first["status"] == "findings"
    assert first["completed_iterations"] == 1
    assert first["active_reviewers"] == ["codex"]
    assert first["fallback"] == [
        {
            "reviewer": "claude",
            "round": 1,
            "reason": "claude uncommitted review failed: bad model",
        }
    ]
    assert second["completed_iterations"] == 2
    assert sorted(calls) == ["claude", "codex", "codex"]


def test_host_failure_stops_without_consuming_iteration(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = create_repository(tmp_path, feature_commit=True)
    (repo / FEATURE_FILE).write_text(DIRTY_CONTENT, encoding="utf-8")
    state = init_state(
        runner, repo, tmp_path, requested_scope="session", explicit_base="main"
    )

    def fake_review(**kwargs: Any) -> dict[str, Any]:
        if kwargs["reviewer"] == "codex" and kwargs["target"] == "uncommitted":
            raise runner.ReviewLoopError("codex uncommitted review failed")
        if kwargs["reviewer"] == "claude":
            raise runner.ReviewLoopError("claude base review failed")
        return review_payload()

    monkeypatch.setattr(runner, "run_structured_review", fake_review)

    with pytest.raises(runner.ReviewLoopError, match="codex uncommitted review failed"):
        runner.execute_round(Path(state["state_file"]))

    persisted = json.loads(Path(state["state_file"]).read_text(encoding="utf-8"))
    assert persisted["completed_iterations"] == 0
    assert persisted["active_reviewers"] == ["codex", "claude"]
    assert persisted["fallback"] == []


def test_iteration_cap_is_reported_without_extra_review(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = create_repository(tmp_path)
    (repo / FEATURE_FILE).write_text(DIRTY_CONTENT, encoding="utf-8")
    state = init_state(
        runner, repo, tmp_path, requested_scope="uncommitted", max_iterations=1
    )
    call_count = 0
    lock = threading.Lock()

    def fake_review(**kwargs: Any) -> dict[str, Any]:
        nonlocal call_count
        with lock:
            call_count += 1
        return review_payload(finding())

    monkeypatch.setattr(runner, "run_structured_review", fake_review)

    first_result = runner.execute_round(Path(state["state_file"]))
    second_result = runner.execute_round(Path(state["state_file"]))

    assert first_result["status"] == "limit_reached"
    assert second_result["status"] == "limit_reached"
    assert call_count == 2


def test_clean_uncommitted_scope_completes_without_reviewer(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = create_repository(tmp_path, feature_commit=True)
    state = init_state(runner, repo, tmp_path, requested_scope="uncommitted")

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
    state = init_state(runner, repo, tmp_path)
    run_git(repo, "restore", FEATURE_FILE)
    monkeypatch.setattr(
        runner,
        "run_structured_review",
        lambda **kwargs: pytest.fail(f"Unexpected review: {kwargs}"),
    )

    result = runner.execute_round(Path(state["state_file"]))

    assert result["selected_scope"] == "uncommitted"
    assert result["status"] == "clean"


def run_review(runner: ModuleType, tmp_path: Path, reviewer: str) -> dict[str, Any]:
    return runner.run_structured_review(
        repo=tmp_path,
        reviewer=reviewer,
        target="uncommitted",
        base_ref=None,
        round_number=1,
        artifact_dir=tmp_path / "artifacts",
    )


def test_codex_review_retries_one_transient_failure(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    attempts = 0

    def fake_process(command: list[str], *, cwd: Path, event_log: Path) -> Any:
        nonlocal attempts
        attempts += 1
        output_path = Path(command[command.index("--output-last-message") + 1])
        if attempts == 1:
            return completed_process(1, stderr="connection timed out")
        output_path.write_text(json.dumps(review_payload()), encoding="utf-8")
        event_log.write_text("{}\n", encoding="utf-8")
        return completed_process(0)

    monkeypatch.setattr(runner, "run_process", fake_process)

    result = run_review(runner, tmp_path, "codex")

    assert result == review_payload()
    assert attempts == 2
    assert (tmp_path / "artifacts" / "round-001-codex-uncommitted.json").is_file()


def test_codex_review_does_not_retry_configuration_failure(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    attempts = 0

    def fake_process(command: list[str], *, cwd: Path, event_log: Path) -> Any:
        nonlocal attempts
        del command, cwd, event_log
        attempts += 1
        return completed_process(1, stderr="unknown model gpt-test")

    monkeypatch.setattr(runner, "run_process", fake_process)

    with pytest.raises(
        runner.ReviewLoopError, match="codex uncommitted.*unknown model"
    ):
        run_review(runner, tmp_path, "codex")

    assert attempts == 1


@pytest.mark.parametrize(
    ("write_output", "expected_error"),
    [(False, "did not write"), (True, "malformed structured output")],
)
def test_codex_review_rejects_missing_or_malformed_output(
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
        return completed_process(0)

    monkeypatch.setattr(runner, "run_process", fake_process)

    with pytest.raises(runner.ReviewLoopError, match=expected_error):
        run_review(runner, tmp_path, "codex")


@pytest.mark.parametrize("reviewer", ["codex", "claude"])
def test_review_stops_after_one_transient_retry(
    runner: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    reviewer: str,
) -> None:
    attempts = 0

    def fake_process(command: list[str], *, cwd: Path, event_log: Path) -> Any:
        nonlocal attempts
        del command, cwd, event_log
        attempts += 1
        return completed_process(1, stderr="rate limit exceeded")

    monkeypatch.setattr(runner, "run_process", fake_process)

    with pytest.raises(runner.ReviewLoopError, match="after one retry"):
        run_review(runner, tmp_path, reviewer)
    assert attempts == 2


def test_claude_extract_prefers_structured_output(runner: ModuleType) -> None:
    payload, detail = runner.extract_claude_payload(
        envelope(structured_output=CLEAN_PAYLOAD, result="ignored"), "uncommitted"
    )
    assert (payload, detail) == (CLEAN_PAYLOAD, None)


def test_claude_extract_falls_back_to_result_text(runner: ModuleType) -> None:
    payload, _ = runner.extract_claude_payload(
        envelope(result=json.dumps(CLEAN_PAYLOAD)), "base"
    )
    assert payload == CLEAN_PAYLOAD


def test_claude_extract_reports_error_result(runner: ModuleType) -> None:
    payload, detail = runner.extract_claude_payload(
        envelope(is_error=True, result="API Error: overloaded"), "base"
    )
    assert payload is None and detail == "API Error: overloaded"


@pytest.mark.parametrize("stdout", ["not json", envelope(result="not json"), "[]"])
def test_claude_extract_rejects_malformed_output(
    runner: ModuleType, stdout: str
) -> None:
    with pytest.raises(runner.ReviewLoopError, match="malformed|non-object"):
        runner.extract_claude_payload(stdout, "base")


def test_claude_review_retries_one_overloaded_result(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    responses = [
        completed_process(0, envelope(is_error=True, result="API Error: Overloaded")),
        completed_process(0, envelope(structured_output=CLEAN_PAYLOAD)),
    ]
    monkeypatch.setattr(
        runner, "run_process", lambda *_args, **_kwargs: responses.pop(0)
    )

    result = run_review(runner, tmp_path, "claude")

    assert result["status"] == "clean"
    assert not responses
    artifact = tmp_path / "artifacts" / "round-001-claude-uncommitted.json"
    assert json.loads(artifact.read_text(encoding="utf-8")) == CLEAN_PAYLOAD


def test_claude_review_stops_on_configuration_failure(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    calls: list[int] = []

    def fake_process(*_args: object, **_kwargs: object) -> Any:
        calls.append(1)
        return completed_process(1, stderr="unknown model opus")

    monkeypatch.setattr(runner, "run_process", fake_process)

    with pytest.raises(
        runner.ReviewLoopError, match="claude uncommitted.*unknown model"
    ):
        run_review(runner, tmp_path, "claude")
    assert len(calls) == 1


def test_claude_review_reports_result_message_from_failed_envelope(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    stdout = envelope(
        is_error=True,
        result="Failed to authenticate: OAuth session expired",
        session_id="session-detail-that-should-not-be-reported",
    )
    monkeypatch.setattr(
        runner, "run_process", lambda *_a, **_k: completed_process(1, stdout)
    )

    with pytest.raises(runner.ReviewLoopError) as error:
        run_review(runner, tmp_path, "claude")

    assert str(error.value) == (
        "claude uncommitted review failed: "
        "Failed to authenticate: OAuth session expired"
    )


def test_claude_review_rejects_invalid_structured_payload(
    runner: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    bad = {"status": "clean", "findings": [{"title": "x"}]}
    monkeypatch.setattr(
        runner,
        "run_process",
        lambda *_a, **_k: completed_process(0, envelope(structured_output=bad)),
    )

    with pytest.raises(runner.ReviewLoopError):
        run_review(runner, tmp_path, "claude")


def test_run_process_preserves_stdout(runner: ModuleType, tmp_path: Path) -> None:
    event_log = tmp_path / "events.jsonl"

    completed = runner.run_process(
        [sys.executable, "-c", "print('{}')"], cwd=tmp_path, event_log=event_log
    )

    assert completed.returncode == 0
    assert event_log.read_text(encoding="utf-8") == "{}\n"


@pytest.mark.parametrize("version", [1, 3])
def test_execute_round_rejects_unsupported_state(
    runner: ModuleType, tmp_path: Path, version: int
) -> None:
    unsupported = tmp_path / "state.json"
    unsupported.write_text(json.dumps({"version": version}) + "\n", encoding="utf-8")

    with pytest.raises(runner.ReviewLoopError, match="Unsupported loop state"):
        runner.execute_round(unsupported)


def test_execute_round_rejects_missing_state(
    runner: ModuleType, tmp_path: Path
) -> None:
    with pytest.raises(runner.ReviewLoopError, match="Cannot read loop state"):
        runner.execute_round(tmp_path / "missing.json")


def test_main_prints_results_and_errors(
    runner: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    observed: dict[str, Any] = {}

    def fake_initialize(**kwargs: Any) -> dict[str, Any]:
        observed.update(kwargs)
        return {"status": "ready", "scope": kwargs["requested_scope"]}

    monkeypatch.setattr(runner, "initialize_state", fake_initialize)
    assert runner.main(["init", "--repo", str(tmp_path), "--host", "claude"]) == 0
    assert json.loads(capsys.readouterr().out)["status"] == "ready"
    assert observed["host"] == "claude"
    assert observed["reviewers"] == ("codex", "claude")
    assert observed["max_iterations"] == DEFAULT_MAX_ITERATIONS
    assert observed["models"] == {}

    assert (
        runner.main(
            [
                "init",
                "--repo",
                str(tmp_path),
                "--host",
                "codex",
                "--reviewers",
                "codex",
                "--codex-model",
                "gpt-test",
                "--claude-model",
                "sonnet",
            ]
        )
        == 0
    )
    capsys.readouterr()
    assert observed["reviewers"] == ("codex",)
    assert observed["models"] == {"codex": "gpt-test", "claude": "sonnet"}

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
    assert runner.main(["init", "--repo", str(tmp_path), "--host", "codex"]) == 1
    assert "expected failure" in capsys.readouterr().err


def test_main_requires_host(runner: ModuleType, tmp_path: Path) -> None:
    with pytest.raises(SystemExit):
        runner.main(["init", "--repo", str(tmp_path)])


def test_skill_variants_pass_their_own_host_and_allow_invocation() -> None:
    codex_text = (SKILL_ROOT / "SKILL.md").read_text(encoding="utf-8")
    claude_text = CLAUDE_SKILL_PATH.read_text(encoding="utf-8")
    interface = (SKILL_ROOT / "agents" / "openai.yaml").read_text(encoding="utf-8")

    assert "--host codex" in codex_text and "--host claude" not in codex_text
    assert "--host claude" in claude_text and "--host codex" not in claude_text
    for path in (SKILL_ROOT / "SKILL.md", CLAUDE_SKILL_PATH):
        assert "disable-model-invocation" not in frontmatter(path)
    assert "allow_implicit_invocation: true" in interface
    assert "code-review high" in claude_text
    assert "run_review_claude.py" not in claude_text
    assert not (CLAUDE_SKILL_PATH.parent / "scripts").exists()
