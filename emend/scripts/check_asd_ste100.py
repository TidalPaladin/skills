#!/usr/bin/env python3
"""Check enforceable ASD-STE100 rules in UTF-8 text documents."""

from __future__ import annotations

import argparse
import bisect
import json
import re
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Literal, Sequence

DocumentType = Literal["descriptive", "procedural"]
InputFormat = Literal["auto", "markdown", "text"]
Severity = Literal["advisory", "error"]

EXIT_PASS = 0
EXIT_FINDINGS = 1
EXIT_ERROR = 2
PROCEDURAL_WORD_LIMIT = 20
DESCRIPTIVE_WORD_LIMIT = 25
DESCRIPTIVE_PARAGRAPH_LIMIT = 6

UNCHECKED_RULES = (
    "Rules 1.1-1.13: approved vocabulary, meanings, parts of speech, and technical terms",
    "Rules 2.1-2.2: multi-word noun length and approved technical noun forms",
    "Rules 3.1-3.4 and 3.7: approved verb forms, tenses, and direct action verbs",
    "Rules 4.1 and 4.3-4.5: sentence clarity, lists, connections, and articles",
    "Rules 5.2-5.5: instruction count, imperative form, conditions, and notes",
    "Rules 6.1-6.5: information order, topic structure, and paragraph focus",
    "Rules 7.1-7.3: safety level, command or condition, and risk explanation",
    "Rules 8.2-8.7: contextual punctuation and complete word-count interpretation",
    "Rules 9.1-9.4: sentence construction, word use, phrasal verbs, and consistency",
)

_CONTRACTION_PATTERN = re.compile(
    r"\b(?:"
    r"ain['’]t|aren['’]t|can['’]t|couldn['’]t|didn['’]t|doesn['’]t|"
    r"don['’]t|hadn['’]t|hasn['’]t|haven['’]t|isn['’]t|mustn['’]t|"
    r"needn['’]t|shan['’]t|shouldn['’]t|wasn['’]t|weren['’]t|won['’]t|"
    r"wouldn['’]t|"
    r"(?:i|you|we|they|he|she|it|that|there|what|who|where|when|why|how)"
    r"['’](?:d|ll|m|re|s|ve)"
    r")\b",
    re.IGNORECASE,
)
_ING_PATTERN = re.compile(r"\b[A-Za-z][A-Za-z-]*ing\b", re.IGNORECASE)
_ING_EXCEPTIONS = frozenset(
    {
        "ceiling",
        "during",
        "king",
        "nothing",
        "opening",
        "remaining",
        "ring",
        "something",
        "spring",
        "string",
        "thing",
        "warning",
    }
)
_PASSIVE_PATTERN = re.compile(
    r"\b(?:am|are|be|been|being|is|was|were)\s+"
    r"(?:(?:[A-Za-z]+ly)\s+){0,2}"
    r"(?:[A-Za-z]+(?:ed|en)|built|done|found|given|held|kept|known|made|put|"
    r"read|seen|sent|set|shown|taken|told|written)\b",
    re.IGNORECASE,
)
_INLINE_CODE_PATTERN = re.compile(r"(`+)(.+?)\1")
_MARKDOWN_LINK_TARGET_PATTERN = re.compile(r"(?<=\])\([^\n)]*\)")
_NUMBER_UNIT_PATTERN = re.compile(
    r"\b\d+(?:[.,]\d+)?\s*(?:%|A|Ah|cm|dB|deg|ft|g|GHz|Hz|in|kg|kHz|km|"
    r"kPa|kV|lb|m|mA|MHz|mm|ms|N|nm|Pa|psi|rpm|s|V|W)\b",
    re.IGNORECASE,
)
_PARENTHETICAL_PATTERN = re.compile(r"\([^()]*\)")
_QUOTED_TEXT_PATTERN = re.compile(r"[\"“][^\"”\n]*[\"”]")
_URL_PATTERN = re.compile(r"\b(?:https?|ftp)://\S+")
_WORD_PATTERN = re.compile(r"[A-Za-z0-9]+(?:[.'’/-][A-Za-z0-9]+)*", re.IGNORECASE)
_ABBREVIATIONS = frozenset(
    {
        "e.g.",
        "etc.",
        "fig.",
        "i.e.",
        "mr.",
        "mrs.",
        "no.",
        "ref.",
        "sec.",
        "u.s.",
        "vs.",
    }
)
_CLOSING_PUNCTUATION = frozenset("\"')]}”’")


