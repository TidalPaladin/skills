"""Check capacity profile rendering and specialist permission overrides."""

from __future__ import annotations

import tomllib
from pathlib import Path

import pytest

from scripts.render_codex_agents import CATALOG_PATH, render_catalog


def agent_data(rendered: dict[str, str], name: str) -> dict[str, object]:
    """Parse one rendered agent."""
    filename = name.replace("_", "-") + ".toml"
    return tomllib.loads(rendered[filename])


MODELS = {"efficient": "gpt-6-luna", "balanced": "gpt-6-sol", "frontier": "gpt-6-astra"}


def test_generated_agents_match_catalog() -> None:
    """All classes and specialists use their catalog model and effort."""
    with CATALOG_PATH.open("rb") as catalog_file:
        catalog = tomllib.load(catalog_file)
    rendered = render_catalog(CATALOG_PATH, MODELS)
    expected_names = set(catalog["classes"]) | set(catalog["specialists"])
    assert set(rendered) == {
        name.replace("_", "-") + ".toml" for name in expected_names
    }

    for name, agent_class in catalog["classes"].items():
        data = agent_data(rendered, name)
        assert data["model"] == MODELS[agent_class["capability"]]
        assert data["model_reasoning_effort"] == agent_class["model_reasoning_effort"]
        assert data["sandbox_mode"] == agent_class["sandbox_mode"]

    for name, specialist in catalog["specialists"].items():
        data = agent_data(rendered, name)
        agent_class = catalog["classes"][specialist["profile"]]
        assert data["model"] == MODELS[agent_class["capability"]]
        assert data["model_reasoning_effort"] == agent_class["model_reasoning_effort"]
        assert data["sandbox_mode"] == specialist.get(
            "sandbox_mode", agent_class["sandbox_mode"]
        )

    assert agent_data(rendered, "citation_verifier")["sandbox_mode"] == "read-only"
    assert agent_data(rendered, "pr_lifecycle_reporter")["sandbox_mode"] == "read-only"
    assert agent_data(rendered, "pr_lifecycle_reporter")["approval_policy"] == "never"


def test_family_upgrade_changes_only_balanced_agents() -> None:
    """A new model list upgrades installed agents without editing the catalog."""
    original = render_catalog(CATALOG_PATH, MODELS)
    for version in ("6.1", "7"):
        updated = render_catalog(
            CATALOG_PATH, {**MODELS, "balanced": f"gpt-{version}-sol"}
        )
        assert agent_data(updated, "moderate_worker")["model"] == f"gpt-{version}-sol"
        for name in (
            "lightweight_reviewer",
            "lightweight_editor",
            "citation_verifier",
            "pr_lifecycle_reporter",
            "consultant",
        ):
            assert (
                updated[name.replace("_", "-") + ".toml"]
                == original[name.replace("_", "-") + ".toml"]
            )


def test_efficient_upgrade_reaches_specialists() -> None:
    updated = render_catalog(CATALOG_PATH, {**MODELS, "efficient": "gpt-7-luna"})
    for name in (
        "lightweight_reviewer",
        "lightweight_editor",
        "citation_verifier",
        "pr_lifecycle_reporter",
    ):
        assert agent_data(updated, name)["model"] == "gpt-7-luna"


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
        render_catalog(catalog_path, MODELS)
