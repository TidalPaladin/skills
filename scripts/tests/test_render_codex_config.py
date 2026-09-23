"""Check surgical updates to personal Codex agent settings."""

from __future__ import annotations

import tomllib

import pytest

from scripts.render_codex_agents import CATALOG_PATH, REPO_ROOT
from scripts.render_codex_config import desired_settings, render_personal_config


def test_defaults_follow_the_catalog_profile() -> None:
    """The personal default uses one class mapping from the catalog."""
    with CATALOG_PATH.open("rb") as catalog_file:
        catalog = tomllib.load(catalog_file)
    profile = catalog["defaults"]["subagent_profile"]
    agent_class = catalog["classes"][profile]
    minimum, model, effort = desired_settings(
        REPO_ROOT / ".codex" / "config.toml", CATALOG_PATH
    )
    assert minimum == 8
    assert model == agent_class["model"]
    assert effort == agent_class["model_reasoning_effort"]


def test_existing_config_preserves_other_fields_and_comments() -> None:
    """Only the managed values change, and a second render is identical."""
    original = """model = "gpt-5.6-sol" # primary

[agents]
max_threads = 12 # higher capacity
max_depth = 2 # preserve
default_subagent_model = "old#model" # preserve this comment
default_subagent_reasoning_effort = "medium" # preserve this too

[agents.reviewer]
description = "Personal reviewer"

[features]
apps = true
"""
    result = render_personal_config(original, 8, "gpt-6-luna", "xhigh")
    assert 'model = "gpt-5.6-sol" # primary' in result
    assert "max_threads = 12 # higher capacity" in result
    assert "max_depth = 2 # preserve" in result
    assert 'default_subagent_model = "gpt-6-luna" # preserve this comment' in result
    assert 'default_subagent_reasoning_effort = "xhigh" # preserve this too' in result
    assert '[agents.reviewer]\ndescription = "Personal reviewer"' in result
    assert "[features]\napps = true" in result
    assert render_personal_config(result, 8, "gpt-6-luna", "xhigh") == result


@pytest.mark.parametrize("header", ['["agents"]', "['agents']", '[ "agents" ]'])
def test_quoted_agents_header_preserves_other_fields(header: str) -> None:
    """Equivalent TOML headers accept managed updates without rewriting neighbors."""
    original = (
        'model = "gpt-5.6-sol"\n'
        f"{header}\n"
        "max_threads = 12 # keep the higher limit\n"
        'default_subagent_model = "old" # keep this comment\n'
        "[features]\napps = true\n"
    )
    result = render_personal_config(original, 8, "gpt-6-luna", "xhigh")
    assert f"{header}\n" in result
    assert 'model = "gpt-5.6-sol"\n' in result
    assert "max_threads = 12 # keep the higher limit\n" in result
    assert 'default_subagent_model = "gpt-6-luna" # keep this comment\n' in result
    assert "[features]\napps = true\n" in result
    assert (
        tomllib.loads(result)["agents"]["default_subagent_reasoning_effort"] == "xhigh"
    )


def test_missing_agents_section_preserves_line_endings() -> None:
    """Appending the managed section does not rewrite existing CRLF lines."""
    original = 'model = "gpt-5.6-sol"\r\n[features]\r\napps = true\r\n'
    result = render_personal_config(original, 8, "gpt-6-luna", "xhigh")
    assert result.startswith(original)
    assert "\r\n[agents]\r\nmax_threads = 8\r\n" in result
    assert '\r\ndefault_subagent_model = "gpt-6-luna"\r\n' in result


def test_current_capacity_alias_is_preserved() -> None:
    """An existing current capacity key stays the capacity key."""
    original = "[agents]\nmax_concurrent_threads_per_session = 3 # retain key\n"
    result = render_personal_config(original, 8, "gpt-6-luna", "xhigh")
    assert "max_concurrent_threads_per_session = 8 # retain key" in result
    assert "max_threads =" not in result


@pytest.mark.parametrize(
    "original",
    [
        "[agents]\nmax_threads = 0\n",
        "[agents]\nmax_threads = 8\nmax_concurrent_threads_per_session = 8\n",
        "[agents]\ndefault_subagent_model = 42\n",
        "model = [\n",
    ],
)
def test_invalid_personal_config_is_rejected(original: str) -> None:
    """Unsafe or ambiguous input fails before the personal file is changed."""
    with pytest.raises((ValueError, tomllib.TOMLDecodeError)):
        render_personal_config(original, 8, "gpt-6-luna", "xhigh")
