"""Check capacity profile rendering and specialist permission overrides."""

from __future__ import annotations

import tomllib
from pathlib import Path

import pytest

from scripts.render_codex_agents import AGENTS_DIRECTORY, CATALOG_PATH, render_catalog


def agent_data(rendered: dict[str, str], name: str) -> dict[str, object]:
    """Parse one rendered agent."""
    filename = name.replace("_", "-") + ".toml"
    return tomllib.loads(rendered[filename])


def test_generated_agents_match_catalog() -> None:
    """All classes and specialists use their catalog model and effort."""
    with CATALOG_PATH.open("rb") as catalog_file:
        catalog = tomllib.load(catalog_file)
    rendered = render_catalog(CATALOG_PATH)
    expected_names = set(catalog["classes"]) | set(catalog["specialists"])
    assert set(rendered) == {
        name.replace("_", "-") + ".toml" for name in expected_names
    }
    for filename, content in rendered.items():
        assert (AGENTS_DIRECTORY / filename).read_text(encoding="utf-8") == content

    for name, agent_class in catalog["classes"].items():
        data = agent_data(rendered, name)
        assert data["model"] == agent_class["model"]
        assert data["model_reasoning_effort"] == agent_class["model_reasoning_effort"]
        assert data["sandbox_mode"] == agent_class["sandbox_mode"]

    for name, specialist in catalog["specialists"].items():
        data = agent_data(rendered, name)
        agent_class = catalog["classes"][specialist["profile"]]
        assert data["model"] == agent_class["model"]
        assert data["model_reasoning_effort"] == agent_class["model_reasoning_effort"]
        assert data["sandbox_mode"] == specialist.get(
            "sandbox_mode", agent_class["sandbox_mode"]
        )

    assert agent_data(rendered, "citation_verifier")["sandbox_mode"] == "read-only"
    assert agent_data(rendered, "pr_lifecycle_reporter")["sandbox_mode"] == "read-only"
    assert agent_data(rendered, "pr_lifecycle_reporter")["approval_policy"] == "never"


def test_one_class_model_change_updates_its_specialist(tmp_path: Path) -> None:
    """A model upgrade propagates without changes to other classes."""
    original = render_catalog(CATALOG_PATH)
    with CATALOG_PATH.open("rb") as catalog_file:
        current = tomllib.load(catalog_file)["classes"]["lightweight_reviewer"]["model"]
    source = CATALOG_PATH.read_text(encoding="utf-8")
    catalog_path = tmp_path / "agent_catalog.toml"
    catalog_path.write_text(
        source.replace(f'model = "{current}"', f'model = "{current}-future"', 1),
        encoding="utf-8",
    )
    updated = render_catalog(catalog_path)

    assert agent_data(updated, "lightweight_reviewer")["model"] == f"{current}-future"
    assert agent_data(updated, "citation_verifier")["model"] == f"{current}-future"
    for name in (
        "lightweight_editor",
        "moderate_worker",
        "consultant",
        "pr_lifecycle_reporter",
    ):
        assert agent_data(updated, name)["model"] == agent_data(original, name)["model"]


def test_unknown_specialist_profile_is_rejected(tmp_path: Path) -> None:
    """Invalid catalog routing fails before agent files are written."""
    source = CATALOG_PATH.read_text(encoding="utf-8")
    catalog_path = tmp_path / "agent_catalog.toml"
    catalog_path.write_text(
        source.replace(
            'profile = "lightweight_reviewer"', 'profile = "missing_class"', 1
        ),
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="unknown class"):
        render_catalog(catalog_path)
