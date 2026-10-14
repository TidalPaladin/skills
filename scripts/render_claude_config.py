#!/usr/bin/env python3
"""Render Claude Code guidance and personal settings without changing unrelated content."""

from __future__ import annotations

import argparse
import errno
import json
import os
import re
import stat
import sys
import tomllib
from pathlib import Path
from typing import Any, cast

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.render_claude_agents import (  # noqa: E402
    SUBAGENT_MODEL_KEY,
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
MARKER_LINE = re.compile(r"^[ \t]*(<!-- /?codex-only -->)[ \t]*$")
PRIVATE_SETTINGS_KEYS = frozenset({"autoMode"})
UNION_LISTS = frozenset(
    ("autoMode", key) for key in ("environment", "allow", "soft_deny", "hard_deny")
)
REDACTED = "<private overlay>"


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


def union_strings(existing: object, added: object, label: str) -> list[str]:
    """Keep existing entries first, then new ones, without exact duplicates."""
    if existing is None:
        existing = []
    if not isinstance(existing, list) or not isinstance(added, list):
        raise ValueError(f"{label} must be a list of strings")
    merged: list[str] = []
    for item in [*cast(list[object], existing), *cast(list[object], added)]:
        if not isinstance(item, str):
            raise ValueError(f"{label} must be a list of strings")
        if item not in merged:
            merged.append(item)
    return merged


def merge_managed(
    current: dict[str, Any], managed: dict[str, Any], path: tuple[str, ...] = ()
) -> dict[str, Any]:
    """Merge managed values into settings.

    Nested tables merge key by key. Lists in UNION_LISTS become an
    order-preserving union; other lists and scalars replace the current value.
    """
    merged = dict(current)
    for key, value in managed.items():
        key_path = (*path, key)
        existing = merged.get(key)
        if isinstance(value, dict):
            base = existing if isinstance(existing, dict) else {}
            merged[key] = merge_managed(
                cast(dict[str, Any], base), cast(dict[str, Any], value), key_path
            )
        elif key_path in UNION_LISTS:
            merged[key] = union_strings(existing, value, ".".join(key_path))
        else:
            merged[key] = value
    return merged


def parse_settings(original: str) -> dict[str, Any]:
    """Parse personal settings, or an empty table for an empty file."""
    parsed: object = json.loads(original) if original.strip() else {}
    settings = require_table(parsed, "personal settings")
    require_table(settings.get("env", {}), "personal settings env")
    return settings


def update_settings(
    settings: dict[str, Any],
    model: str,
    managed: dict[str, Any] | None = None,
    private: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Apply catalog values, then the private overlay, then the subagent model."""
    updated = merge_managed(settings, managed or {})
    updated = merge_managed(updated, private or {})
    return merge_managed(updated, {"env": {SUBAGENT_MODEL_KEY: model}})


def settings_text(
    original: str, settings: dict[str, Any], updated: dict[str, Any]
) -> str:
    """Keep the original bytes when nothing changes."""
    if updated == settings and original.strip():
        return original
    return json.dumps(updated, indent=2, ensure_ascii=False) + "\n"


def render_settings(
    original: str,
    model: str,
    managed: dict[str, Any] | None = None,
    private: dict[str, Any] | None = None,
) -> str:
    """Set the default subagent model, catalog values, and private values only."""
    settings = parse_settings(original)
    return settings_text(
        original, settings, update_settings(settings, model, managed, private)
    )


def load_private_settings(path: Path) -> dict[str, Any] | None:
    """Read the private settings overlay, or None when it does not exist.

    Error messages name the problem but never include overlay content.
    """
    if not path.is_absolute():
        raise ValueError("private settings overlay path must be absolute")
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    except OSError as error:
        if error.errno == errno.ELOOP:
            raise ValueError(
                f"private settings overlay must not be a symlink: {path}"
            ) from None
        raise
    try:
        status = os.fstat(descriptor)
        if not stat.S_ISREG(status.st_mode):
            raise ValueError(f"private settings overlay must be a regular file: {path}")
        mode = stat.S_IMODE(status.st_mode)
        if mode != 0o600:
            raise ValueError(
                f"private settings overlay must have mode 600, not {mode:o}: {path}"
            )
    except BaseException:
        os.close(descriptor)
        raise
    with os.fdopen(descriptor, "rb") as source:
        data = source.read()
    try:
        parsed: object = json.loads(data.decode("utf-8"))
    except ValueError:  # UnicodeDecodeError and JSONDecodeError
        raise ValueError(
            f"private settings overlay is not valid UTF-8 JSON: {path}"
        ) from None
    if not isinstance(parsed, dict):
        raise ValueError("private settings overlay must be a JSON object")
    overlay = cast(dict[str, Any], parsed)
    unknown = sorted(overlay.keys() - PRIVATE_SETTINGS_KEYS)
    if unknown:
        raise ValueError(
            "private settings overlay may contain only "
            f"{', '.join(sorted(PRIVATE_SETTINGS_KEYS))}; found {', '.join(unknown)}"
        )
    for key, value in overlay.items():
        table = require_table(value, f"private settings overlay {key}")
        for name, entries in table.items():
            if (key, name) in UNION_LISTS:
                _ = union_strings([], entries, f"private settings overlay {key}.{name}")
    return overlay


def redact(settings: dict[str, Any], private: dict[str, Any]) -> dict[str, Any]:
    """Replace each top-level key that the overlay sets with a placeholder."""
    return {
        key: REDACTED if key in private else value for key, value in settings.items()
    }


def overlay_summary(
    current: dict[str, Any],
    updated: dict[str, Any],
    private: dict[str, Any],
    path: tuple[str, ...] = (),
) -> list[str]:
    """Describe overlay effects by key path and entry count, without values."""
    lines: list[str] = []
    for key, value in private.items():
        key_path = (*path, key)
        before = current.get(key)
        after = updated.get(key)
        if isinstance(value, dict):
            lines.extend(
                overlay_summary(
                    cast(dict[str, Any], before if isinstance(before, dict) else {}),
                    cast(dict[str, Any], after if isinstance(after, dict) else {}),
                    cast(dict[str, Any], value),
                    key_path,
                )
            )
            continue
        label = ".".join(key_path)
        if isinstance(after, list):
            kept = cast(list[object], before) if isinstance(before, list) else []
            added = sum(item not in kept for item in cast(list[object], after))
            removed = len(kept) + added - len(cast(list[object], after))
            line = f"  {label}: {added} entr{'y' if added == 1 else 'ies'} to add"
            if removed:
                line += f", {removed} to remove"
            lines.append(line)
        else:
            lines.append(f"  {label}: {'changes' if before != after else 'unchanged'}")
    return lines


def default_subagent_model(catalog: dict[str, Any]) -> str:
    """Resolve the Claude model for the catalog's default subagent profile."""
    settings = claude_settings(catalog)
    defaults = require_table(catalog["defaults"], "defaults")
    classes = require_table(catalog["classes"], "classes")
    profile = defaults.get("subagent_profile")
    if not isinstance(profile, str) or profile not in classes:
        raise ValueError("catalog defaults.subagent_profile must name a class")
    capability = require_table(classes[profile], f"classes.{profile}").get("capability")
    if not isinstance(capability, str) or capability not in settings.models:
        raise ValueError(f"classes.{profile}.capability has no claude.models mapping")
    return settings.models[capability]


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
    _ = parser.add_argument(
        "--private-settings",
        type=Path,
        help="optional private settings overlay, merged after claude.settings",
    )
    arguments = parser.parse_args()
    try:
        catalog = load_catalog(cast(Path, arguments.catalog))
        settings = claude_settings(catalog)
        skills = exported_skills(REPO_ROOT, settings)
        claude_home = cast(Path, arguments.claude_home)
        output = cast(Path, arguments.output)
        private_path = cast(Path | None, arguments.private_settings)
        private = None if private_path is None else load_private_settings(private_path)
        output.mkdir(parents=True, exist_ok=True)
        guidance = render_guidance(
            read_text(cast(Path, arguments.guidance)), settings.terms, skills
        )
        claude_md = render_claude_md(read_text(claude_home / "CLAUDE.md"))
        original = read_text(claude_home / "settings.json")
        current = parse_settings(original)
        updated = update_settings(
            current, default_subagent_model(catalog), settings.settings, private
        )
        (output / "AGENTS.md").write_bytes(guidance.encode("utf-8"))
        (output / "CLAUDE.md").write_bytes(claude_md.encode("utf-8"))
        (output / "settings.json").write_bytes(
            settings_text(original, current, updated).encode("utf-8")
        )
        if private is not None:
            # Dry runs show these redacted files and the summary, never overlay values.
            for name, table in (("current", current), ("proposed", updated)):
                preview = json.dumps(
                    redact(table, private), indent=2, ensure_ascii=False
                )
                (output / f"settings.redacted-{name}.json").write_text(
                    preview + "\n", encoding="utf-8"
                )
            summary = overlay_summary(current, updated, private)
            (output / "settings.overlay-summary.txt").write_text(
                "".join(f"{line}\n" for line in summary), encoding="utf-8"
            )
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