@dataclass(frozen=True, slots=True)
class Finding:
    """One linter finding with its source location."""

    path: str
    line: int
    column: int
    rule: str
    severity: Severity
    message: str
    excerpt: str


@dataclass(frozen=True, slots=True)
class ScanReport:
    """Findings and scan metadata for one input."""

    path: str
    document_type: DocumentType
    input_format: Literal["markdown", "text"]
    findings: list[Finding]
    skipped_regions: int


@dataclass(frozen=True, slots=True)
class MaskedText:
    """Text with protected regions replaced by spaces."""

    text: str
    skipped_regions: int


class Styles:
    """Centralized ANSI styles for text output."""

    def __init__(self, enabled: bool) -> None:
        self.enabled = enabled

    def apply(self, value: str, code: str) -> str:
        if not self.enabled:
            return value
        return f"\x1b[{code}m{value}\x1b[0m"

    def status(self, value: str) -> str:
        code = {"PASS": "1;32", "WARN": "1;33", "FAIL": "1;31"}[value]
        return self.apply(value, code)

    def section(self, value: str) -> str:
        return self.apply(value, "1;36")

    def severity(self, value: Severity) -> str:
        return self.apply(value, "31" if value == "error" else "33")


def _mask_segment(characters: list[str], start: int, end: int) -> None:
    for index in range(start, end):
        if characters[index] not in "\r\n":
            characters[index] = " "


def _mask_markdown(text: str) -> MaskedText:
    characters = list(text)
    skipped_regions = 0
    lines = text.splitlines(keepends=True)
    offsets: list[int] = []
    offset = 0
    for line in lines:
        offsets.append(offset)
        offset += len(line)

    front_matter = bool(lines and lines[0].strip() == "---")
    in_fence = False
    fence_marker = ""
    in_block_quote = False

    for line_index, line in enumerate(lines):
        start = offsets[line_index]
        end = start + len(line)

        if front_matter:
            _mask_segment(characters, start, end)
            if line_index > 0 and line.strip() in {"---", "..."}:
                front_matter = False
                skipped_regions += 1
            continue

        fence_match = re.match(r"^\s*(`{3,}|~{3,})", line)
        if in_fence:
            _mask_segment(characters, start, end)
            if fence_match:
                closing_marker = fence_match.group(1)
                has_only_trailing_space = not line[fence_match.end() :].strip()
                if (
                    closing_marker[0] == fence_marker[0]
                    and len(closing_marker) >= len(fence_marker)
                    and has_only_trailing_space
                ):
                    in_fence = False
            continue
        if fence_match:
            in_fence = True
            fence_marker = fence_match.group(1)
            skipped_regions += 1
            _mask_segment(characters, start, end)
            continue

        is_block_quote = bool(re.match(r"^\s*>", line))
        if is_block_quote:
            if not in_block_quote:
                skipped_regions += 1
            in_block_quote = True
            _mask_segment(characters, start, end)
            continue
        in_block_quote = False

        for inline_match in _INLINE_CODE_PATTERN.finditer(line):
            skipped_regions += 1
            _mask_segment(
                characters,
                start + inline_match.start(),
                start + inline_match.end(),
            )
        for target_match in _MARKDOWN_LINK_TARGET_PATTERN.finditer(line):
            _mask_segment(
                characters,
                start + target_match.start(),
                start + target_match.end(),
            )

    return MaskedText("".join(characters), skipped_regions)


def _resolve_input_format(
    path: Path, input_format: InputFormat
) -> Literal["markdown", "text"]:
    if input_format != "auto":
        return input_format
    if path.suffix.lower() in {".md", ".markdown", ".mdx"}:
        return "markdown"
    return "text"


def _line_starts(text: str) -> list[int]:
    return [0, *(match.end() for match in re.finditer("\n", text))]


