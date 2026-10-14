"""Check Claude guidance, CLAUDE.md, settings, and skill staging."""

from __future__ import annotations

import json
import os
import tomllib
from pathlib import Path
from typing import Any

import pytest

from scripts.render_claude_agents import claude_settings
from scripts.render_claude_config import (
    IMPORT_LINE,
    REDACTED,
    default_subagent_model,
    load_private_settings,
    overlay_summary,
    redact,
    render_claude_md,
    render_guidance,
    render_settings,
    strip_codex_only,
    update_settings,
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


def test_managed_env_merges_with_subagent_model() -> None:
    """Catalog env values and the subagent model both reach settings env."""
    original = json.dumps({"env": {"KEEP": "1"}})
    managed = {"env": {"WATCH": "1"}}
    rendered = render_settings(original, "sonnet", managed)
    assert json.loads(rendered)["env"] == {
        "KEEP": "1",
        "WATCH": "1",
        "CLAUDE_CODE_SUBAGENT_MODEL": "sonnet",
    }
    assert render_settings(rendered, "sonnet", managed) == rendered


def test_catalog_enables_plugin_dir_watch() -> None:
    """Desktop sessions reload mod edits without a restart."""
    settings = claude_settings(load_catalog(CATALOG_PATH))
    rendered = json.loads(render_settings("", "sonnet", settings.settings))
    assert rendered["env"]["CLAUDE_CODE_PLUGIN_DIR_WATCH"] == "1"


@pytest.mark.parametrize(
    ("env_table", "message"),
    [
        ('CLAUDE_CODE_SUBAGENT_MODEL = "opus"', "defaults.subagent_profile"),
        ("X = 1", "non-empty string"),
    ],
)
def test_catalog_env_rejects_invalid_values(
    tmp_path: Path, env_table: str, message: str
) -> None:
    """The sync owns the subagent model, and env values are strings."""
    source = CATALOG_PATH.read_text(encoding="utf-8")
    catalog_path = tmp_path / "agent_catalog.toml"
    catalog_path.write_text(
        source.replace(
            "[claude.settings.env]\n", f"[claude.settings.env]\n{env_table}\n"
        ),
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match=message):
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
    codex_model = catalog["classes"][profile]["capability"]
    expected = catalog["claude"]["models"][codex_model]
    assert default_subagent_model(load_catalog(CATALOG_PATH)) == expected


PRIVATE_VALUE = "**Organization**: Example private detail"


def write_overlay(path: Path, overlay: object, mode: int = 0o600) -> Path:
    path.write_text(json.dumps(overlay), encoding="utf-8")
    path.chmod(mode)
    return path


@pytest.mark.parametrize("key", ["environment", "allow", "soft_deny", "hard_deny"])
def test_auto_mode_lists_union_with_local_entries(key: str) -> None:
    """Local entries stay first and in order; new entries follow once each."""
    original = json.dumps({"autoMode": {key: ["local", "$defaults", "local", "b"]}})
    private = {"autoMode": {key: ["$defaults", "new", "b", "new"]}}
    rendered = render_settings(original, "sonnet", {}, private)
    assert json.loads(rendered)["autoMode"][key] == ["local", "$defaults", "b", "new"]
    assert render_settings(rendered, "sonnet", {}, private) == rendered


def test_auto_mode_union_adds_one_defaults_entry_where_it_appears() -> None:
    """A new $defaults keeps its overlay position after the local entries."""
    original = json.dumps({"autoMode": {"environment": ["local"]}})
    private = {"autoMode": {"environment": ["$defaults", "org"]}}
    rendered = json.loads(render_settings(original, "sonnet", {}, private))
    assert rendered["autoMode"]["environment"] == ["local", "$defaults", "org"]


def test_catalog_auto_mode_lists_also_union() -> None:
    """Catalog autoMode rules do not wipe local rules."""
    original = json.dumps({"autoMode": {"allow": ["local"]}})
    managed = {"autoMode": {"allow": ["catalog"]}}
    private = {"autoMode": {"allow": ["private"]}}
    rendered = json.loads(render_settings(original, "sonnet", managed, private))
    assert rendered["autoMode"]["allow"] == ["local", "catalog", "private"]


def test_other_lists_are_replaced() -> None:
    """Lists outside autoMode keep replace semantics."""
    original = json.dumps({"permissions": {"allow": ["local"]}})
    managed = {"permissions": {"allow": ["catalog"]}}
    rendered = json.loads(render_settings(original, "sonnet", managed))
    assert rendered["permissions"]["allow"] == ["catalog"]


@pytest.mark.parametrize(
    "auto_mode", [{"allow": "local"}, {"allow": ["local", 1]}, {"allow": {}}]
)
def test_invalid_local_auto_mode_lists_are_rejected(auto_mode: dict[str, Any]) -> None:
    """A union never replaces a malformed local list."""
    original = json.dumps({"autoMode": auto_mode})
    with pytest.raises(ValueError, match="autoMode.allow must be a list of strings"):
        _ = render_settings(original, "sonnet", {}, {"autoMode": {"allow": ["new"]}})


def test_overlay_merge_preserves_unrelated_settings() -> None:
    """The overlay changes only its own entries."""
    original = json.dumps(
        {
            "editorMode": "vim",
            "env": {"KEEP": "1"},
            "hooks": {"Stop": []},
            "permissions": {"allow": ["Bash(ls)"]},
            "autoMode": {"allow": ["local"], "other": True},
        }
    )
    private = {"autoMode": {"allow": ["private"]}}
    rendered = json.loads(render_settings(original, "sonnet", {}, private))
    assert rendered == {
        "editorMode": "vim",
        "env": {"KEEP": "1", "CLAUDE_CODE_SUBAGENT_MODEL": "sonnet"},
        "hooks": {"Stop": []},
        "permissions": {"allow": ["Bash(ls)"]},
        "autoMode": {"allow": ["local", "private"], "other": True},
    }


def test_overlay_without_changes_keeps_original_bytes() -> None:
    """A no-op sync returns the file byte for byte, including its layout."""
    original = (
        '{"env":{"CLAUDE_CODE_SUBAGENT_MODEL":"sonnet"},'
        '"autoMode":{"allow":["$defaults","x"]}}'
    )
    private = {"autoMode": {"allow": ["x", "$defaults"]}}
    assert render_settings(original, "sonnet", {}, private) == original


def test_missing_overlay_is_a_no_op(tmp_path: Path) -> None:
    """An absent overlay loads as None and leaves settings unchanged."""
    assert load_private_settings(tmp_path / "missing.json") is None
    original = json.dumps({"env": {"CLAUDE_CODE_SUBAGENT_MODEL": "sonnet"}})
    assert render_settings(original, "sonnet", {}, None) == original


def test_valid_overlay_loads(tmp_path: Path) -> None:
    overlay = {"autoMode": {"allow": ["$defaults", PRIVATE_VALUE]}}
    path = write_overlay(tmp_path / "private.json", overlay)
    assert load_private_settings(path) == overlay


@pytest.mark.parametrize("mode", [0o644, 0o640, 0o400, 0o700])
def test_overlay_with_wrong_mode_is_rejected(tmp_path: Path, mode: int) -> None:
    path = write_overlay(tmp_path / "private.json", {"autoMode": {}}, mode)
    with pytest.raises(ValueError, match="must have mode 600"):
        _ = load_private_settings(path)


@pytest.mark.parametrize("dangling", [False, True])
def test_overlay_symlink_is_rejected(tmp_path: Path, dangling: bool) -> None:
    target = tmp_path / "target.json"
    if not dangling:
        _ = write_overlay(target, {"autoMode": {}})
    link = tmp_path / "private.json"
    link.symlink_to(target)
    with pytest.raises(ValueError, match="must not be a symlink"):
        _ = load_private_settings(link)


def test_overlay_directory_is_rejected(tmp_path: Path) -> None:
    path = tmp_path / "private.json"
    path.mkdir(mode=0o700)
    with pytest.raises(ValueError, match="must be a regular file"):
        _ = load_private_settings(path)


@pytest.mark.parametrize(
    ("overlay", "message"),
    [
        ([PRIVATE_VALUE], "must be a JSON object"),
        (PRIVATE_VALUE, "must be a JSON object"),
        ({"permissions": {"allow": [PRIVATE_VALUE]}}, "found permissions"),
        ({"autoMode": [PRIVATE_VALUE]}, "autoMode must be"),
        ({"autoMode": {"allow": PRIVATE_VALUE}}, "list of strings"),
        ({"autoMode": {"allow": [PRIVATE_VALUE, 1]}}, "list of strings"),
    ],
)
def test_invalid_overlay_is_rejected_without_values(
    tmp_path: Path, overlay: object, message: str
) -> None:
    """Rejections name the problem and never echo overlay content."""
    path = write_overlay(tmp_path / "private.json", overlay)
    with pytest.raises((TypeError, ValueError), match=message) as error:
        _ = load_private_settings(path)
    assert PRIVATE_VALUE not in str(error.value)


def test_malformed_overlay_json_is_rejected_without_values(tmp_path: Path) -> None:
    path = tmp_path / "private.json"
    path.write_text(f'{{"autoMode": "{PRIVATE_VALUE}', encoding="utf-8")
    path.chmod(0o600)
    with pytest.raises(ValueError, match="not valid UTF-8 JSON") as error:
        _ = load_private_settings(path)
    assert PRIVATE_VALUE not in str(error.value)


def test_relative_overlay_path_is_rejected() -> None:
    with pytest.raises(ValueError, match="must be absolute"):
        _ = load_private_settings(Path("private.json"))


def test_overlay_preview_hides_private_values() -> None:
    """The redacted settings and the summary show keys and counts only."""
    current = {"editorMode": "vim", "autoMode": {"allow": [PRIVATE_VALUE, "local"]}}
    private = {
        "autoMode": {
            "allow": ["$defaults", PRIVATE_VALUE],
            "environment": [f"{PRIVATE_VALUE} 2"],
        }
    }
    updated = update_settings(current, "sonnet", {}, private)
    for table in (current, updated):
        preview = json.dumps(redact(table, private))
        assert PRIVATE_VALUE not in preview
        assert REDACTED in preview
    summary = overlay_summary(current, updated, private)
    assert summary == [
        "  autoMode.allow: 1 entry to add",
        "  autoMode.environment: 1 entry to add",
    ]
    assert PRIVATE_VALUE not in "".join(summary)


def test_overlay_summary_counts_removed_duplicates() -> None:
    current = {"autoMode": {"allow": ["a", "a"]}}
    private = {"autoMode": {"allow": ["b"]}}
    updated = update_settings(current, "sonnet", {}, private)
    assert overlay_summary(current, updated, private) == [
        "  autoMode.allow: 1 entry to add, 1 to remove"
    ]


def test_overlay_file_mode_check_ignores_umask(tmp_path: Path) -> None:
    """The check reads the file's own mode, not the creation default."""
    previous = os.umask(0o077)
    try:
        path = write_overlay(tmp_path / "private.json", {"autoMode": {}})
    finally:
        _ = os.umask(previous)
    assert load_private_settings(path) == {"autoMode": {}}


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
