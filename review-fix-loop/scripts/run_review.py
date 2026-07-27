#!/usr/bin/env python3
"""Run one structured Codex review round for the review-fix-loop skill."""

from __future__ import annotations

import argparse
import json
import os
import posixpath
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Final, Literal, TypeAlias, cast

SKILL_ROOT: Final = Path(__file__).resolve().parents[1]
REVIEW_SCHEMA_PATH: Final = SKILL_ROOT / "references" / "review-result.schema.json"
DEFAULT_MAX_ITERATIONS: Final = 10
BASE_CANDIDATES: Final = ("origin/main", "origin/master", "main", "master")
MODEL: Final = "gpt-5.6-luna"
REASONING_EFFORT: Final = "medium"
TRANSIENT_ERROR_MARKERS: Final = (
    "connection timed out",
    "timed out",
    "timeout",
    "temporarily unavailable",
    "failed to connect",
    "connection reset",
    "rate limit",
    "too many requests",
    "status 429",
    "status 500",
    "status 502",
    "status 503",
    "status 504",
    "dns error",
)
PRIORITY_ORDER: Final = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}
PRIORITY_PREFIX: Final = re.compile(r"^\[p[0-3]\]\s*", re.IGNORECASE)

Scope: TypeAlias = Literal["auto", "uncommitted", "session"]
SelectedScope: TypeAlias = Literal["uncommitted", "session"]
ReviewTarget: TypeAlias = Literal["base", "uncommitted"]
JsonObject: TypeAlias = dict[str, Any]


class ReviewLoopError(RuntimeError):
    """Report a review-loop configuration or execution failure."""


def _run_git(
    repo: Path, *arguments: str, check: bool = True
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        ["git", *arguments],
        cwd=repo,
        check=False,
        capture_output=True,
        text=True,
    )
    if check and completed.returncode != 0:
        detail = (
            completed.stderr.strip() or completed.stdout.strip() or "git command failed"
        )
        raise ReviewLoopError(detail)
    return completed


def repository_root(repo: Path) -> Path:
    """Return the canonical Git worktree root for *repo*."""
    completed = _run_git(repo.resolve(), "rev-parse", "--show-toplevel")
    return Path(completed.stdout.strip()).resolve()


def is_dirty(repo: Path) -> bool:
    """Return whether staged, unstaged, or untracked changes exist."""
    completed = _run_git(repo, "status", "--porcelain=v1", "--untracked-files=all")
    return bool(completed.stdout)


def select_scope(requested_scope: str, dirty: bool) -> SelectedScope:
    """Resolve the requested scope once, before the loop starts."""
    if requested_scope not in {"auto", "uncommitted", "session"}:
        raise ReviewLoopError(
            f"Invalid scope {requested_scope!r}; expected auto, uncommitted, or session."
        )
    if requested_scope == "auto":
        return "uncommitted" if dirty else "session"
    return cast(SelectedScope, requested_scope)


def _resolve_commit(repo: Path, ref: str) -> str | None:
    completed = _run_git(
        repo, "rev-parse", "--verify", f"{ref}^{{commit}}", check=False
    )
    if completed.returncode != 0:
        return None
    return completed.stdout.strip()


def resolve_base(repo: Path, explicit_base: str | None) -> tuple[str, str]:
    """Resolve a session base and its merge base without fetching."""
    if explicit_base is not None:
        if _resolve_commit(repo, explicit_base) is None:
            raise ReviewLoopError(
                f"Base ref {explicit_base!r} does not resolve to a commit."
            )
        base_ref = explicit_base
    else:
        base_ref = next(
            (
                candidate
                for candidate in BASE_CANDIDATES
                if _resolve_commit(repo, candidate)
            ),
            "",
        )
        if not base_ref:
            candidates = ", ".join(BASE_CANDIDATES)
            raise ReviewLoopError(
                f"No automatic session base exists ({candidates}); provide base=<ref>."
            )

    completed = _run_git(repo, "merge-base", "HEAD", base_ref, check=False)
    if completed.returncode != 0 or not completed.stdout.strip():
        detail = completed.stderr.strip() or "the histories have no merge base"
        raise ReviewLoopError(f"Cannot resolve merge base for {base_ref!r}: {detail}")
    return base_ref, completed.stdout.strip()


