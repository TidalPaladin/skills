#!/usr/bin/env python3
"""Validate standalone Codex agent definitions before they are synced."""

from __future__ import annotations

import argparse
import re
import sys
import tomllib
from pathlib import Path
from typing import cast

REQUIRED_STRING_FIELDS = ("name", "description", "developer_instructions")
NICKNAME_PATTERN = re.compile(r"^[A-Za-z0-9 _-]+$")


def validate_agent(agent_path: Path) -> list[str]:
    """Return validation errors for one standalone Codex agent file."""
    try:
        with agent_path.open("rb") as agent_file:
            agent_data = cast(dict[str, object], tomllib.load(agent_file))
    except (OSError, tomllib.TOMLDecodeError) as error:
        return [f"{agent_path}: invalid TOML: {error}"]

    errors: list[str] = []
    for field_name in REQUIRED_STRING_FIELDS:
        field_value = agent_data.get(field_name)
        if not isinstance(field_value, str) or not field_value.strip():
            errors.append(f"{agent_path}: {field_name} must be a non-empty string")

    nickname_candidates = agent_data.get("nickname_candidates")
    if nickname_candidates is not None:
        errors.extend(validate_nickname_candidates(agent_path, nickname_candidates))

    return errors


def validate_nickname_candidates(agent_path: Path, value: object) -> list[str]:
    """Validate the optional display-nickname list."""
    if not isinstance(value, list) or not value:
        return [f"{agent_path}: nickname_candidates must be a non-empty list"]
    candidate_values = cast(list[object], value)
    if not all(isinstance(candidate, str) for candidate in candidate_values):
        return [f"{agent_path}: every nickname candidate must be a string"]

    candidates = [
        candidate for candidate in candidate_values if isinstance(candidate, str)
    ]
    errors: list[str] = []
    if len(candidates) != len(set(candidates)):
        errors.append(f"{agent_path}: nickname candidates must be unique")
    for candidate in candidates:
        if not candidate or NICKNAME_PATTERN.fullmatch(candidate) is None:
            errors.append(
                f"{agent_path}: invalid nickname candidate {candidate!r}; use ASCII letters, digits, spaces, hyphens, or underscores"
            )
    return errors


def parse_agents_directory() -> Path:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Validate standalone TOML files in a Codex agents directory."
    )
    _ = parser.add_argument("agents_directory", type=Path)
    arguments = parser.parse_args()
    return cast(Path, arguments.agents_directory)


def main() -> int:
    """Validate every standalone agent in the requested directory."""
    agents_directory = parse_agents_directory()
    if not agents_directory.is_dir():
        print(f"Agent directory does not exist: {agents_directory}", file=sys.stderr)
        return 1

    agent_paths = sorted(agents_directory.glob("*.toml"))
    errors = [
        error for agent_path in agent_paths for error in validate_agent(agent_path)
    ]
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
