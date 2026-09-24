#!/usr/bin/env python3
"""Render Claude Code subagents from the shared capacity catalog."""

from __future__ import annotations

import argparse
import json
import re
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, cast

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.render_codex_agents import (  # noqa: E402
    CATALOG_PATH,
    REPO_ROOT,
    expand_catalog,
    load_catalog,
    require_table,
)

AGENTS_DIRECTORY = REPO_ROOT / ".claude" / "agents"
OVERLAY_SKILLS_DIRECTORY = REPO_ROOT / ".claude" / "overlays" / "skills"
CLAUDE_MODELS = frozenset({"sonnet", "opus", "haiku", "fable", "inherit"})
EFFORTS = {
    "minimal": "low",
    "low": "low",
    "medium": "medium",
    "high": "high",
    "xhigh": "xhigh",
    "max": "max",
}
READ_ONLY_DISALLOWED_TOOLS = "Edit, Write, NotebookEdit"
SKILL_REFERENCE = re.compile(r"\$([a-z0-9][a-z0-9-]*)")
TERM_PATTERN = re.compile(r"^[A-Za-z][A-Za-z0-9-]*$")


@dataclass(frozen=True)
class ClaudeSettings:
    """Claude export settings from the catalog's claude table."""

    exclude_skills: frozenset[str]
    models: dict[str, str]
    terms: dict[str, str]
    settings: dict[str, Any]


def string_table(value: object, label: str) -> dict[str, str]:
    """Require a table of non-empty strings."""
    table = require_table(value, label)
    for key, item in table.items():
        if not isinstance(item, str) or not item.strip():
            raise ValueError(f"{label}.{key} must be a non-empty string")
    return cast(dict[str, str], table)


def claude_settings(catalog: dict[str, Any]) -> ClaudeSettings:
    """Validate the catalog's claude table."""
    table = require_table(catalog.get("claude"), "claude")
    expected = {"exclude_skills", "models", "guidance_terms"}
    if not expected <= table.keys() <= expected | {"settings"}:
        raise ValueError(
            f"claude must contain {', '.join(sorted(expected))} and may contain settings"
        )
    managed = require_table(table.get("settings", {}), "claude.settings")
    if "env" in managed:
        raise ValueError("claude.settings must not set env; the sync manages it")
    raw_excludes = table["exclude_skills"]
    if not isinstance(raw_excludes, list) or not all(
        isinstance(name, str) and name for name in cast(list[object], raw_excludes)
    ):
        raise ValueError("claude.exclude_skills must be a list of skill names")
    models = string_table(table["models"], "claude.models")
    for codex_model, claude_model in models.items():
        if claude_model not in CLAUDE_MODELS:
            raise ValueError(
                f"claude.models.{codex_model} must be one of {sorted(CLAUDE_MODELS)}"
            )
    terms = string_table(table["guidance_terms"], "claude.guidance_terms")
    for term in terms:
        if TERM_PATTERN.fullmatch(term) is None:
            raise ValueError(f"claude.guidance_terms has an invalid term: {term}")
    return ClaudeSettings(
        exclude_skills=frozenset(cast(list[str], raw_excludes)),
        models=models,
        terms=terms,
        settings=managed,
    )


def exported_skills(repo_root: Path, settings: ClaudeSettings) -> frozenset[str]:
    """List the skill names that the Claude target exports."""
    base = {
        path.parent.name
        for path in repo_root.glob("*/SKILL.md")
        if not path.parent.name.startswith(".")
    }
    unknown = settings.exclude_skills - base
    if unknown:
        raise ValueError(
            f"claude.exclude_skills names unknown skills: {sorted(unknown)}"
        )
    overlays = repo_root / ".claude" / "overlays" / "skills"
    overlay_names = {path.parent.name for path in overlays.glob("*/SKILL.md")}
    return frozenset((base - settings.exclude_skills) | overlay_names)


def transform_text(text: str, terms: dict[str, str], skills: frozenset[str]) -> str:
    """Replace Codex model-family terms and rewrite exported skill references."""
    if terms:
        pattern = re.compile(
            r"\b(" + "|".join(re.escape(term) for term in sorted(terms)) + r")\b"
        )
        text = pattern.sub(lambda match: terms[match.group(1)], text)
    return SKILL_REFERENCE.sub(
        lambda match: (
            f"/{match.group(1)}" if match.group(1) in skills else match.group(0)
        ),
        text,
    )


def render_agent(
    name: str,
    agent: dict[str, Any],
    settings: ClaudeSettings,
    skills: frozenset[str],
) -> str:
    """Render one Claude subagent file with stable field order."""
    codex_model = cast(str, agent["model"])
    if codex_model not in settings.models:
        raise ValueError(f"{name}: model {codex_model} has no claude.models mapping")
    effort = cast(str, agent["model_reasoning_effort"])
    if effort not in EFFORTS:
        raise ValueError(f"{name}: unsupported reasoning effort {effort}")
    description = transform_text(
        cast(str, agent["description"]), settings.terms, skills
    )
    lines = [
        "---\n",
        "# Generated by scripts/render_claude_agents.py; edit .codex/agent_catalog.toml.\n",
        f"name: {json.dumps(name)}\n",
        f"description: {json.dumps(description)}\n",
        f"model: {settings.models[codex_model]}\n",
        f"effort: {EFFORTS[effort]}\n",
    ]
    if agent["sandbox_mode"] == "read-only":
        lines.append(f"disallowedTools: {READ_ONLY_DISALLOWED_TOOLS}\n")
    lines.append("---\n\n")
    instructions = transform_text(
        cast(str, agent["developer_instructions"]), settings.terms, skills
    )
    lines.append(instructions.strip("\n") + "\n")
    return "".join(lines)


def render_catalog(catalog_path: Path, repo_root: Path = REPO_ROOT) -> dict[str, str]:
    """Render every catalog agent as a Claude subagent file."""
    catalog = load_catalog(catalog_path)
    settings = claude_settings(catalog)
    skills = exported_skills(repo_root, settings)
    return {
        name.replace("_", "-") + ".md": render_agent(name, agent, settings, skills)
        for name, agent in expand_catalog(catalog).items()
    }


def main() -> int:
    """Check generated agents by default, or write them when requested."""
    parser = argparse.ArgumentParser(description=__doc__)
    _ = parser.add_argument(
        "--write", action="store_true", help="update generated agents"
    )
    arguments = parser.parse_args()
    try:
        expected = render_catalog(CATALOG_PATH)
        actual = {path.name: path for path in AGENTS_DIRECTORY.glob("*.md")}
        unexpected = sorted(actual.keys() - expected.keys())
        if unexpected:
            raise ValueError(f"unexpected agent files: {', '.join(unexpected)}")
        stale = [
            name
            for name, content in expected.items()
            if name not in actual or actual[name].read_text(encoding="utf-8") != content
        ]
        if arguments.write:
            AGENTS_DIRECTORY.mkdir(parents=True, exist_ok=True)
            for name in stale:
                (AGENTS_DIRECTORY / name).write_text(expected[name], encoding="utf-8")
            print(f"Updated {len(stale)} Claude agent file(s).")
            return 0
        if stale:
            print(
                f"Stale or missing Claude agents: {', '.join(stale)}", file=sys.stderr
            )
            return 1
        print(f"All {len(expected)} Claude agent files match the catalog.")
        return 0
    except (OSError, tomllib.TOMLDecodeError, TypeError, ValueError) as error:
        print(f"Agent catalog error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
