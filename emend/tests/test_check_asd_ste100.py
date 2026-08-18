from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path
from typing import Any

import pytest

SCRIPT_PATH = Path(__file__).parents[1] / "scripts" / "check_asd_ste100.py"
SPEC = importlib.util.spec_from_file_location("check_asd_ste100", SCRIPT_PATH)
assert SPEC is not None
assert SPEC.loader is not None
CHECKER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CHECKER
SPEC.loader.exec_module(CHECKER)


def sentence(word_count: int) -> str:
    return " ".join(f"word{index}" for index in range(word_count)) + "."


def rules(report: Any) -> list[str]:
    return [finding.rule for finding in report.findings]


def test_count_words_uses_asd_ste100_word_units() -> None:
    text = (
        "Install the oil-filter (item 12) at 25 mm from connector J1. "
        'Read "DO NOT OPEN THIS PANEL" now.'
    )

    assert CHECKER.count_words(text.split(". ", maxsplit=1)[0]) == 9
    assert CHECKER.count_words(text.split(". ", maxsplit=1)[1]) == 3


@pytest.mark.parametrize(
    ("document_type", "limit", "rule"),
    [("procedural", 20, "5.1"), ("descriptive", 25, "6.3")],
)
def test_sentence_limits_have_exact_boundaries(
    document_type: str, limit: int, rule: str
) -> None:
    passing = CHECKER.scan_text(
        sentence(limit), Path("sample.txt"), document_type, "text"
    )
    failing = CHECKER.scan_text(
        sentence(limit + 1), Path("sample.txt"), document_type, "text"
    )

    assert rule not in rules(passing)
    assert rules(failing) == [rule]
    assert failing.findings[0].severity == "error"


def test_descriptive_paragraph_limit_is_six_sentences() -> None:
    six_sentences = " ".join(["The unit is serviceable."] * 6)
    seven_sentences = " ".join(["The unit is serviceable."] * 7)

    passing = CHECKER.scan_text(
        six_sentences, Path("sample.txt"), "descriptive", "text"
    )
    failing = CHECKER.scan_text(
        seven_sentences, Path("sample.txt"), "descriptive", "text"
    )

    assert "6.6" not in rules(passing)
    assert rules(failing) == ["6.6"]


def test_markdown_list_items_are_separate_text_blocks() -> None:
    text = "\n".join(["- The unit is serviceable."] * 7)

    report = CHECKER.scan_text(text, Path("sample.md"), "descriptive", "markdown")

    assert "6.6" not in rules(report)


def test_mechanical_findings_include_source_locations() -> None:
    report = CHECKER.scan_text(
        "Use the pump.\nThe valve can't open; replace it.",
        Path("sample.txt"),
        "procedural",
        "text",
    )

    assert rules(report) == ["4.2", "8.1"]
    assert [(item.line, item.column) for item in report.findings] == [(2, 11), (2, 21)]


def test_typographic_apostrophe_contractions_are_checked() -> None:
    report = CHECKER.scan_text(
        "The valve can’t open.", Path("sample.txt"), "descriptive", "text"
    )

    assert rules(report) == ["4.2"]
    assert (report.findings[0].line, report.findings[0].column) == (1, 11)


def test_markdown_safe_zones_are_not_checked() -> None:
    text = """---
title: It can't run;
---
> The quoted text can't run;

```text
The code can't run;
```

The file contains `can't; running` text.
"""

    report = CHECKER.scan_text(text, Path("sample.md"), "descriptive", "markdown")

    assert report.findings == []
    assert report.skipped_regions == 4


def test_shorter_marker_does_not_close_markdown_fence() -> None:
    text = """````text
The code can't run;
```
The code can't run;
````
"""

    report = CHECKER.scan_text(text, Path("sample.md"), "descriptive", "markdown")

    assert report.findings == []
    assert report.skipped_regions == 1


def test_passive_voice_and_ing_forms_are_advisories() -> None:
    report = CHECKER.scan_text(
        "The pump is installed during testing.",
        Path("sample.txt"),
        "descriptive",
        "text",
    )

    assert rules(report) == ["3.6", "3.5"]
    assert {finding.severity for finding in report.findings} == {"advisory"}


def test_json_output_is_stable_and_disables_color(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    target = tmp_path / "sample.txt"
    target.write_text("The valve can't open; replace it.\n", encoding="utf-8")

    exit_code = CHECKER.main([str(target), "--format", "json", "--color", "always"])
    captured = capsys.readouterr()
    payload = json.loads(captured.out)

    assert exit_code == 1
    assert captured.err == ""
    assert "\x1b[" not in captured.out
    assert payload["status"] == "fail"
    assert payload["summary"] == {"advisories": 0, "errors": 2, "files": 1}
    assert [item["rule"] for item in payload["findings"]] == ["4.2", "8.1"]
    assert payload["unchecked_rules"]


def test_standard_input_and_strict_advisories(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(
        sys, "stdin", __import__("io").StringIO("The pump is installed.\n")
    )

    exit_code = CHECKER.main(["-", "--strict", "--format", "json"])
    payload = json.loads(capsys.readouterr().out)

    assert exit_code == 1
    assert payload["status"] == "warn"
    assert payload["strict"] is True
    assert payload["findings"][0]["rule"] == "3.6"


def test_quiet_and_verbose_text_modes(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    target = tmp_path / "sample.txt"
    target.write_text("The pump is installed.\n", encoding="utf-8")

    assert CHECKER.main([str(target), "--quiet", "--no-color"]) == 0
    quiet_output = capsys.readouterr().out
    assert quiet_output.startswith("WARN  check-asd-ste100")
    assert "Findings" not in quiet_output

    assert CHECKER.main([str(target), "--verbose", "--no-color"]) == 0
    verbose_output = capsys.readouterr().out
    assert "Findings" in verbose_output
    assert "Unchecked Rules" in verbose_output
    assert "Skipped regions:" in verbose_output


def test_no_color_overrides_always_color(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    target = tmp_path / "sample.txt"
    target.write_text("The unit is serviceable.\n", encoding="utf-8")

    assert CHECKER.main([str(target), "--color", "always"]) == 0
    assert "\x1b[" in capsys.readouterr().out

    assert CHECKER.main([str(target), "--color", "always", "--no-color"]) == 0
    assert "\x1b[" not in capsys.readouterr().out


def test_runtime_errors_use_stderr_and_exit_two(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    missing = tmp_path / "missing.txt"

    exit_code = CHECKER.main([str(missing)])
    captured = capsys.readouterr()

    assert exit_code == 2
    assert captured.out == ""
    assert captured.err.startswith("check-asd-ste100 failed:")


def test_findings_are_sorted_by_path_and_source_location(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    second = tmp_path / "b.txt"
    first = tmp_path / "a.txt"
    second.write_text("Use this; now.\n", encoding="utf-8")
    first.write_text("Don't use this.\n", encoding="utf-8")

    exit_code = CHECKER.main([str(second), str(first), "--format", "json"])
    payload = json.loads(capsys.readouterr().out)

    assert exit_code == 1
    assert [Path(item["path"]).name for item in payload["findings"]] == [
        "a.txt",
        "b.txt",
    ]


def test_invalid_verbosity_combination_exits_two() -> None:
    with pytest.raises(SystemExit, match="2"):
        CHECKER.main(["-", "--quiet", "--verbose"])
