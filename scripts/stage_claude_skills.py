#!/usr/bin/env python3
"""Adapt a staged skills tree for Claude Code after overlays are applied."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import cast

INTERFACE_PATH = Path("agents") / "openai.yaml"
EXPLICIT_ONLY = re.compile(r"^[ \t]+allow_implicit_invocation:[ \t]*false[ \t]*$", re.M)
DISABLE_FIELD = "disable-model-invocation"


def add_disable_field(skill_text: str) -> str:
    """Add the Claude field that blocks implicit skill invocation."""
    if not skill_text.startswith("---\n"):
        raise ValueError("SKILL.md must start with frontmatter")
    end = skill_text.find("\n---\n", 4)
    if end < 0:
        raise ValueError("SKILL.md frontmatter is not terminated")
    frontmatter = skill_text[4:end]
    if re.search(rf"^{DISABLE_FIELD}:", frontmatter, re.M):
        return skill_text
    return f"---\n{frontmatter}\n{DISABLE_FIELD}: true{skill_text[end:]}"


def stage_skill(skill: Path) -> None:
    """Translate the Codex invocation policy, then remove the Codex interface."""
    interface = skill / INTERFACE_PATH
    if not interface.is_file():
        return
    if EXPLICIT_ONLY.search(interface.read_text(encoding="utf-8")):
        skill_file = skill / "SKILL.md"
        text = skill_file.read_text(encoding="utf-8")
        skill_file.write_text(add_disable_field(text), encoding="utf-8")
    interface.unlink()
    if not any(interface.parent.iterdir()):
        interface.parent.rmdir()


def main() -> int:
    """Adapt every skill in the staging directory."""
    parser = argparse.ArgumentParser(description=__doc__)
    _ = parser.add_argument("skills_directory", type=Path)
    skills_directory = cast(Path, parser.parse_args().skills_directory)
    try:
        for skill_file in sorted(skills_directory.glob("*/SKILL.md")):
            stage_skill(skill_file.parent)
    except (OSError, UnicodeError, ValueError) as error:
        print(f"Error: cannot stage Claude skills: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