def build_review_command(
    *,
    target: ReviewTarget,
    schema_path: Path,
    output_path: Path,
    base_ref: str | None,
    merge_base: str | None,
) -> list[str]:
    """Build a structured, read-only review subprocess command."""
    # `codex exec review` starts a Review request that does not forward
    # `--output-schema`. A regular exec turn preserves the schema and still
    # provides an isolated reviewer when paired with this read-only prompt.
    output_contract = """
Report only discrete, actionable issues introduced by this review scope. Focus on
correctness, security, performance, reliability, and maintainability. Ignore
style and backward compatibility unless repository instructions require them.
Use repository-relative file paths and the shortest changed line range that
shows each issue. Start every title with [P0], [P1], [P2], or [P3], and set the
matching priority field. Return status "clean" with an empty findings array when
there are no findings. Otherwise return status "findings" and every finding.
Return only the JSON object required by the output schema. Do not modify files.
""".strip()
    if target == "uncommitted":
        review_prompt = f"""Review only staged, unstaged, and untracked changes in this repository.
Inspect git diff, git diff --cached, and every path reported by git ls-files
--others --exclude-standard. Do not review committed branch changes.

{output_contract}"""
    elif target == "base":
        if not base_ref or not merge_base:
            raise ReviewLoopError(
                "A base review requires a pinned base ref and merge-base SHA."
            )
        review_prompt = f"""Review all current repository changes from merge base {merge_base} through the working tree.
The selected base ref is {base_ref}. Inspect git diff {merge_base} for the net
tracked changes, and inspect every path reported by git ls-files --others
--exclude-standard. Include committed, staged, unstaged, and untracked changes
in this session pass.

{output_contract}"""
    else:
        raise ReviewLoopError(f"Unsupported review target: {target!r}")

    command = [
        "codex",
        "exec",
        "--json",
        "--ephemeral",
        "--model",
        MODEL,
        "-c",
        f'model_reasoning_effort="{REASONING_EFFORT}"',
        "-c",
        'sandbox_mode="read-only"',
        "-c",
        'approval_policy="never"',
        "--output-schema",
        str(schema_path),
        "--output-last-message",
        str(output_path),
        review_prompt,
    ]
    return command


def _nonempty_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ReviewLoopError(f"Review field {field!r} must be a non-empty string.")
    return value


def validate_review_payload(payload: Any) -> JsonObject:
    """Validate the structured review result without third-party dependencies."""
    if not isinstance(payload, dict):
        raise ReviewLoopError("Review output must be a JSON object.")
    if set(payload) != {"status", "findings"}:
        raise ReviewLoopError("Review output must contain only status and findings.")
    status = payload.get("status")
    findings = payload.get("findings")
    if status not in {"clean", "findings"} or not isinstance(findings, list):
        raise ReviewLoopError("Review output has an invalid status or findings list.")
    if (status == "clean" and findings) or (status == "findings" and not findings):
        raise ReviewLoopError("Review status is inconsistent with the findings list.")

    required = {
        "title",
        "body",
        "priority",
        "confidence",
        "file",
        "line_start",
        "line_end",
    }
    for index, raw_finding in enumerate(findings):
        if not isinstance(raw_finding, dict) or set(raw_finding) != required:
            raise ReviewLoopError(f"Finding {index} has missing or unknown fields.")
        for field in ("title", "body", "file"):
            _nonempty_string(raw_finding[field], field)
        priority = raw_finding["priority"]
        if priority not in PRIORITY_ORDER:
            raise ReviewLoopError(f"Finding {index} has invalid priority {priority!r}.")
        confidence = raw_finding["confidence"]
        if (
            isinstance(confidence, bool)
            or not isinstance(confidence, (int, float))
            or not 0 <= confidence <= 1
        ):
            raise ReviewLoopError(f"Finding {index} has invalid confidence.")
        line_start = raw_finding["line_start"]
        line_end = raw_finding["line_end"]
        if (
            isinstance(line_start, bool)
            or isinstance(line_end, bool)
            or not isinstance(line_start, int)
            or not isinstance(line_end, int)
            or line_start < 1
            or line_end < line_start
        ):
            raise ReviewLoopError(f"Finding {index} has an invalid line range.")
    return cast(JsonObject, payload)


def _normalized_path(path: str) -> str:
    normalized = posixpath.normpath(path.replace("\\", "/"))
    return normalized.removeprefix("./")


def _normalized_title(title: str) -> str:
    without_priority = PRIORITY_PREFIX.sub("", title.strip())
    return " ".join(without_priority.casefold().split())


def _title_with_priority(title: str, priority: str) -> str:
    without_priority = PRIORITY_PREFIX.sub("", title.strip())
    return f"[{priority}] {without_priority}"


