#!/usr/bin/env python3
"""Render Claude Code guidance and personal settings without changing unrelated content."""

from __future__ import annotations

import argparse
import json
import re
import sys
import tomllib
from pathlib import Path
from typing import Any, cast

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.render_claude_agents import (  # noqa: E402
    claude_settings,
    exported_skills,
    transform_text,
)
from scripts.render_codex_agents import (  # noqa: E402
    REPO_ROOT,
    load_catalog,
    require_table,
)

CODEX_ONLY_START = "<!-- codex-only -->"
CODEX_ONLY_END = "<!-- /codex-only -->"
IMPORT_LINE = "@AGENTS.md"
SUBAGENT_MODEL_KEY = "CLAUDE_CODE_SUBAGENT_MODEL"
MARKER_LINE = re.compile(r"^[ \t]*(<!-- /?codex-only -->)[ \t]*$")


def strip_codex_only(text: str) -> str:
    """Remove codex-only blocks, including their marker lines."""
    kept: list[str] = []
    inside = False
    for line in text.splitlines(keepends=True):
        match = MARKER_LINE.match(line.rstrip("\r\n"))
        if match is None:
            if CODEX_ONLY_START in line or CODEX_ONLY_END in line:
                raise ValueError("codex-only markers must be on their own lines")
            if not inside:
                kept.append(line)
        elif match.group(1) == CODEX_ONLY_START:
            if inside:
                raise ValueError("nested codex-only block")
            inside = True
        else:
            if not inside:
                raise ValueError("codex-only end marker without a start marker")
            inside = False
    if inside:
        raise ValueError("unterminated codex-only block")
    return "".join(kept)


def render_guidance(source: str, terms: dict[str, str], skills: frozenset[str]) -> str:
    """Render root guidance for Claude Code."""
    return transform_text(strip_codex_only(source), terms, skills)


def render_claude_md(original: str) -> str:
    """Add the AGENTS.md import once and keep all other content."""
    if any(line.strip() == IMPORT_LINE for line in original.splitlines()):
        return original
    newline = "\r\n" if "\r\n" in original else "\n"
    if not original:
        return f"{IMPORT_LINE}{newline}"
    separator = "" if original.endswith("\n") else newline
    return f"{original}{separator}{newline}{IMPORT_LINE}{newline}"


def merge_managed(current: dict[str, Any], managed: dict[str, Any]) -> dict[str, Any]:
    """Merge managed values into settings; nested tables merge key by key."""
    merged = dict(current)
    for key, value in managed.items():
        existing = merged.get(key)
        if isinstance(value, dict) and isinstance(existing, dict):
            merged[key] = merge_managed(
                cast(dict[str, Any], existing), cast(dict[str, Any], value)
            )
        else:
            merged[key] = value
    return merged


def render_settings(
    original: str, model: str, managed: dict[str, Any] | None = None
) -> str:
    """Set the default subagent model and catalog-managed values only."""
    parsed: object = json.loads(original) if original.strip() else {}
    settings = require_table(parsed, "personal settings")
    require_table(settings.get("env", {}), "personal settings env")
    updated = merge_managed(
        settings, {**(managed or {}), "env": {SUBAGENT_MODEL_KEY: model}}
    )
    if updated == settings and original.strip():
        return original
    return json.dumps(updated, indent=2, ensure_ascii=False) + "\n"


def default_subagent_model(catalog: dict[str, Any]) -> str:
    """Resolve the Claude model for the catalog's default subagent profile."""
    settings = claude_settings(catalog)
    defaults = require_table(catalog["defaults"], "defaults")
    classes = require_table(catalog["classes"], "classes")
    profile = defaults.get("subagent_profile")
    if not isinstance(profile, str) or profile not in classes:
        raise ValueError("catalog defaults.subagent_profile must name a class")
    codex_model = require_table(classes[profile], f"classes.{profile}").get("model")
    if not isinstance(codex_model, str) or codex_model not in settings.models:
        raise ValueError(f"classes.{profile}.model has no claude.models mapping")
    return settings.models[codex_model]


def read_text(path: Path) -> str:
    """Read a UTF-8 file, or an empty document when the file is absent."""
    return path.read_bytes().decode("utf-8") if path.is_file() else ""


def main() -> int:
    """Write proposed Claude guidance, CLAUDE.md, and settings to an output directory."""
    parser = argparse.ArgumentParser(description=__doc__)
    _ = parser.add_argument("catalog", type=Path)
    _ = parser.add_argument("guidance", type=Path)
    _ = parser.add_argument("claude_home", type=Path)
    _ = parser.add_argument("output", type=Path)
    arguments = parser.parse_args()
    try:
        catalog = load_catalog(cast(Path, arguments.catalog))
        settings = claude_settings(catalog)
        skills = exported_skills(REPO_ROOT, settings)
        claude_home = cast(Path, arguments.claude_home)
        output = cast(Path, arguments.output)
        output.mkdir(parents=True, exist_ok=True)
        guidance = render_guidance(
            read_text(cast(Path, arguments.guidance)), settings.terms, skills
        )
        claude_md = render_claude_md(read_text(claude_home / "CLAUDE.md"))
        personal = render_settings(
            read_text(claude_home / "settings.json"),
            default_subagent_model(catalog),
            settings.settings,
        )
        (output / "AGENTS.md").write_bytes(guidance.encode("utf-8"))
        (output / "CLAUDE.md").write_bytes(claude_md.encode("utf-8"))
        (output / "settings.json").write_bytes(personal.encode("utf-8"))
        return 0
    except (
        OSError,
        UnicodeError,
        json.JSONDecodeError,
        tomllib.TOMLDecodeError,
        TypeError,
        ValueError,
    ) as error:
        print(f"Error: cannot render Claude config: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
