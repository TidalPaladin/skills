#!/usr/bin/env python3
"""Render personal Codex agent defaults without changing unrelated settings."""

from __future__ import annotations

import argparse
import json
import re
import sys
import tomllib
from pathlib import Path
from typing import Any, cast

AGENTS_HEADER = re.compile(
    r"""^[ \t]*\[[ \t]*(?:agents|"agents"|'agents')[ \t]*\][ \t]*(?:#.*)?(?:\r?\n)?$"""
)
TABLE_HEADER = re.compile(r"^[ \t]*\[")
MANAGED_KEYS = frozenset(
    {
        "max_threads",
        "max_concurrent_threads_per_session",
        "default_subagent_model",
        "default_subagent_reasoning_effort",
    }
)


def load_toml(path: Path) -> dict[str, Any]:
    """Read a TOML file, or an empty document when the file is absent."""
    if not path.is_file():
        return {}
    return cast(dict[str, Any], tomllib.loads(path.read_bytes().decode("utf-8")))


def required_table(value: object, label: str) -> dict[str, Any]:
    """Require one TOML table."""
    if not isinstance(value, dict):
        raise TypeError(f"{label} must be a table")
    return cast(dict[str, Any], value)


def desired_settings(project_path: Path, catalog_path: Path) -> tuple[int, str, str]:
    """Resolve capacity and the catalog's default capacity class."""
    project = load_toml(project_path)
    project_agents = required_table(project.get("agents"), "project agents")
    minimum_threads = project_agents.get("max_threads")
    if type(minimum_threads) is not int or minimum_threads < 1:
        raise ValueError("project agents.max_threads must be a positive integer")

    catalog = load_toml(catalog_path)
    defaults = required_table(catalog.get("defaults"), "catalog defaults")
    classes = required_table(catalog.get("classes"), "catalog classes")
    profile = defaults.get("subagent_profile")
    if not isinstance(profile, str) or profile not in classes:
        raise ValueError("catalog defaults.subagent_profile must name a class")
    agent_class = required_table(classes[profile], f"catalog classes.{profile}")
    model = agent_class.get("model")
    effort = agent_class.get("model_reasoning_effort")
    if not isinstance(model, str) or not model.strip():
        raise ValueError(f"catalog classes.{profile}.model must be a string")
    if not isinstance(effort, str) or not effort.strip():
        raise ValueError(
            f"catalog classes.{profile}.model_reasoning_effort must be a string"
        )
    return minimum_threads, model, effort


def agents_span(lines: list[str]) -> tuple[int, int] | None:
    """Locate the [agents] table without touching nested agent tables."""
    start: int | None = None
    for index, line in enumerate(lines):
        if AGENTS_HEADER.fullmatch(line):
            if start is not None:
                raise ValueError("personal config has multiple [agents] tables")
            start = index
        elif start is not None and TABLE_HEADER.match(line):
            return start, index
    return (start, len(lines)) if start is not None else None


def comment_offset(value: str) -> int | None:
    """Find an inline TOML comment outside one-line quoted strings."""
    quote: str | None = None
    escaped = False
    for index, character in enumerate(value):
        if quote == '"':
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                quote = None
        elif quote == "'":
            if character == "'":
                quote = None
        elif character in {'"', "'"}:
            quote = character
        elif character == "#":
            return index
    return None


def replace_assignment(line: str, key: str, value: int | str) -> str:
    """Replace one managed value while preserving its layout and comment."""
    body = line.rstrip("\r\n")
    ending = line[len(body) :]
    match = re.fullmatch(rf"([ \t]*{re.escape(key)}[ \t]*=[ \t]*)(.*)", body)
    if match is None:
        raise ValueError(f"cannot locate personal agents.{key} assignment")
    rest = match.group(2)
    comment = comment_offset(rest)
    before_comment = rest if comment is None else rest[:comment]
    suffix = before_comment[len(before_comment.rstrip(" \t")) :]
    suffix += "" if comment is None else rest[comment:]
    rendered = str(value) if isinstance(value, int) else json.dumps(value)
    return f"{match.group(1)}{rendered}{suffix}{ending}"