def merge_results(results: list[tuple[str, JsonObject]]) -> JsonObject:
    """Merge reviewer passes, deduplicating the same source location and title."""
    merged: dict[tuple[str, int, int, str], JsonObject] = {}
    for source, payload in results:
        validated = validate_review_payload(payload)
        for raw_finding in validated["findings"]:
            finding = cast(JsonObject, raw_finding)
            key = (
                _normalized_path(cast(str, finding["file"])),
                cast(int, finding["line_start"]),
                cast(int, finding["line_end"]),
                _normalized_title(cast(str, finding["title"])),
            )
            existing = merged.get(key)
            if existing is None:
                priority = cast(str, finding["priority"])
                merged[key] = {
                    **finding,
                    "title": _title_with_priority(
                        cast(str, finding["title"]), priority
                    ),
                    "sources": [source],
                }
                continue

            sources = cast(list[str], existing["sources"])
            if source not in sources:
                sources.append(source)
            best_priority = min(
                cast(str, existing["priority"]),
                cast(str, finding["priority"]),
                key=PRIORITY_ORDER.__getitem__,
            )
            if cast(float, finding["confidence"]) > cast(float, existing["confidence"]):
                selected_sources = sources
                existing = {
                    **finding,
                    "title": _title_with_priority(
                        cast(str, finding["title"]), best_priority
                    ),
                    "priority": best_priority,
                    "sources": selected_sources,
                }
                merged[key] = existing
            else:
                existing["priority"] = best_priority
                existing["title"] = _title_with_priority(
                    cast(str, existing["title"]), best_priority
                )

    findings = list(merged.values())
    findings.sort(
        key=lambda item: (
            PRIORITY_ORDER[cast(str, item["priority"])],
            _normalized_path(cast(str, item["file"])),
            cast(int, item["line_start"]),
            _normalized_title(cast(str, item["title"])),
        )
    )
    return {"status": "findings" if findings else "clean", "findings": findings}


def _write_json(path: Path, payload: JsonObject) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(f"{path.suffix}.tmp")
    temporary.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    os.chmod(temporary, 0o600)
    temporary.replace(path)


def initialize_state(
    *,
    repo: Path,
    requested_scope: str,
    explicit_base: str | None,
    max_iterations: int,
    state_root: Path | None = None,
) -> JsonObject:
    """Pin loop scope and session-base metadata, then persist loop state."""
    if isinstance(max_iterations, bool) or max_iterations < 1:
        raise ReviewLoopError("max-iterations must be a positive integer.")
    root = repository_root(repo)
    selected_scope = select_scope(requested_scope, is_dirty(root))
    base_ref: str | None = None
    merge_base: str | None = None
    if selected_scope == "session":
        base_ref, merge_base = resolve_base(root, explicit_base)

    if state_root is None:
        state_directory = Path(tempfile.mkdtemp(prefix="codex-review-fix-loop-"))
    else:
        state_directory = state_root.resolve()
        state_directory.mkdir(parents=True, exist_ok=True)
        os.chmod(state_directory, 0o700)
    state_file = state_directory / "state.json"
    state: JsonObject = {
        "version": 1,
        "repo": str(root),
        "requested_scope": requested_scope,
        "selected_scope": selected_scope,
        "base_ref": base_ref,
        "merge_base": merge_base,
        "max_iterations": max_iterations,
        "completed_iterations": 0,
        "status": "ready",
        "last_findings": [],
        "review_targets": [],
        "state_file": str(state_file),
    }
    _write_json(state_file, state)
    return state


def run_process(
    command: list[str], *, cwd: Path, event_log: Path
) -> subprocess.CompletedProcess[str]:
    """Run Codex while preserving its JSONL event stream for diagnosis."""
    completed = subprocess.run(
        command,
        cwd=cwd,
        check=False,
        capture_output=True,
        text=True,
    )
    event_log.write_text(completed.stdout, encoding="utf-8")
    os.chmod(event_log, 0o600)
    return completed


def _is_transient_failure(detail: str) -> bool:
    normalized = detail.casefold()
    return any(marker in normalized for marker in TRANSIENT_ERROR_MARKERS)


