"""Check Claude subagent rendering from the shared capacity catalog."""

from __future__ import annotations

import tomllib
from pathlib import Path

import pytest

from scripts.render_claude_agents import (
    AGENTS_DIRECTORY,
    claude_settings,
    exported_skills,
    render_catalog,
    transform_text,
)
from scripts.render_codex_agents import CATALOG_PATH, REPO_ROOT
from scripts.validate_claude_agents import parse_frontmatter, validate_agent


def frontmatter(rendered: dict[str, str], name: str) -> dict[str, str]:
    """Parse one rendered agent's frontmatter."""
    return parse_frontmatter(rendered[name.replace("_", "-") + ".md"])


def test_generated_agents_match_catalog() -> None:
    """Committed agents match the catalog and use mapped Claude models."""
    with CATALOG_PATH.open("rb") as catalog_file:
        catalog = tomllib.load(catalog_file)
    rendered = render_catalog(CATALOG_PATH)
    for filename, content in rendered.items():
        assert (AGENTS_DIRECTORY / filename).read_text(encoding="utf-8") == content
    assert {path.name for path in AGENTS_DIRECTORY.glob("*.md")} == set(rendered)

    models = catalog["claude"]["models"]
    for name, agent_class in catalog["classes"].items():
        fields = frontmatter(rendered, name)
        assert fields["name"] == name
        assert fields["model"] == models[agent_class["model"]]
        assert fields["effort"] == agent_class["model_reasoning_effort"]
    for name, specialist in catalog["specialists"].items():
        agent_class = catalog["classes"][specialist["profile"]]
        assert frontmatter(rendered, name)["model"] == models[agent_class["model"]]


def test_generated_agents_pass_validation() -> None:
    """The sync validator accepts every committed agent."""
    for path in AGENTS_DIRECTORY.glob("*.md"):
        assert validate_agent(path) == []


def test_read_only_agents_deny_edit_tools() -> None:
    """Read-only sandbox settings, including specialist overrides, deny edits."""
    rendered = render_catalog(CATALOG_PATH)
    for name in ("lightweight_reviewer", "consultant", "pr_lifecycle_reporter"):
        assert frontmatter(rendered, name)["disallowedTools"] == (
            "Edit, Write, NotebookEdit"
        )
    for name in ("lightweight_editor", "moderate_worker"):
        assert "disallowedTools" not in frontmatter(rendered, name)


def test_family_terms_are_replaced_without_touching_codex_reviews() -> None:
    """Model families change; references to the Codex review bot stay."""
    rendered = render_catalog(CATALOG_PATH)
    consultant = rendered["consultant.md"]
    assert "If the caller is Fable, decline" in consultant
    for term in ("Luna", "Sol ", "Astra"):
        assert term not in consultant
    assert "completed public Codex review" in rendered["pr-lifecycle-reporter.md"]


def test_unmapped_model_is_rejected(tmp_path: Path) -> None:
    """A Codex model upgrade without a Claude mapping fails the render."""
    source = CATALOG_PATH.read_text(encoding="utf-8")
    catalog_path = tmp_path / "agent_catalog.toml"
    catalog_path.write_text(
        source.replace('model = "gpt-6-sol"', 'model = "gpt-7-sol"', 1),
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="no claude.models mapping"):
        render_catalog(catalog_path)


def test_invalid_claude_model_is_rejected(tmp_path: Path) -> None:
    """Mappings accept only Claude Code model aliases."""
    source = CATALOG_PATH.read_text(encoding="utf-8")
    catalog_path = tmp_path / "agent_catalog.toml"
    catalog_path.write_text(
        source.replace('"gpt-6-sol" = "opus"', '"gpt-6-sol" = "gpt-6-sol"', 1),
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="must be one of"):
        render_catalog(catalog_path)


def test_unknown_excluded_skill_is_rejected() -> None:
    """A stale exclude entry fails instead of silently doing nothing."""
    with CATALOG_PATH.open("rb") as catalog_file:
        catalog = tomllib.load(catalog_file)
    catalog["claude"]["exclude_skills"].append("missing-skill")
    with pytest.raises(ValueError, match="unknown skills"):
        exported_skills(REPO_ROOT, claude_settings(catalog))


def test_exported_skills_drop_excludes_and_keep_overlays() -> None:
    """Excluded skills are absent; overlaid skills remain exported."""
    with CATALOG_PATH.open("rb") as catalog_file:
        settings = claude_settings(tomllib.load(catalog_file))
    skills = exported_skills(REPO_ROOT, settings)
    assert "goal-mode" not in skills
    assert "notify-wake" not in skills
    assert {"review-fix-loop", "emend", "citation-verifier"} <= skills


def test_transform_rewrites_only_exported_skill_references() -> None:
    """Exported skills become slash commands; other dollar words stay."""
    text = "Sol and Solution use $emend, $goal-mode, and $HOME."
    result = transform_text(text, {"Sol": "Opus"}, frozenset({"emend"}))
    assert result == "Opus and Solution use /emend, $goal-mode, and $HOME."
