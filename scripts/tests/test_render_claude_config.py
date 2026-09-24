"""Check Claude guidance, CLAUDE.md, settings, and skill staging."""

from __future__ import annotations

import json
import tomllib
from pathlib import Path

import pytest

from scripts.render_claude_agents import claude_settings
from scripts.render_claude_config import (
    IMPORT_LINE,
    default_subagent_model,
    render_claude_md,
    render_guidance,
    render_settings,
    strip_codex_only,
)
from scripts.render_codex_agents import CATALOG_PATH, REPO_ROOT, load_catalog
from scripts.stage_claude_skills import add_disable_field, stage_skill


def test_codex_only_blocks_are_removed() -> None:
    """Marker lines and their content disappear; other text stays."""
    source = "a\n<!-- codex-only -->\nb\n<!-- /codex-only -->\nc\n"
    assert strip_codex_only(source) == "a\nc\n"


@pytest.mark.parametrize(
    "source",
    [
        "<!-- codex-only -->\nb\n",
        "<!-- /codex-only -->\n",
        "<!-- codex-only -->\n<!-- codex-only -->\n<!-- /codex-only -->\n",
        "text <!-- codex-only -->\n<!-- /codex-only -->\n",
    ],
)
def test_malformed_codex_only_markers_are_rejected(source: str) -> None:
    """Unbalanced, nested, or inline markers fail the render."""
    with pytest.raises(ValueError):
        strip_codex_only(source)


def test_root_guidance_renders_for_claude() -> None:
    """The exported guidance has Claude families and no Codex-only workflow."""
    guidance = (REPO_ROOT / "AGENTS.md").read_text(encoding="utf-8")
    rendered = render_guidance(
        guidance,
        {"Luna": "Sonnet", "Sol": "Opus", "Astra": "Fable"},
        frozenset({"emend"}),
    )
    assert "notify-wake" not in rendered
    assert "codex-only" not in rendered
    assert "Fable primary agents do not use `consultant`." in rendered
    assert "`/emend`" in rendered


@pytest.mark.parametrize(
    ("original", "expected"),
    [
        ("", f"{IMPORT_LINE}\n"),
        ("# Mine\n", f"# Mine\n\n{IMPORT_LINE}\n"),
        ("# Mine", f"# Mine\n\n{IMPORT_LINE}\n"),
        ("# Mine\r\n", f"# Mine\r\n\r\n{IMPORT_LINE}\r\n"),
        (f"{IMPORT_LINE}\n# Mine\n", f"{IMPORT_LINE}\n# Mine\n"),
    ],
)
def test_claude_md_import_is_added_once(original: str, expected: str) -> None:
    """The import is appended once and a second render is identical."""
    rendered = render_claude_md(original)
    assert rendered == expected
    assert render_claude_md(rendered) == rendered


def test_settings_preserve_other_fields() -> None:
    """Only the managed env key changes, and a second render is identical."""
    original = json.dumps({"editorMode": "vim", "env": {"KEEP": "1"}, "hooks": {}})
    rendered = render_settings(original, "sonnet")
    assert json.loads(rendered) == {
        "editorMode": "vim",
        "env": {"KEEP": "1", "CLAUDE_CODE_SUBAGENT_MODEL": "sonnet"},
        "hooks": {},
    }
    assert render_settings(rendered, "sonnet") == rendered


def test_managed_settings_merge_nested_tables() -> None:
    """Managed values override theirs; sibling keys in the same table stay."""
    original = json.dumps(
        {"attribution": {"commit": "Co-Authored-By: X", "sessionUrl": False}}
    )
    managed = {"attribution": {"commit": "", "pr": ""}}
    rendered = render_settings(original, "sonnet", managed)
    assert json.loads(rendered)["attribution"] == {
        "commit": "",
        "pr": "",
        "sessionUrl": False,
    }
    assert render_settings(rendered, "sonnet", managed) == rendered


def test_catalog_disables_attribution() -> None:
    """The catalog removes the commit trailer and PR footer."""
    settings = claude_settings(load_catalog(CATALOG_PATH))
    rendered = json.loads(render_settings("", "sonnet", settings.settings))
    assert rendered["attribution"] == {"commit": "", "pr": ""}


def test_catalog_settings_cannot_manage_env(tmp_path: Path) -> None:
    """The env table stays under sync control."""
    source = CATALOG_PATH.read_text(encoding="utf-8")
    catalog_path = tmp_path / "agent_catalog.toml"
    catalog_path.write_text(
        source.replace(
            "[claude.settings.attribution]",
            '[claude.settings.env]\nX = "1"\n\n[claude.settings.attribution]',
        ),
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="must not set env"):
        claude_settings(load_catalog(catalog_path))


def test_missing_settings_are_created() -> None:
    """An absent settings file gets only the managed key."""
    assert json.loads(render_settings("", "opus")) == {
        "env": {"CLAUDE_CODE_SUBAGENT_MODEL": "opus"}
    }


@pytest.mark.parametrize("original", ["[]", '{"env": []}', "{"])
def test_invalid_settings_are_rejected(original: str) -> None:
    """Malformed settings fail instead of being overwritten."""
    with pytest.raises((TypeError, ValueError)):
        render_settings(original, "sonnet")


def test_default_subagent_model_follows_catalog_profile() -> None:
    """The default subagent model is the mapped model of the default class."""
    with CATALOG_PATH.open("rb") as catalog_file:
        catalog = tomllib.load(catalog_file)
    profile = catalog["defaults"]["subagent_profile"]
    codex_model = catalog["classes"][profile]["model"]
    expected = catalog["claude"]["models"][codex_model]
    assert default_subagent_model(load_catalog(CATALOG_PATH)) == expected


def write_skill(root: Path, interface: str | None) -> Path:
    skill = root / "example"
    skill.mkdir()
    (skill / "SKILL.md").write_text(
        "---\nname: example\ndescription: Example.\n---\n\n# Example\n",
        encoding="utf-8",
    )
    if interface is not None:
        (skill / "agents").mkdir()
        (skill / "agents" / "openai.yaml").write_text(interface, encoding="utf-8")
    return skill


def test_explicit_only_policy_becomes_claude_field(tmp_path: Path) -> None:
    """Codex explicit-only policy maps to disable-model-invocation."""
    skill = write_skill(
        tmp_path,
        "interface:\n  display_name: X\npolicy:\n  allow_implicit_invocation: false\n",
    )
    stage_skill(skill)
    text = (skill / "SKILL.md").read_text(encoding="utf-8")
    assert text.startswith(
        "---\nname: example\ndescription: Example.\ndisable-model-invocation: true\n---\n"
    )
    assert not (skill / "agents").exists()


def test_default_policy_leaves_skill_unchanged(tmp_path: Path) -> None:
    """Skills without the policy only lose the Codex interface file."""
    skill = write_skill(tmp_path, "interface:\n  display_name: X\n")
    before = (skill / "SKILL.md").read_text(encoding="utf-8")
    stage_skill(skill)
    assert (skill / "SKILL.md").read_text(encoding="utf-8") == before
    assert not (skill / "agents").exists()


def test_existing_disable_field_is_not_duplicated() -> None:
    """An overlay that already sets the field stays unchanged."""
    text = "---\nname: x\ndisable-model-invocation: true\n---\nbody\n"
    assert add_disable_field(text) == text


@pytest.mark.parametrize("text", ["no frontmatter\n", "---\nname: x\n"])
def test_malformed_skill_frontmatter_is_rejected(text: str) -> None:
    with pytest.raises(ValueError):
        add_disable_field(text)
