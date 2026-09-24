#!/usr/bin/env python3
"""Validate Claude Code subagent definitions before they are synced."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import cast

MODELS = frozenset({"sonnet", "opus", "haiku", "fable", "inherit"})
EFFORTS = frozenset({"low", "medium", "high", "xhigh", "max"})
NAME_PATTERN = re.compile(r"^[a-z][a-z0-9_-]*$")
FIELD_PATTERN = re.compile(r"^([A-Za-z][A-Za-z0-9_-]*):[ \t]*(.*)$")


def parse_frontmatter(text: str) -> dict[str, str]:
    """Parse the flat YAML frontmatter that the renderer emits."""
    lines = text.splitlines()
    if not lines or lines[0] != "---":
        raise ValueError("missing frontmatter start")
    try:
        end = lines.index("---", 1)
    except ValueError as error:
        raise ValueError("missing frontmatter end") from error
    fields: dict[str, str] = {}
    for line in lines[1:end]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = FIELD_PATTERN.fullmatch(line)
        if match is None:
            raise ValueError(f"unsupported frontmatter line: {line!r}")
        key, raw = match.groups()
        if key in fields:
            raise ValueError(f"duplicate frontmatter field: {key}")
        value = raw.strip()
        if value.startswith('"'):
            decoded: object = json.loads(value)
            if not isinstance(decoded, str):
                raise ValueError(f"{key} must be a string")
            value = decoded
        fields[key] = value
    if not "\n".join(lines[end + 1 :]).strip():
        raise ValueError("agent instructions must not be empty")
    return fields


def validate_agent(agent_path: Path) -> list[str]:
    """Return validation errors for one Claude subagent file."""
    try:
        fields = parse_frontmatter(agent_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError) as error:
        return [f"{agent_path}: invalid agent: {error}"]
    errors: list[str] = []
    for field in ("name", "description"):
        if not fields.get(field, "").strip():
            errors.append(f"{agent_path}: {field} must be a non-empty string")
    name = fields.get("name", "")
    if name and NAME_PATTERN.fullmatch(name) is None:
        errors.append(f"{agent_path}: invalid name {name!r}")
    model = fields.get("model")
    if model is not None and model not in MODELS:
        errors.append(f"{agent_path}: model must be one of {sorted(MODELS)}")
    effort = fields.get("effort")
    if effort is not None and effort not in EFFORTS:
        errors.append(f"{agent_path}: effort must be one of {sorted(EFFORTS)}")
    return errors


def main() -> int:
    """Validate every Claude subagent in the requested directory."""
    parser = argparse.ArgumentParser(description=__doc__)
    _ = parser.add_argument("agents_directory", type=Path)
    agents_directory = cast(Path, parser.parse_args().agents_directory)
    if not agents_directory.is_dir():
        print(f"Agent directory does not exist: {agents_directory}", file=sys.stderr)
        return 1
    errors = [
        error
        for agent_path in sorted(agents_directory.glob("*.md"))
        for error in validate_agent(agent_path)
    ]
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
