from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import subprocess
import sys
import zipfile
from pathlib import Path
from types import ModuleType

import pytest

SCRIPT = Path(__file__).parents[1] / "cognidox_office_form.py"


def _load_form_module() -> ModuleType:
    specification = importlib.util.spec_from_file_location(
        "cognidox_office_form", SCRIPT
    )
    assert specification is not None and specification.loader is not None
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


FORM_MODULE = _load_form_module()


def _write_docx(path: Path, body: str) -> None:
    content_types = """<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="xml" ContentType="application/xml"/>
</Types>"""
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("[Content_Types].xml", content_types)
        archive.writestr("word/document.xml", body)
        archive.writestr("word/styles.xml", "<styles>preserve-me</styles>")


def _write_xlsx(path: Path, text: str) -> None:
    content_types = """<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="xml" ContentType="application/xml"/>
</Types>"""
    shared_strings = f"""<?xml version="1.0" encoding="UTF-8"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <si><r><t>{text[:8]}</t></r><r><t>{text[8:]}</t></r></si>
</sst>"""
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("[Content_Types].xml", content_types)
        archive.writestr("xl/sharedStrings.xml", shared_strings)
        archive.writestr("xl/styles.xml", "<styles>preserve-me</styles>")


def _run(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    stdout = io.StringIO()
    stderr = io.StringIO()
    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
        return_code = FORM_MODULE.main(list(args))
    result = subprocess.CompletedProcess(
        [sys.executable, str(SCRIPT), *args],
        return_code,
        stdout.getvalue(),
        stderr.getvalue(),
    )
    if check and return_code:
        raise subprocess.CalledProcessError(
            return_code,
            result.args,
            output=result.stdout,
            stderr=result.stderr,
        )
    return result


def test_inspect_and_fill_docx_split_merge_field(tmp_path: Path) -> None:
    source = tmp_path / "source.docx"
    output = tmp_path / "filled.docx"
    values = tmp_path / "values.json"
    document = """<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body><w:p>
  <w:r><w:fldChar w:fldCharType="begin"/></w:r>
  <w:r><w:instrText> MERGEFIELD [form.text</w:instrText></w:r>
  <w:r><w:instrText>1] \\* MERGEFORMAT </w:instrText></w:r>
  <w:r><w:fldChar w:fldCharType="separate"/></w:r>
  <w:r><w:t>«[form.text1]»</w:t></w:r>
  <w:r><w:fldChar w:fldCharType="end"/></w:r>
</w:p></w:body></w:document>"""
    _write_docx(source, document)
    values.write_text(json.dumps({"text1": "Alpha\nBeta"}), encoding="utf-8")

    inspected = _run("inspect", str(source), "--format", "json")
    manifest = json.loads(inspected.stdout)
    assert manifest == {
        "fields": [{"id": "text1", "required": True, "type": "text"}],
        "format": "docx",
    }

    _run("fill", str(source), "--values", str(values), "--output", str(output))
    with zipfile.ZipFile(output) as archive:
        filled = archive.read("word/document.xml").decode()
        assert "Alpha" in filled
        assert "Beta" in filled
        assert "MERGEFIELD" not in filled
        assert archive.read("word/styles.xml") == b"<styles>preserve-me</styles>"


def test_inspect_text_output_is_human_readable(tmp_path: Path) -> None:
    source = tmp_path / "source.xlsx"
    _write_xlsx(source, "[form.text1]")

    result = _run("inspect", str(source))

    assert "text1\ttext\trequired=true" in result.stdout
    assert "format: xlsx" in result.stdout


def test_fill_docx_simple_merge_field(tmp_path: Path) -> None:
    source = tmp_path / "simple.docx"
    output = tmp_path / "filled.docx"
    values = tmp_path / "values.json"
    document = """<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body><w:p><w:fldSimple w:instr=" MERGEFIELD [form.text1] "><w:r><w:t>[form.text1]</w:t></w:r>
</w:fldSimple></w:p></w:body></w:document>"""
    _write_docx(source, document)
    values.write_text(json.dumps({"text1": "Simple value"}), encoding="utf-8")

    _run("fill", str(source), "--values", str(values), "--output", str(output))

    with zipfile.ZipFile(output) as archive:
        filled = archive.read("word/document.xml").decode()
    assert "Simple value" in filled
    assert "fldSimple" not in filled


def test_author_and_fill_xlsx_split_marker(tmp_path: Path) -> None:
    source = tmp_path / "source.xlsx"
    authored = tmp_path / "authored.xlsx"
    filled = tmp_path / "filled.xlsx"
    manifest = tmp_path / "manifest.json"
    values = tmp_path / "values.json"
    _write_xlsx(source, "{{date7}}")
    manifest.write_text(
        json.dumps(
            {
                "fields": [
                    {
                        "id": "date7",
                        "label": "Current Date",
                        "required": True,
                        "type": "date",
                    }
                ]
            }
        ),
        encoding="utf-8",
    )
    values.write_text(json.dumps({"date7": "2026-08-25"}), encoding="utf-8")

    _run("author", str(source), "--manifest", str(manifest), "--output", str(authored))
    inspected = json.loads(_run("inspect", str(authored), "--format", "json").stdout)
    assert inspected["fields"] == [{"id": "date7", "required": True, "type": "date"}]
    _run("fill", str(authored), "--values", str(values), "--output", str(filled))
    with zipfile.ZipFile(filled) as archive:
        assert "2026-08-25" in archive.read("xl/sharedStrings.xml").decode()
        assert archive.read("xl/styles.xml") == b"<styles>preserve-me</styles>"


def test_fill_uses_manifest_schema_for_optional_nonprefixed_date(
    tmp_path: Path,
) -> None:
    source = tmp_path / "source.docx"
    output = tmp_path / "filled.docx"
    manifest = tmp_path / "manifest.json"
    values = tmp_path / "values.json"
    document = """<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body><w:p><w:r><w:t>[form.completion]</w:t></w:r></w:p></w:body></w:document>"""
    _write_docx(source, document)
    manifest.write_text(
        json.dumps(
            {
                "fields": [
                    {
                        "id": "completion",
                        "label": "Completion date",
                        "required": False,
                        "type": "date",
                    }
                ]
            }
        ),
        encoding="utf-8",
    )
    values.write_text("{}", encoding="utf-8")

    _run(
        "fill",
        str(source),
        "--manifest",
        str(manifest),
        "--values",
        str(values),
        "--output",
        str(output),
    )

    with zipfile.ZipFile(output) as archive:
        assert "[form.completion]" not in archive.read("word/document.xml").decode()

    invalid_output = tmp_path / "invalid.docx"
    values.write_text(json.dumps({"completion": "08/25/2026"}), encoding="utf-8")
    result = _run(
        "fill",
        str(source),
        "--manifest",
        str(manifest),
        "--values",
        str(values),
        "--output",
        str(invalid_output),
        check=False,
    )
    assert result.returncode == 1
    assert "ISO date" in result.stderr


def test_fill_preserves_suffix_formatting_for_split_marker(tmp_path: Path) -> None:
    source = tmp_path / "source.docx"
    output = tmp_path / "filled.docx"
    values = tmp_path / "values.json"
    document = """<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Before [form.na</w:t></w:r><w:r><w:rPr><w:i/></w:rPr><w:t>me] after</w:t></w:r></w:p></w:body></w:document>"""
    _write_docx(source, document)
    values.write_text(json.dumps({"name": "X"}), encoding="utf-8")

    _run("fill", str(source), "--values", str(values), "--output", str(output))

    with zipfile.ZipFile(output) as archive:
        root = FORM_MODULE.ET.fromstring(archive.read("word/document.xml"))
    runs = list(root.iter(FORM_MODULE.WORD_RUN))
    assert "".join(runs[0].itertext()) == "Before X"
    assert "".join(runs[1].itertext()) == " after"
    bold_properties = runs[0].find(FORM_MODULE.WORD_RUN_PROPERTIES)
    italic_properties = runs[1].find(FORM_MODULE.WORD_RUN_PROPERTIES)
    assert bold_properties is not None
    assert italic_properties is not None
    assert bold_properties.find(f"{{{FORM_MODULE.WORD_NAMESPACE}}}b") is not None
    assert italic_properties.find(f"{{{FORM_MODULE.WORD_NAMESPACE}}}i") is not None


def test_fill_plain_docx_multiline_value_uses_word_break(tmp_path: Path) -> None:
    source = tmp_path / "source.docx"
    output = tmp_path / "filled.docx"
    values = tmp_path / "values.json"
    document = """<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body><w:p><w:r><w:t>Before [form.textarea.notes] after</w:t></w:r></w:p></w:body></w:document>"""
    _write_docx(source, document)
    values.write_text(json.dumps({"textarea.notes": "Alpha\nBeta"}), encoding="utf-8")

    _run("fill", str(source), "--values", str(values), "--output", str(output))

    with zipfile.ZipFile(output) as archive:
        root = FORM_MODULE.ET.fromstring(archive.read("word/document.xml"))
    run = next(root.iter(FORM_MODULE.WORD_RUN))
    assert [node.text for node in run.iter(FORM_MODULE.WORD_TEXT)] == [
        "Before Alpha",
        "Beta after",
    ]
    assert len(list(run.iter(FORM_MODULE.WORD_BREAK))) == 1


@pytest.mark.parametrize("blank_value", ["", "   "])
def test_fill_rejects_blank_required_value(tmp_path: Path, blank_value: str) -> None:
    source = tmp_path / "source.docx"
    output = tmp_path / "filled.docx"
    values = tmp_path / "values.json"
    document = """<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body><w:p><w:r><w:t>[form.name]</w:t></w:r></w:p></w:body></w:document>"""
    _write_docx(source, document)
    values.write_text(json.dumps({"name": blank_value}), encoding="utf-8")

    result = _run(
        "fill",
        str(source),
        "--values",
        str(values),
        "--output",
        str(output),
        check=False,
    )

    assert result.returncode == 1
    assert "required field must not be blank: name" in result.stderr
    assert not output.exists()


@pytest.mark.parametrize("invalid_date", ["20260825", "2026-W35-2"])
def test_fill_rejects_noncanonical_iso_date(tmp_path: Path, invalid_date: str) -> None:
    source = tmp_path / "source.docx"
    output = tmp_path / "filled.docx"
    values = tmp_path / "values.json"
    document = """<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body><w:p><w:r><w:t>[form.date7]</w:t></w:r></w:p></w:body></w:document>"""
    _write_docx(source, document)
    values.write_text(json.dumps({"date7": invalid_date}), encoding="utf-8")

    result = _run(
        "fill",
        str(source),
        "--values",
        str(values),
        "--output",
        str(output),
        check=False,
    )

    assert result.returncode == 1
    assert "YYYY-MM-DD" in result.stderr
    assert not output.exists()


def test_fill_rejects_missing_unknown_invalid_and_existing_output(
    tmp_path: Path,
) -> None:
    source = tmp_path / "source.docx"
    output = tmp_path / "filled.docx"
    values = tmp_path / "values.json"
    document = """<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body><w:p><w:r><w:t>[form.date7]</w:t></w:r></w:p></w:body></w:document>"""
    _write_docx(source, document)

    for payload, message in [
        ({}, "missing field values"),
        ({"date7": "2026-08-25", "extra": "x"}, "unknown field values"),
        ({"date7": "08/25/2026"}, "ISO date"),
    ]:
        values.write_text(json.dumps(payload), encoding="utf-8")
        result = _run(
            "fill",
            str(source),
            "--values",
            str(values),
            "--output",
            str(output),
            check=False,
        )
        assert result.returncode == 1
        assert message in result.stderr

    values.write_text(json.dumps({"date7": "2026-08-25"}), encoding="utf-8")
    output.write_text("do-not-overwrite", encoding="utf-8")
    result = _run(
        "fill",
        str(source),
        "--values",
        str(values),
        "--output",
        str(output),
        check=False,
    )
    assert result.returncode == 1
    assert "already exists" in result.stderr
    assert output.read_text(encoding="utf-8") == "do-not-overwrite"


def test_fill_rejects_dangling_output_symlink(tmp_path: Path) -> None:
    source = tmp_path / "source.docx"
    output = tmp_path / "filled.docx"
    target = tmp_path / "missing-target.docx"
    values = tmp_path / "values.json"
    document = """<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body><w:p><w:r><w:t>[form.text1]</w:t></w:r></w:p></w:body></w:document>"""
    _write_docx(source, document)
    values.write_text(json.dumps({"text1": "approved value"}), encoding="utf-8")
    output.symlink_to(target)

    result = _run(
        "fill",
        str(source),
        "--values",
        str(values),
        "--output",
        str(output),
        check=False,
    )

    assert result.returncode == 1
    assert "already exists" in result.stderr
    assert output.is_symlink()
    assert not target.exists()


def test_fill_rejects_duplicate_json_field_names(tmp_path: Path) -> None:
    source = tmp_path / "source.docx"
    output = tmp_path / "filled.docx"
    values = tmp_path / "values.json"
    document = """<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body><w:p><w:r><w:t>[form.text1]</w:t></w:r></w:p></w:body></w:document>"""
    _write_docx(source, document)
    values.write_text('{"text1":"first","text1":"second"}', encoding="utf-8")

    result = _run(
        "fill",
        str(source),
        "--values",
        str(values),
        "--output",
        str(output),
        check=False,
    )

    assert result.returncode == 1
    assert "duplicate JSON field" in result.stderr
    assert not output.exists()


def test_author_rejects_markers_missing_from_manifest(tmp_path: Path) -> None:
    source = tmp_path / "source.docx"
    output = tmp_path / "authored.docx"
    manifest = tmp_path / "manifest.json"
    document = """<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body><w:p><w:r><w:t>{{known}} {{typo}}</w:t></w:r></w:p></w:body></w:document>"""
    _write_docx(source, document)
    manifest.write_text(
        json.dumps(
            {
                "fields": [
                    {"id": "known", "required": True, "type": "text"},
                ]
            }
        ),
        encoding="utf-8",
    )

    result = _run(
        "author",
        str(source),
        "--manifest",
        str(manifest),
        "--output",
        str(output),
        check=False,
    )

    assert result.returncode == 1
    assert "unknown author markers: typo" in result.stderr
    assert not output.exists()


def test_malformed_package_and_duplicate_manifest_are_rejected(tmp_path: Path) -> None:
    malformed = tmp_path / "bad.docx"
    malformed.write_bytes(b"not-a-zip")
    result = _run("inspect", str(malformed), check=False)
    assert result.returncode == 1
    assert "valid OOXML package" in result.stderr

    source = tmp_path / "source.xlsx"
    output = tmp_path / "output.xlsx"
    manifest = tmp_path / "manifest.json"
    _write_xlsx(source, "{{field1}}")
    manifest.write_text(
        json.dumps(
            {
                "fields": [
                    {"id": "field1", "label": "One", "type": "text", "required": True},
                    {
                        "id": "field1",
                        "label": "Duplicate",
                        "type": "text",
                        "required": True,
                    },
                ]
            }
        ),
        encoding="utf-8",
    )
    result = _run(
        "author",
        str(source),
        "--manifest",
        str(manifest),
        "--output",
        str(output),
        check=False,
    )
    assert result.returncode == 1
    assert "duplicate field id" in result.stderr


def test_open_package_keeps_only_editable_xml_in_memory(tmp_path: Path) -> None:
    source = tmp_path / "source.docx"
    document = """<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body><w:p><w:r><w:t>[form.text1]</w:t></w:r></w:p></w:body></w:document>"""
    _write_docx(source, document)
    with zipfile.ZipFile(source, "a") as archive:
        archive.writestr("word/media/image.bin", b"unrelated-media")

    package_format, payloads, member_names = FORM_MODULE._open_package(source)

    assert package_format == "docx"
    assert member_names == ["word/document.xml"]
    assert set(payloads) == set(member_names)


def test_inspect_rejects_oversized_archive_member(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source = tmp_path / "source.docx"
    document = """<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body><w:p><w:r><w:t>[form.text1]</w:t></w:r></w:p></w:body></w:document>"""
    _write_docx(source, document)
    member_limit = 1024
    monkeypatch.setattr(
        FORM_MODULE, "MAX_MEMBER_UNCOMPRESSED_BYTES", member_limit, raising=False
    )
    with zipfile.ZipFile(source, "a") as archive:
        archive.writestr("word/media/image.bin", b"x" * (member_limit + 1))

    result = _run("inspect", str(source), check=False)

    assert result.returncode == 1
    assert "member size limit" in result.stderr


def test_inspect_rejects_excessive_archive_compression(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source = tmp_path / "source.docx"
    document = """<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body><w:p><w:r><w:t>[form.text1]</w:t></w:r></w:p></w:body></w:document>"""
    _write_docx(source, document)
    monkeypatch.setattr(FORM_MODULE, "MAX_COMPRESSION_RATIO", 2, raising=False)
    with zipfile.ZipFile(source, "a") as archive:
        archive.writestr(
            "word/media/image.bin",
            b"x" * 4096,
            compress_type=zipfile.ZIP_DEFLATED,
        )

    result = _run("inspect", str(source), check=False)

    assert result.returncode == 1
    assert "compression ratio limit" in result.stderr


@pytest.mark.parametrize("suffix", [".doc", ".xls", ".txt"])
def test_unsupported_extensions_are_rejected(tmp_path: Path, suffix: str) -> None:
    source = tmp_path / f"source{suffix}"
    source.write_bytes(b"content")
    result = _run("inspect", str(source), check=False)
    assert result.returncode == 1
    assert "DOCX and XLSX" in result.stderr