def run_structured_review(
    *,
    repo: Path,
    target: ReviewTarget,
    base_ref: str | None,
    merge_base: str | None = None,
    round_number: int,
    artifact_dir: Path,
) -> JsonObject:
    """Run one structured review, retrying one transient process failure."""
    artifact_dir.mkdir(parents=True, exist_ok=True)
    output_path = artifact_dir / f"round-{round_number:03d}-{target}.json"
    event_log = artifact_dir / f"round-{round_number:03d}-{target}.jsonl"
    command = build_review_command(
        target=target,
        schema_path=REVIEW_SCHEMA_PATH,
        output_path=output_path,
        base_ref=base_ref,
        merge_base=merge_base,
    )

    for attempt in range(2):
        output_path.unlink(missing_ok=True)
        completed = run_process(command, cwd=repo, event_log=event_log)
        if completed.returncode == 0:
            if not output_path.is_file():
                raise ReviewLoopError(
                    f"{target} review succeeded but did not write structured output."
                )
            try:
                payload = json.loads(output_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as error:
                raise ReviewLoopError(
                    f"{target} review returned malformed structured output: {error}"
                ) from error
            return validate_review_payload(payload)

        detail = (
            completed.stderr.strip() or completed.stdout.strip() or "unknown failure"
        )
        if attempt == 0 and _is_transient_failure(detail):
            continue
        qualifier = " after one retry" if attempt else ""
        raise ReviewLoopError(f"{target} review failed{qualifier}: {detail}")

    raise AssertionError("unreachable")  # pragma: no cover


def _read_state(state_file: Path) -> JsonObject:
    try:
        payload = json.loads(state_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ReviewLoopError(
            f"Cannot read loop state {state_file}: {error}"
        ) from error
    if not isinstance(payload, dict) or payload.get("version") != 1:
        raise ReviewLoopError(f"Unsupported loop state in {state_file}.")
    return cast(JsonObject, payload)


def _result(state: JsonObject, status: str, targets: list[str]) -> JsonObject:
    return {
        "status": status,
        "selected_scope": state["selected_scope"],
        "base_ref": state["base_ref"],
        "merge_base": state["merge_base"],
        "completed_iterations": state["completed_iterations"],
        "max_iterations": state["max_iterations"],
        "findings": state["last_findings"],
        "review_targets": targets,
        "state_file": state["state_file"],
    }


def execute_round(state_file: Path) -> JsonObject:
    """Execute every reviewer pass required for one logical loop iteration."""
    state_file = state_file.resolve()
    state = _read_state(state_file)
    completed_iterations = cast(int, state["completed_iterations"])
    max_iterations = cast(int, state["max_iterations"])
    if completed_iterations >= max_iterations:
        state["status"] = "limit_reached"
        _write_json(state_file, state)
        return _result(state, "limit_reached", cast(list[str], state["review_targets"]))

    repo = Path(cast(str, state["repo"]))
    selected_scope = cast(SelectedScope, state["selected_scope"])
    dirty = is_dirty(repo)
    targets: list[ReviewTarget]
    if selected_scope == "uncommitted":
        if not dirty:
            state.update(status="clean", last_findings=[], review_targets=[])
            _write_json(state_file, state)
            return _result(state, "clean", [])
        targets = ["uncommitted"]
    else:
        targets = ["base"]
        if dirty:
            targets.append("uncommitted")

    round_number = completed_iterations + 1
    artifact_dir = state_file.parent / "artifacts"
    results: list[tuple[str, JsonObject]] = []
    for target in targets:
        payload = run_structured_review(
            repo=repo,
            target=target,
            base_ref=cast(str | None, state["base_ref"]),
            merge_base=cast(str | None, state["merge_base"]),
            round_number=round_number,
            artifact_dir=artifact_dir,
        )
        results.append((target, payload))

    merged = merge_results(results)
    completed_iterations += 1
    findings = cast(list[JsonObject], merged["findings"])
    status = cast(str, merged["status"])
    if findings and completed_iterations >= max_iterations:
        status = "limit_reached"
    state.update(
        completed_iterations=completed_iterations,
        status=status,
        last_findings=findings,
        review_targets=list(targets),
    )
    _write_json(state_file, state)
    return _result(state, status, list(targets))


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    initialize = subparsers.add_parser("init", help="resolve and pin loop scope")
    initialize.add_argument("--repo", type=Path, default=Path.cwd())
    initialize.add_argument(
        "--scope", choices=("auto", "uncommitted", "session"), default="auto"
    )
    initialize.add_argument("--base")
    initialize.add_argument(
        "--max-iterations", type=int, default=DEFAULT_MAX_ITERATIONS
    )
    initialize.add_argument("--state-root", type=Path)

    review = subparsers.add_parser("review", help="execute one logical review round")
    review.add_argument("--state-file", type=Path, required=True)
    return parser


def main(arguments: list[str] | None = None) -> int:
    """Run the command-line interface and print one machine-readable result."""
    args = _parser().parse_args(arguments)
    try:
        if args.command == "init":
            result = initialize_state(
                repo=args.repo,
                requested_scope=args.scope,
                explicit_base=args.base,
                max_iterations=args.max_iterations,
                state_root=args.state_root,
            )
        else:
            result = execute_round(args.state_file)
    except ReviewLoopError as error:
        print(f"review-fix-loop: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