def _source_location(line_starts: list[int], offset: int) -> tuple[int, int]:
    line_index = bisect.bisect_right(line_starts, offset) - 1
    return line_index + 1, offset - line_starts[line_index] + 1


def _line_excerpt(text: str, line: int) -> str:
    lines = text.splitlines()
    if line > len(lines):
        return ""
    return lines[line - 1].strip()


def count_words(text: str) -> int:
    """Count words with the mechanical rules from ASD-STE100 section 8."""

    normalized = _QUOTED_TEXT_PATTERN.sub(" STEQUOTE ", text)
    previous = None
    while previous != normalized:
        previous = normalized
        normalized = _PARENTHETICAL_PATTERN.sub(" STEPAREN ", normalized)
    normalized = _NUMBER_UNIT_PATTERN.sub(" STEUNIT ", normalized)
    normalized = _URL_PATTERN.sub(" STEURL ", normalized)
    return len(_WORD_PATTERN.findall(normalized))


def _is_abbreviation(text: str, period_offset: int) -> bool:
    prefix = text[: period_offset + 1].lower()
    token_match = re.search(r"[a-z](?:[a-z.]*)\.$", prefix)
    if token_match is None:
        return False
    token = token_match.group(0)
    return token in _ABBREVIATIONS or bool(re.fullmatch(r"(?:[a-z]\.){2,}", token))


def _sentence_spans(text: str, base_offset: int) -> list[tuple[int, int]]:
    spans: list[tuple[int, int]] = []
    sentence_start = 0
    index = 0
    while index < len(text):
        character = text[index]
        if character not in ".!?":
            index += 1
            continue
        if character == "." and _is_abbreviation(text, index):
            index += 1
            continue
        boundary = index + 1
        while boundary < len(text) and text[boundary] in _CLOSING_PUNCTUATION:
            boundary += 1
        if boundary < len(text) and not text[boundary].isspace():
            index += 1
            continue
        if text[sentence_start:boundary].strip():
            spans.append((base_offset + sentence_start, base_offset + boundary))
        sentence_start = boundary
        while sentence_start < len(text) and text[sentence_start].isspace():
            sentence_start += 1
        index = sentence_start
    if text[sentence_start:].strip():
        spans.append((base_offset + sentence_start, base_offset + len(text)))
    return spans


def _paragraph_spans(
    text: str, input_format: Literal["markdown", "text"]
) -> list[tuple[int, int]]:
    spans: list[tuple[int, int]] = []
    paragraph_start: int | None = None
    offset = 0
    for line in text.splitlines(keepends=True):
        if line.strip():
            if input_format == "markdown" and re.match(r"^\s*#{1,6}\s+", line):
                if paragraph_start is not None:
                    spans.append((paragraph_start, offset))
                    paragraph_start = None
                spans.append((offset, offset + len(line)))
                offset += len(line)
                continue
            if input_format == "markdown" and re.match(
                r"^\s*(?:[-+*]|\d+[.)])\s+", line
            ):
                if paragraph_start is not None:
                    spans.append((paragraph_start, offset))
                paragraph_start = offset
                offset += len(line)
                continue
            if paragraph_start is None:
                paragraph_start = offset
        elif paragraph_start is not None:
            spans.append((paragraph_start, offset))
            paragraph_start = None
        offset += len(line)
    if paragraph_start is not None:
        spans.append((paragraph_start, len(text)))
    return spans


def _make_finding(
    source_text: str,
    source_path: Path,
    line_starts: list[int],
    offset: int,
    rule: str,
    severity: Severity,
    message: str,
) -> Finding:
    line, column = _source_location(line_starts, offset)
    return Finding(
        path=str(source_path),
        line=line,
        column=column,
        rule=rule,
        severity=severity,
        message=message,
        excerpt=_line_excerpt(source_text, line),
    )


