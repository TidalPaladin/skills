#!/usr/bin/env python3
"""Inspect, author, and fill reusable Cognidox Office form templates."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import sys
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from xml.etree import ElementTree as ET

EXIT_RUNTIME = 1
EXIT_USAGE = 2
MAX_PACKAGE_COMPRESSED_BYTES = 512 * 1024 * 1024
MAX_MEMBER_UNCOMPRESSED_BYTES = 256 * 1024 * 1024
MAX_TOTAL_UNCOMPRESSED_BYTES = 1024 * 1024 * 1024
MAX_COMPRESSION_RATIO = 1000
MAX_ARCHIVE_MEMBERS = 10_000
ARCHIVE_COPY_BUFFER_BYTES = 1024 * 1024
FIELD_ID_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+$")
FORM_MARKER_PATTERN = re.compile(r"\[form\.([A-Za-z0-9_.-]+)\]")
AUTHOR_MARKER_PATTERN = re.compile(r"\{\{([A-Za-z0-9_.-]+)\}\}")
DATE_VALUE_PATTERN = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
MERGE_FIELD_PATTERN = re.compile(
    r"\bMERGEFIELD\s+(?:\"?\[form\.([A-Za-z0-9_.-]+)\]\"?)",
    re.IGNORECASE,
)
WORD_NAMESPACE = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
SPREADSHEET_NAMESPACE = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
WORD_TEXT = f"{{{WORD_NAMESPACE}}}t"
WORD_RUN = f"{{{WORD_NAMESPACE}}}r"
WORD_RUN_PROPERTIES = f"{{{WORD_NAMESPACE}}}rPr"
WORD_BREAK = f"{{{WORD_NAMESPACE}}}br"
WORD_FIELD_CHAR = f"{{{WORD_NAMESPACE}}}fldChar"
WORD_INSTRUCTION = f"{{{WORD_NAMESPACE}}}instrText"
WORD_SIMPLE_FIELD = f"{{{WORD_NAMESPACE}}}fldSimple"
WORD_PARAGRAPH = f"{{{WORD_NAMESPACE}}}p"
XML_SPACE = "{http://www.w3.org/XML/1998/namespace}space"
SUPPORTED_FIELD_TYPES = frozenset({"text", "textarea", "date"})


class FormError(Exception):
    """A safe, user-facing Office form error."""


@dataclass(frozen=True)
class Field:
    """A reusable form field."""

    field_id: str
    field_type: str
    required: bool
    label: str | None = None

    def as_dict(self) -> dict[str, object]:
        result: dict[str, object] = {
            "id": self.field_id,
            "required": self.required,
            "type": self.field_type,
        }
        if self.label is not None:
            result["label"] = self.label
        return result


def _package_format(path: Path) -> str:
    suffix = path.suffix.lower()
    if suffix == ".docx":
        return "docx"
    if suffix == ".xlsx":
        return "xlsx"
    raise FormError("only DOCX and XLSX Office packages are supported")


def _xml_member_names(package: zipfile.ZipFile, package_format: str) -> list[str]:
    names = package.namelist()
    if package_format == "docx":
        if "word/document.xml" not in names:
            raise FormError("malformed DOCX package: word/document.xml is missing")
        return [
            name
            for name in names
            if name == "word/document.xml"
            or re.fullmatch(r"word/(?:header|footer)\d+\.xml", name)
        ]

    worksheet_names = [
        name for name in names if re.fullmatch(r"xl/worksheets/[^/]+\.xml", name)
    ]
    shared_names = [name for name in names if name == "xl/sharedStrings.xml"]
    if not worksheet_names and not shared_names:
        raise FormError(
            "malformed XLSX package: no worksheet or shared string XML is present"
        )
    return [*shared_names, *worksheet_names]


def _validate_archive(path: Path, package: zipfile.ZipFile) -> None:
    if path.stat().st_size > MAX_PACKAGE_COMPRESSED_BYTES:
        raise FormError("Office package exceeds the compressed size limit")
    members = package.infolist()
    if len(members) > MAX_ARCHIVE_MEMBERS:
        raise FormError("Office package exceeds the archive member count limit")
    names = [member.filename for member in members]
    if len(names) != len(set(names)):
        raise FormError("Office package contains duplicate archive member names")

    total_size = 0
    for member in members:
        total_size += member.file_size
        if member.file_size > MAX_MEMBER_UNCOMPRESSED_BYTES:
            raise FormError("Office package member size limit exceeded")
        if member.file_size and (
            member.compress_size == 0
            or member.file_size / member.compress_size > MAX_COMPRESSION_RATIO
        ):
            raise FormError("Office package compression ratio limit exceeded")
    if total_size > MAX_TOTAL_UNCOMPRESSED_BYTES:
        raise FormError("Office package exceeds the total uncompressed size limit")


def _open_package(path: Path) -> tuple[str, dict[str, bytes], list[str]]:
    package_format = _package_format(path)
    try:
        with zipfile.ZipFile(path) as package:
            _validate_archive(path, package)
            member_names = _xml_member_names(package, package_format)
            return (
                package_format,
                {name: package.read(name) for name in member_names},
                member_names,
            )
    except (OSError, zipfile.BadZipFile) as error:
        raise FormError(
            f"input is not a valid OOXML package ({package_format.upper()})"
        ) from error


def _parse_xml(payload: bytes, member_name: str) -> ET.Element:
    try:
        return ET.fromstring(payload)
    except ET.ParseError as error:
        raise FormError(f"malformed Office XML in {member_name}") from error


def _infer_field_type(field_id: str) -> str:
    prefix = field_id.lower().split(".", maxsplit=1)[0]
    if prefix.startswith("date"):
        return "date"
    if prefix.startswith("textarea"):
        return "textarea"
    return "text"


def _validate_field_id(field_id: object) -> str:
    if not isinstance(field_id, str) or not FIELD_ID_PATTERN.fullmatch(field_id):
        raise FormError(
            "field IDs may contain only letters, numbers, dots, hyphens, and underscores"
        )
    return field_id


def _manifest_from_ids(field_ids: set[str]) -> list[Field]:
    return [
        Field(field_id, _infer_field_type(field_id), required=True)
        for field_id in sorted(field_ids)
    ]


def _reject_duplicate_json_fields(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for field_name, value in pairs:
        if field_name in result:
            raise FormError(f"duplicate JSON field: {field_name}")
        result[field_name] = value
    return result


def _load_json_object(path: Path, description: str) -> dict[str, Any]:
    try:
        value = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=_reject_duplicate_json_fields,
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise FormError(f"{description} must be a readable JSON object") from error
    if not isinstance(value, dict):
        raise FormError(f"{description} must be a JSON object")
    return value


def _load_manifest(path: Path) -> list[Field]:
    manifest = _load_json_object(path, "manifest")
    raw_fields = manifest.get("fields")
    if not isinstance(raw_fields, list) or not raw_fields:
        raise FormError("manifest must contain a non-empty fields array")

    fields: list[Field] = []
    seen: set[str] = set()
    for raw_field in raw_fields:
        if not isinstance(raw_field, dict):
            raise FormError("each manifest field must be an object")
        field_id = _validate_field_id(raw_field.get("id"))
        if field_id in seen:
            raise FormError(f"duplicate field id in manifest: {field_id}")
        seen.add(field_id)
        field_type = raw_field.get("type", _infer_field_type(field_id))
        if not isinstance(field_type, str) or field_type not in SUPPORTED_FIELD_TYPES:
            raise FormError(f"unsupported field type for {field_id}")
        required = raw_field.get("required", True)
        if not isinstance(required, bool):
            raise FormError(f"required must be true or false for {field_id}")
        label = raw_field.get("label")
        if label is not None and not isinstance(label, str):
            raise FormError(f"label must be text for {field_id}")
        fields.append(Field(field_id, field_type, required, label))
    return fields


def _word_complex_field_ids(root: ET.Element) -> set[str]:
    field_ids: set[str] = set()
    for paragraph in root.iter(WORD_PARAGRAPH):
        active = False
        instructions: list[str] = []
        for element in paragraph.iter():
            if element.tag == WORD_FIELD_CHAR:
                field_type = element.get(f"{{{WORD_NAMESPACE}}}fldCharType")
                if field_type == "begin":
                    active = True
                    instructions = []
                elif field_type == "end" and active:
                    match = MERGE_FIELD_PATTERN.search("".join(instructions))
                    if match:
                        field_ids.add(match.group(1))
                    active = False
            elif active and element.tag == WORD_INSTRUCTION:
                instructions.append(element.text or "")
    return field_ids


def _discover_fields(
    package_format: str, payloads: dict[str, bytes], members: list[str]
) -> list[Field]:
    field_ids: set[str] = set()
    for member_name in members:
        root = _parse_xml(payloads[member_name], member_name)
        text = "".join(root.itertext())
        field_ids.update(FORM_MARKER_PATTERN.findall(text))
        if package_format == "docx":
            field_ids.update(_word_complex_field_ids(root))
    if not field_ids:
        raise FormError("no [form.<field-id>] markers were found")
    return _manifest_from_ids(field_ids)


def _group_text_nodes(root: ET.Element, package_format: str) -> list[list[ET.Element]]:
    if package_format == "docx":
        return [
            list(paragraph.iter(WORD_TEXT)) for paragraph in root.iter(WORD_PARAGRAPH)
        ]
    shared_item_tag = f"{{{SPREADSHEET_NAMESPACE}}}si"
    inline_item_tag = f"{{{SPREADSHEET_NAMESPACE}}}is"
    text_tag = f"{{{SPREADSHEET_NAMESPACE}}}t"
    groups = [list(item.iter(text_tag)) for item in root.iter(shared_item_tag)]
    groups.extend(list(item.iter(text_tag)) for item in root.iter(inline_item_tag))
    return groups


def _replace_token_in_nodes(
    nodes: list[ET.Element], token: str, replacement: str
) -> int:
    text = "".join(node.text or "" for node in nodes)
    occurrences = [match.span() for match in re.finditer(re.escape(token), text)]
    for start, end in reversed(occurrences):
        cursor = 0
        start_node_index = -1
        start_offset = 0
        end_node_index = -1
        end_offset = 0
        for index, node in enumerate(nodes):
            node_text = node.text or ""
            next_cursor = cursor + len(node_text)
            if start_node_index < 0 and start < next_cursor:
                start_node_index = index
                start_offset = start - cursor
            if end <= next_cursor:
                end_node_index = index
                end_offset = end - cursor
                break
            cursor = next_cursor
        if start_node_index < 0 or end_node_index < 0:
            continue
        start_text = nodes[start_node_index].text or ""
        end_text = nodes[end_node_index].text or ""
        prefix = start_text[:start_offset]
        suffix = end_text[end_offset:]
        if start_node_index == end_node_index:
            nodes[start_node_index].text = prefix + replacement + suffix
            continue
        nodes[start_node_index].text = prefix + replacement
        for index in range(start_node_index + 1, end_node_index):
            nodes[index].text = ""
        nodes[end_node_index].text = suffix
    return len(occurrences)


def _replace_plain_markers(
    root: ET.Element, package_format: str, replacements: dict[str, str]
) -> set[str]:
    replaced: set[str] = set()
    for nodes in _group_text_nodes(root, package_format):
        for field_id, value in replacements.items():
            token = f"[form.{field_id}]"
            if _replace_token_in_nodes(nodes, token, value):
                replaced.add(field_id)
    if package_format == "docx" and replaced:
        _expand_word_text_newlines(root)
    return replaced


def _replace_author_markers(
    root: ET.Element, package_format: str, fields: list[Field]
) -> set[str]:
    replaced: set[str] = set()
    for nodes in _group_text_nodes(root, package_format):
        for field in fields:
            token = f"{{{{{field.field_id}}}}}"
            if _replace_token_in_nodes(nodes, token, f"[form.{field.field_id}]"):
                replaced.add(field.field_id)
    return replaced


def _author_marker_ids(root: ET.Element, package_format: str) -> set[str]:
    field_ids: set[str] = set()
    for nodes in _group_text_nodes(root, package_format):
        text = "".join(node.text or "" for node in nodes)
        field_ids.update(AUTHOR_MARKER_PATTERN.findall(text))
    return field_ids


def _make_word_value_run(source_run: ET.Element | None, value: str) -> ET.Element:
    run = ET.Element(WORD_RUN)
    if source_run is not None:
        run_properties = source_run.find(WORD_RUN_PROPERTIES)
        if run_properties is not None:
            run.append(ET.fromstring(ET.tostring(run_properties)))
    lines = value.split("\n")
    for index, line in enumerate(lines):
        if index:
            run.append(ET.Element(WORD_BREAK))
        text = ET.SubElement(run, WORD_TEXT)
        if line.startswith(" ") or line.endswith(" "):
            text.set(XML_SPACE, "preserve")
        text.text = line
    return run


def _set_word_text(text_node: ET.Element, value: str) -> None:
    text_node.text = value
    if value.startswith(" ") or value.endswith(" "):
        text_node.set(XML_SPACE, "preserve")


def _expand_word_text_newlines(root: ET.Element) -> None:
    parents = {child: parent for parent in root.iter() for child in parent}
    for text_node in list(root.iter(WORD_TEXT)):
        value = text_node.text or ""
        if "\n" not in value:
            continue
        parent = parents.get(text_node)
        if parent is None or parent.tag != WORD_RUN:
            raise FormError("DOCX text with a line break must be inside a Word run")
        lines = value.split("\n")
        _set_word_text(text_node, lines[0])
        insertion_index = list(parent).index(text_node) + 1
        for line in lines[1:]:
            parent.insert(insertion_index, ET.Element(WORD_BREAK))
            insertion_index += 1
            continuation = ET.Element(WORD_TEXT)
            _set_word_text(continuation, line)
            parent.insert(insertion_index, continuation)
            insertion_index += 1


def _replace_word_complex_fields(
    root: ET.Element, replacements: dict[str, str]
) -> set[str]:
    replaced: set[str] = set()
    for paragraph in root.iter(WORD_PARAGRAPH):
        children = list(paragraph)
        index = 0
        while index < len(children):
            run = children[index]
            field_char = run.find(WORD_FIELD_CHAR) if run.tag == WORD_RUN else None
            field_type = (
                field_char.get(f"{{{WORD_NAMESPACE}}}fldCharType")
                if field_char is not None
                else None
            )
            if field_type != "begin":
                index += 1
                continue
            end_index = index + 1
            instructions: list[str] = []
            result_run: ET.Element | None = None
            separate_seen = False
            while end_index < len(children):
                candidate = children[end_index]
                for instruction in candidate.iter(WORD_INSTRUCTION):
                    instructions.append(instruction.text or "")
                candidate_char = (
                    candidate.find(WORD_FIELD_CHAR)
                    if candidate.tag == WORD_RUN
                    else None
                )
                candidate_type = (
                    candidate_char.get(f"{{{WORD_NAMESPACE}}}fldCharType")
                    if candidate_char is not None
                    else None
                )
                if candidate_type == "separate":
                    separate_seen = True
                elif separate_seen and result_run is None and candidate.tag == WORD_RUN:
                    result_run = candidate
                if candidate_type == "end":
                    break
                end_index += 1
            if end_index >= len(children):
                index += 1
                continue
            match = MERGE_FIELD_PATTERN.search("".join(instructions))
            if not match or match.group(1) not in replacements:
                index = end_index + 1
                continue
            field_id = match.group(1)
            insertion_index = list(paragraph).index(run)
            for child in children[index : end_index + 1]:
                paragraph.remove(child)
            paragraph.insert(
                insertion_index,
                _make_word_value_run(result_run, replacements[field_id]),
            )
            replaced.add(field_id)
            children = list(paragraph)
            index = insertion_index + 1
    return replaced


def _replace_word_simple_fields(
    root: ET.Element, replacements: dict[str, str]
) -> set[str]:
    replaced: set[str] = set()
    for parent in root.iter():
        for child in list(parent):
            if child.tag != WORD_SIMPLE_FIELD:
                continue
            instruction = child.get(f"{{{WORD_NAMESPACE}}}instr", "")
            match = MERGE_FIELD_PATTERN.search(instruction)
            if not match or match.group(1) not in replacements:
                continue
            field_id = match.group(1)
            source_run = next(child.iter(WORD_RUN), None)
            index = list(parent).index(child)
            parent.remove(child)
            parent.insert(
                index, _make_word_value_run(source_run, replacements[field_id])
            )
            replaced.add(field_id)
    return replaced


def _serialize_xml(root: ET.Element) -> bytes:
    ET.register_namespace("w", WORD_NAMESPACE)
    ET.register_namespace("x", SPREADSHEET_NAMESPACE)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def _write_package(source: Path, output: Path, payloads: dict[str, bytes]) -> None:
    if output.exists() or output.is_symlink():
        raise FormError(f"output already exists: {output}")
    try:
        if source.resolve() == output.resolve():
            raise FormError("output must not overwrite the source package")
    except OSError as error:
        raise FormError("could not resolve the input or output path") from error
    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    file_descriptor, temporary_name = tempfile.mkstemp(
        prefix=".cognidox-form-", dir=output.parent
    )
    os.close(file_descriptor)
    temporary_path = Path(temporary_name)
    try:
        with (
            zipfile.ZipFile(source) as original,
            zipfile.ZipFile(
                temporary_path, "w", compression=zipfile.ZIP_DEFLATED
            ) as generated,
        ):
            _validate_archive(source, original)
            for information in original.infolist():
                if information.filename in payloads:
                    generated.writestr(information, payloads[information.filename])
                elif information.is_dir():
                    generated.writestr(information, b"")
                else:
                    with (
                        original.open(information) as source_member,
                        generated.open(
                            information, "w", force_zip64=True
                        ) as output_member,
                    ):
                        shutil.copyfileobj(
                            source_member,
                            output_member,
                            length=ARCHIVE_COPY_BUFFER_BYTES,
                        )
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, output)
    except (OSError, zipfile.BadZipFile) as error:
        raise FormError("could not write the Office package") from error
    finally:
        temporary_path.unlink(missing_ok=True)


def _validate_values(fields: list[Field], values_path: Path) -> dict[str, str]:
    raw_values = _load_json_object(values_path, "values file")
    field_map = {field.field_id: field for field in fields}
    unknown = sorted(set(raw_values) - set(field_map))
    if unknown:
        raise FormError(f"unknown field values: {', '.join(unknown)}")
    missing = sorted(
        field.field_id
        for field in fields
        if field.required and field.field_id not in raw_values
    )
    if missing:
        raise FormError(f"missing field values: {', '.join(missing)}")

    values: dict[str, str] = {}
    for field_id, raw_value in raw_values.items():
        if not isinstance(raw_value, str):
            raise FormError(f"field value must be text: {field_id}")
        field = field_map[field_id]
        if field.required and not raw_value.strip():
            raise FormError(f"required field must not be blank: {field_id}")
        if field.field_type == "date":
            if not raw_value and not field.required:
                values[field_id] = raw_value
                continue
            try:
                if not DATE_VALUE_PATTERN.fullmatch(raw_value):
                    raise ValueError
                dt.date.fromisoformat(raw_value)
            except ValueError as error:
                raise FormError(
                    f"field {field_id} must use an ISO date in YYYY-MM-DD form"
                ) from error
        values[field_id] = raw_value
    for field in fields:
        values.setdefault(field.field_id, "")
    return values


def inspect_package(source: Path) -> dict[str, object]:
    package_format, payloads, members = _open_package(source)
    fields = _discover_fields(package_format, payloads, members)
    return {"fields": [field.as_dict() for field in fields], "format": package_format}


def author_package(
    source: Path, manifest_path: Path, output: Path
) -> dict[str, object]:
    package_format, payloads, members = _open_package(source)
    fields = _load_manifest(manifest_path)
    declared = {field.field_id for field in fields}
    discovered: set[str] = set()
    replaced: set[str] = set()
    for member_name in members:
        root = _parse_xml(payloads[member_name], member_name)
        discovered.update(_author_marker_ids(root, package_format))
        replaced.update(_replace_author_markers(root, package_format, fields))
        payloads[member_name] = _serialize_xml(root)
    unknown = sorted(discovered - declared)
    if unknown:
        raise FormError(f"unknown author markers: {', '.join(unknown)}")
    missing = sorted(
        field.field_id for field in fields if field.field_id not in replaced
    )
    if missing:
        raise FormError(f"missing author markers: {', '.join(missing)}")
    _write_package(source, output, payloads)
    return {
        "fields": [field.as_dict() for field in fields],
        "format": package_format,
        "output": str(output),
    }


def fill_package(
    source: Path,
    values_path: Path,
    output: Path,
    manifest_path: Path | None = None,
) -> dict[str, object]:
    package_format, payloads, members = _open_package(source)
    discovered_fields = _discover_fields(package_format, payloads, members)
    fields = (
        _load_manifest(manifest_path)
        if manifest_path is not None
        else discovered_fields
    )
    if manifest_path is not None:
        discovered_ids = {field.field_id for field in discovered_fields}
        manifest_ids = {field.field_id for field in fields}
        missing = sorted(manifest_ids - discovered_ids)
        if missing:
            raise FormError(f"missing form fields in package: {', '.join(missing)}")
        unknown = sorted(discovered_ids - manifest_ids)
        if unknown:
            raise FormError(f"unknown form fields in package: {', '.join(unknown)}")
    values = _validate_values(fields, values_path)
    replaced: set[str] = set()
    for member_name in members:
        root = _parse_xml(payloads[member_name], member_name)
        if package_format == "docx":
            replaced.update(_replace_word_complex_fields(root, values))
            replaced.update(_replace_word_simple_fields(root, values))
        replaced.update(_replace_plain_markers(root, package_format, values))
        payloads[member_name] = _serialize_xml(root)
    missing = sorted(set(values) - replaced)
    if missing:
        raise FormError(f"missing form fields in package: {', '.join(missing)}")
    _write_package(source, output, payloads)
    return {"fields": sorted(values), "format": package_format, "output": str(output)}


def _render(result: dict[str, object], output_format: str) -> None:
    if output_format == "json":
        print(
            json.dumps(
                result, ensure_ascii=False, separators=(",", ":"), sort_keys=True
            )
        )
        return
    for key, value in result.items():
        if key == "fields" and isinstance(value, list):
            for field in value:
                if isinstance(field, dict):
                    print(
                        f"{field['id']}\t{field['type']}\trequired={str(field['required']).lower()}"
                    )
                else:
                    print(field)
        else:
            print(f"{key}: {value}")


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("inspect", "author", "fill"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument("source", type=Path)
        subparser.add_argument("--format", choices=("text", "json"), default="text")
        if command in {"author", "fill"}:
            subparser.add_argument("--output", type=Path, required=True)
        if command == "author":
            subparser.add_argument("--manifest", type=Path, required=True)
        if command == "fill":
            subparser.add_argument("--manifest", type=Path)
            subparser.add_argument("--values", type=Path, required=True)
    return parser


def main(arguments: list[str] | None = None) -> int:
    parser = _build_parser()
    namespace = parser.parse_args(arguments)
    try:
        if namespace.command == "inspect":
            result = inspect_package(namespace.source)
        elif namespace.command == "author":
            result = author_package(
                namespace.source, namespace.manifest, namespace.output
            )
        else:
            result = fill_package(
                namespace.source,
                namespace.values,
                namespace.output,
                namespace.manifest,
            )
        _render(result, namespace.format)
        return 0
    except FormError as error:
        print(f"error: {error}", file=sys.stderr)
        return EXIT_RUNTIME


if __name__ == "__main__":
    raise SystemExit(main())
