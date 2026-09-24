#!/usr/bin/env python3
"""Run one structured Claude review round for the review-fix-loop skill.

The Claude export places this file next to run_review.py. It reuses that
runner's scope pinning, state, validation, and merging, and replaces only the
reviewer process.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any, Final, cast

sys.path.insert(0, str(Path(__file__).resolve().parent))

import run_review as base  # noqa: E402

MODEL: Final = "sonnet"
EFFORT: Final = "medium"
AVAILABLE_TOOLS: Final = "Read,Grep,Glob,Bash"
ALLOWED_TOOLS: Final = (
    "Read",
    "Grep",
    "Glob",
    "Bash(git diff:*)",
    "Bash(git ls-files:*)",
    "Bash(git status:*)",
    "Bash(git show:*)",
    "Bash(git log:*)",
)
DISALLOWED_TOOLS: Final = ("Edit", "Write", "NotebookEdit")
EXTRA_TRANSIENT_MARKERS: Final = ("overloaded", "status 529")


def build_review_command(
    *,
    target: base.ReviewTarget,
    schema_path: Path,
    base_ref: str | None,
    merge_base: str | None,
) -> list[str]:
    """Build a headless, read-only Claude review command."""
    codex_command = base.build_review_command(
        target=target,
        schema_path=schema_path,
        output_path=schema_path,
        base_ref=base_ref,
        merge_base=merge_base,
    )
    review_prompt = codex_command[-1]
    schema = json.dumps(
        json.loads(schema_path.read_text(encoding="utf-8")), separators=(",", ":")
    )
    return [
        "claude",
        "-p",
        "--model",
        MODEL,
        "--effort",
        EFFORT,
        "--output-format",
        "json",
        "--no-session-persistence",
        "--permission-mode",
        "dontAsk",
        "--tools",
        AVAILABLE_TOOLS,
        "--allowedTools",
        *ALLOWED_TOOLS,
        "--disallowedTools",
        *DISALLOWED_TOOLS,
        "--json-schema",
        schema,
        "--",
        review_prompt,
    ]


def _is_transient_failure(detail: str) -> bool:
    normalized = detail.casefold()
    return base._is_transient_failure(detail) or any(  # pyright: ignore[reportPrivateUsage]
        marker in normalized for marker in EXTRA_TRANSIENT_MARKERS
    )


def extract_payload(stdout: str, target: str) -> tuple[Any, str | None]:
    """Return the structured payload, or an error detail from the Claude result."""
    try:
        envelope = json.loads(stdout)
    except json.JSONDecodeError as error:
        raise base.ReviewLoopError(
            f"{target} review returned malformed JSON output: {error}"
        ) from error
    if not isinstance(envelope, dict):
        raise base.ReviewLoopError(f"{target} review returned a non-object result.")
    result = cast(dict[str, Any], envelope)
    if result.get("is_error") or result.get("subtype") not in (None, "success"):
        detail = result.get("result") or result.get("subtype") or "unknown failure"
        return None, str(detail)
    structured = result.get("structured_output")
    if structured is not None:
        return structured, None
    text = result.get("result")
    if not isinstance(text, str):
        raise base.ReviewLoopError(
            f"{target} review succeeded but did not return structured output."
        )
    try:
        return json.loads(text), None
    except json.JSONDecodeError as error:
        raise base.ReviewLoopError(
            f"{target} review returned malformed structured output: {error}"
        ) from error


def run_structured_review(
    *,
    repo: Path,
    target: base.ReviewTarget,
    base_ref: str | None,
    merge_base: str | None = None,
    round_number: int,
    artifact_dir: Path,
) -> base.JsonObject:
    """Run one Claude review, retrying one transient process failure."""
    artifact_dir.mkdir(parents=True, exist_ok=True)
    output_path = artifact_dir / f"round-{round_number:03d}-{target}.json"
    event_log = artifact_dir / f"round-{round_number:03d}-{target}.log"
    command = build_review_command(
        target=target,
        schema_path=base.REVIEW_SCHEMA_PATH,
        base_ref=base_ref,
        merge_base=merge_base,
    )

    for attempt in range(2):
        output_path.unlink(missing_ok=True)
        completed = base.run_process(command, cwd=repo, event_log=event_log)
        detail: str | None
        if completed.returncode == 0:
            payload, detail = extract_payload(completed.stdout, target)
            if detail is None:
                output_path.write_text(
                    json.dumps(payload, indent=2) + "\n", encoding="utf-8"
                )
                os.chmod(output_path, 0o600)
                return base.validate_review_payload(payload)
        else:
            detail = (
                completed.stderr.strip()
                or completed.stdout.strip()
                or "unknown failure"
            )
        if attempt == 0 and _is_transient_failure(detail):
            continue
        qualifier = " after one retry" if attempt else ""
        raise base.ReviewLoopError(f"{target} review failed{qualifier}: {detail}")

    raise AssertionError("unreachable")  # pragma: no cover


base.run_structured_review = run_structured_review
main = base.main


if __name__ == "__main__":
    raise SystemExit(main())