def scan_text(
    text: str,
    source_path: Path,
    document_type: DocumentType,
    input_format: InputFormat,
) -> ScanReport:
    """Scan one text and return deterministic findings in source order."""

    resolved_format = _resolve_input_format(source_path, input_format)
    masked = (
        _mask_markdown(text) if resolved_format == "markdown" else MaskedText(text, 0)
    )
    checked_text = masked.text
    line_starts = _line_starts(text)
    findings: list[Finding] = []

    for match in _CONTRACTION_PATTERN.finditer(checked_text):
        findings.append(
            _make_finding(
                text,
                source_path,
                line_starts,
                match.start(),
                "4.2",
                "error",
                "Do not use contractions.",
            )
        )
    for match in re.finditer(";", checked_text):
        findings.append(
            _make_finding(
                text,
                source_path,
                line_starts,
                match.start(),
                "8.1",
                "error",
                "Do not use semicolons.",
            )
        )

    sentence_limit = (
        PROCEDURAL_WORD_LIMIT
        if document_type == "procedural"
        else DESCRIPTIVE_WORD_LIMIT
    )
    sentence_rule = "5.1" if document_type == "procedural" else "6.3"
    for paragraph_start, paragraph_end in _paragraph_spans(
        checked_text, resolved_format
    ):
        paragraph = checked_text[paragraph_start:paragraph_end]
        sentence_spans = _sentence_spans(paragraph, paragraph_start)
        if (
            document_type == "descriptive"
            and len(sentence_spans) > DESCRIPTIVE_PARAGRAPH_LIMIT
        ):
            first_content = paragraph_start + len(paragraph) - len(paragraph.lstrip())
            findings.append(
                _make_finding(
                    text,
                    source_path,
                    line_starts,
                    first_content,
                    "6.6",
                    "error",
                    f"Use no more than {DESCRIPTIVE_PARAGRAPH_LIMIT} sentences in a paragraph.",
                )
            )
        for sentence_start, sentence_end in sentence_spans:
            sentence_text = checked_text[sentence_start:sentence_end]
            word_count = count_words(sentence_text)
            if word_count > sentence_limit:
                first_content = (
                    sentence_start + len(sentence_text) - len(sentence_text.lstrip())
                )
                findings.append(
                    _make_finding(
                        text,
                        source_path,
                        line_starts,
                        first_content,
                        sentence_rule,
                        "error",
                        f"Sentence has {word_count} words. The limit is {sentence_limit}.",
                    )
                )

    for match in _PASSIVE_PATTERN.finditer(checked_text):
        findings.append(
            _make_finding(
                text,
                source_path,
                line_starts,
                match.start(),
                "3.6",
                "advisory",
                "Review possible passive voice. Use active voice when the agent is known.",
            )
        )
    for match in _ING_PATTERN.finditer(checked_text):
        if match.group(0).lower() in _ING_EXCEPTIONS:
            continue
        findings.append(
            _make_finding(
                text,
                source_path,
                line_starts,
                match.start(),
                "3.5",
                "advisory",
                "Review this -ing form. Use it only in an approved technical noun.",
            )
        )

    findings.sort(
        key=lambda finding: (
            finding.path,
            finding.line,
            finding.column,
            finding.rule,
            finding.severity,
        )
    )
    return ScanReport(
        path=str(source_path),
        document_type=document_type,
        input_format=resolved_format,
        findings=findings,
        skipped_regions=masked.skipped_regions,
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="check-asd-ste100",
        description=(
            "Check enforceable ASD-STE100 Issue 9 rules. "
            "This tool does not certify full compliance."
        ),
    )
    parser.add_argument(
        "targets", nargs="+", metavar="PATH", help="UTF-8 file or - for stdin"
    )
    parser.add_argument(
        "--document-type",
        choices=("descriptive", "procedural"),
        default="descriptive",
    )
    parser.add_argument(
        "--input-format", choices=("auto", "markdown", "text"), default="auto"
    )
    parser.add_argument("--format", choices=("text", "json"), default="text")
    parser.add_argument("--color", choices=("auto", "always", "never"), default="auto")
    parser.add_argument(
        "--no-color", action="store_true", help="Alias for --color never"
    )
    verbosity = parser.add_mutually_exclusive_group()
    verbosity.add_argument("--quiet", action="store_true")
    verbosity.add_argument("--verbose", action="store_true")
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Return exit code 1 when the report has advisories only",
    )
    return parser