def unmanaged_fields(document: dict[str, Any]) -> dict[str, Any]:
    """Remove only managed agent fields for a preservation check."""
    result = dict(document)
    agents = dict(required_table(result.get("agents", {}), "personal agents"))
    for key in MANAGED_KEYS:
        agents.pop(key, None)
    if agents:
        result["agents"] = agents
    else:
        result.pop("agents", None)
    return result


def render_personal_config(
    original: str, minimum_threads: int, model: str, effort: str
) -> str:
    """Surgically update managed fields in a personal config document."""
    parsed = cast(dict[str, Any], tomllib.loads(original))
    agents = required_table(parsed.get("agents", {}), "personal agents")
    has_legacy = "max_threads" in agents
    has_current = "max_concurrent_threads_per_session" in agents
    if has_legacy and has_current:
        raise ValueError("personal agents has both thread-capacity keys")
    thread_key = "max_concurrent_threads_per_session" if has_current else "max_threads"
    current_threads = agents.get(thread_key)
    if current_threads is not None and (
        type(current_threads) is not int or current_threads < 1
    ):
        raise ValueError(f"personal agents.{thread_key} must be a positive integer")
    for key in ("default_subagent_model", "default_subagent_reasoning_effort"):
        current = agents.get(key)
        if current is not None and not isinstance(current, str):
            raise ValueError(f"personal agents.{key} must be a string")

    settings: dict[str, int | str] = {
        thread_key: max(current_threads or 0, minimum_threads),
        "default_subagent_model": model,
        "default_subagent_reasoning_effort": effort,
    }
    lines = original.splitlines(keepends=True)
    span = agents_span(lines)
    newline = "\r\n" if "\r\n" in original else "\n"

    if span is None:
        if agents:
            raise ValueError("personal agents table must use a plain [agents] header")
        separator = (
            ""
            if not original
            else ("" if original.endswith("\n") else newline) + newline
        )
        assignments = "".join(
            f"{key} = {json.dumps(value)}{newline}" for key, value in settings.items()
        )
        result = f"{original}{separator}[agents]{newline}{assignments}"
    else:
        start, end = span
        found: set[str] = set()
        for index in range(start + 1, end):
            for key, value in settings.items():
                if re.match(rf"^[ \t]*{re.escape(key)}[ \t]*=", lines[index]):
                    found.add(key)
                    if agents.get(key) != value:
                        lines[index] = replace_assignment(lines[index], key, value)
                    break
        if any(key in agents and key not in found for key in settings):
            raise ValueError("a managed personal agent setting uses unsupported syntax")
        missing = [key for key in settings if key not in found]
        if missing:
            if not lines[start].endswith("\n"):
                lines[start] += newline
            insertion = [
                f"{key} = {json.dumps(settings[key])}{newline}" for key in missing
            ]
            lines[start + 1 : start + 1] = insertion
        result = "".join(lines)

    proposed = cast(dict[str, Any], tomllib.loads(result))
    if unmanaged_fields(parsed) != unmanaged_fields(proposed):
        raise ValueError("rendered config changed an unrelated field")
    proposed_agents = required_table(proposed.get("agents"), "rendered agents")
    if any(proposed_agents.get(key) != value for key, value in settings.items()):
        raise ValueError("rendered config did not set every managed field")
    return result


def main() -> int:
    """Render a proposed config for the shell sync's strict validation step."""
    parser = argparse.ArgumentParser(description=__doc__)
    _ = parser.add_argument("project_config", type=Path)
    _ = parser.add_argument("catalog", type=Path)
    _ = parser.add_argument("personal_config", type=Path)
    _ = parser.add_argument("output", type=Path)
    arguments = parser.parse_args()
    try:
        minimum, model, effort = desired_settings(
            arguments.project_config, arguments.catalog
        )
        original = (
            arguments.personal_config.read_bytes().decode("utf-8")
            if arguments.personal_config.exists()
            else ""
        )
        proposed = render_personal_config(original, minimum, model, effort)
        arguments.output.write_bytes(proposed.encode("utf-8"))
        return 0
    except (
        OSError,
        UnicodeError,
        tomllib.TOMLDecodeError,
        TypeError,
        ValueError,
    ) as error:
        print(f"Error: cannot render personal Codex config: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