def _read_reports(args: argparse.Namespace) -> list[ScanReport]:
    if args.targets.count("-") > 1:
        raise ValueError("standard input can be specified only once")
    reports: list[ScanReport] = []
    for target in args.targets:
        if target == "-":
            source_path = Path("<stdin>")
            text = sys.stdin.read()
        else:
            source_path = Path(target)
            text = source_path.read_text(encoding="utf-8")
        reports.append(
            scan_text(text, source_path, args.document_type, args.input_format)
        )
    reports.sort(key=lambda report: report.path)
    return reports


def _summary(reports: list[ScanReport]) -> dict[str, int]:
    findings = [finding for report in reports for finding in report.findings]
    return {
        "advisories": sum(item.severity == "advisory" for item in findings),
        "errors": sum(item.severity == "error" for item in findings),
        "files": len(reports),
    }


def _status(summary: dict[str, int]) -> Literal["fail", "pass", "warn"]:
    if summary["errors"]:
        return "fail"
    if summary["advisories"]:
        return "warn"
    return "pass"


def _format_duration(elapsed_seconds: float) -> str:
    if elapsed_seconds >= 1:
        return f"{elapsed_seconds:.2f}s"
    return f"{elapsed_seconds * 1000:.0f}ms"


def _use_color(args: argparse.Namespace) -> bool:
    if args.no_color or args.format != "text" or args.color == "never":
        return False
    if args.color == "always":
        return True
    return sys.stdout.isatty()


def _render_json(
    reports: list[ScanReport], args: argparse.Namespace, status: str
) -> str:
    findings = [asdict(finding) for report in reports for finding in report.findings]
    payload = {
        "status": status,
        "strict": args.strict,
        "document_type": args.document_type,
        "input_format": args.input_format,
        "summary": _summary(reports),
        "findings": findings,
        "skipped_regions": sum(report.skipped_regions for report in reports),
        "unchecked_rules": list(UNCHECKED_RULES),
    }
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"


def _render_text(
    reports: list[ScanReport],
    args: argparse.Namespace,
    status: str,
    elapsed_seconds: float,
) -> str:
    styles = Styles(_use_color(args))
    summary = _summary(reports)
    target = reports[0].path if len(reports) == 1 else f"{len(reports)} targets"
    status_label = status.upper()
    lines = [
        (
            f"{styles.status(status_label)}  check-asd-ste100  {target} "
            f"({_format_duration(elapsed_seconds)})"
        ),
        "",
        styles.section("Summary"),
        f"  Files:         {summary['files']:,}",
        f"  Errors:        {summary['errors']:,}",
        f"  Advisories:    {summary['advisories']:,}",
        f"  Document type: {args.document_type}",
    ]
    if args.quiet:
        return "\n".join(lines) + "\n"

    findings = [finding for report in reports for finding in report.findings]
    lines.extend(["", styles.section("Findings")])
    if findings:
        for finding in findings:
            label = styles.severity(finding.severity)
            lines.append(
                f"  {finding.path}:{finding.line}:{finding.column} "
                f"[{label} STE {finding.rule}] {finding.message}"
            )
    else:
        lines.append("  None.")

    if args.verbose:
        lines.extend(
            [
                "",
                styles.section("Diagnostics"),
                f"  Skipped regions: {sum(report.skipped_regions for report in reports):,}",
                "",
                styles.section("Unchecked Rules"),
            ]
        )
        lines.extend(f"  - {rule}" for rule in UNCHECKED_RULES)
    return "\n".join(lines) + "\n"


def main(argv: Sequence[str] | None = None) -> int:
    """Run the CLI and return its process exit code."""

    args = _parser().parse_args(argv)
    start = time.perf_counter()
    try:
        reports = _read_reports(args)
    except (OSError, UnicodeError, ValueError) as error:
        print(f"check-asd-ste100 failed: {error}", file=sys.stderr)
        return EXIT_ERROR

    summary = _summary(reports)
    status = _status(summary)
    if args.format == "json":
        sys.stdout.write(_render_json(reports, args, status))
    else:
        sys.stdout.write(
            _render_text(reports, args, status, time.perf_counter() - start)
        )
    if summary["errors"] or (args.strict and summary["advisories"]):
        return EXIT_FINDINGS
    return EXIT_PASS


if __name__ == "__main__":
    raise SystemExit(main())
