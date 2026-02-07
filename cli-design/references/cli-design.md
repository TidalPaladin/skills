# CLI Design Reference

Design principles for CLI tools. Follow these conventions when building new CLI tools or extending existing ones.

## Table of Contents

- [Color Palette](#color-palette)
- [Status-Line Header](#status-line-header)
- [Section Layout](#section-layout)
- [Aligned Key-Value Pairs](#aligned-key-value-pairs)
- [Unicode Status Symbols](#unicode-status-symbols)
- [Progressive Disclosure](#progressive-disclosure)
- [Number Formatting](#number-formatting)
- [Deterministic Output](#deterministic-output)
- [Breakdown Tables](#breakdown-tables)
- [Color Control](#color-control)
- [Dual Output Format](#dual-output-format)
- [Exit Codes](#exit-codes)
- [Progress Feedback](#progress-feedback)
- [stdout vs stderr](#stdout-vs-stderr)
- [Error Reporting](#error-reporting)
- [JSONL for Streaming](#jsonl-for-streaming)
- [Unix Composability](#unix-composability)

## Color Palette

Use color semantically, not decoratively.

| Role | Color | ANSI code | Usage |
|------|-------|-----------|-------|
| Structure | Cyan | `36` | Section headers, progress bar fill |
| Data values | Yellow | `33` | User-provided values, computed results, counts |
| Success | Green (bold) | `1;32` | PASS/OK status word, `✓` checkmark |
| Warning status | Yellow (bold) | `1;33` | WARN status word |
| Failure | Red (bold) | `1;31` | FAIL status word, `✗` cross |
| Error text | Red | `31` | Error-severity labels |
| Warning text | Yellow | `33` | Warning-severity labels |
| Info text | Cyan | `36` | Info-severity labels |
| Inactive / zero | Dim | `2` | Counts that are zero, unavailable data |
| Section headers | Bold | `1` | Section titles (optionally combined with cyan) |

## Status-Line Header

For tools with pass/fail semantics, the first line of output is a single-line summary. Format:

```
STATUS  tool-name  target  (duration)
```

- **STATUS** is a bold colored word (e.g., `PASS`/`FAIL`, `OK`/`WARN`).
- **tool-name** is the binary name, uncolored.
- **target** is the primary input (path, URL, resource identifier).
- **duration** is parenthesized, formatted as `1.25s` (>= 1s) or `340ms` (< 1s).

Print a blank line after the header before the first section.

For tools without pass/fail semantics, use a two-line title variant (title + underline) with an optional final status line at the bottom:

```
My Tool Name
============

...sections...

Status: PASSED
```

## Section Layout

Organize output into labeled sections separated by blank lines.

```
Section Name
  key:   value
  key2:  value2

Next Section
  ...
```

- Section names are **bold** (optionally combined with cyan for emphasis).
- Indent content by **2 spaces**.
- Separate sections with exactly **one blank line**.

## Aligned Key-Value Pairs

Within a section, right-pad labels so values align vertically:

```
  Name:       my-widget
  Version:    1.2.3
  Status:     active
  Created:    2025-01-15
```

Determine the padding width per-section, not globally. Use fixed padding within each section (e.g., the widest label in that group plus 2-4 spaces).

## Unicode Status Symbols

Use `✓` (green) for pass/enabled and `✗` (red) for fail/disabled.

Use these for boolean states and per-item verification results. For non-boolean states, use explicit text labels (e.g., `active`, `degraded`, `offline`) with semantic color.

If terminal/font compatibility is uncertain, provide an ASCII fallback (`+` / `x`) via a dedicated flag (for example, `--ascii`) or automatically when Unicode output is disabled.

## Progressive Disclosure

Support three verbosity tiers via `--quiet` and `--verbose` flags:

| Mode | Content |
|------|---------|
| `--quiet` | Header + summary only (top-level totals) |
| Default | Header + summary + full detail sections |
| `--verbose` | Default + diagnostics / extra metadata |

In quiet mode, return early after rendering the summary to avoid computing detail sections.

Treat `--quiet` and `--verbose` as mutually exclusive and have the argument parser reject invalid combinations.

## Number Formatting

- Use **thousand separators** (commas) for counts: `1,234,567`.
- Use **contextual decimal precision**: choose precision based on what the number represents (e.g., `.2` for percentages and durations in seconds, `.1` for latencies in ms, higher precision for scientific values).
- Display ranges as `min=X max=Y` in a single line when both endpoints exist.

## Deterministic Output

Text and JSON output should be deterministic for the same input:

- Sort collections with stable rules (alphabetical by default unless domain semantics require another order).
- Keep key ordering consistent in JSON output.
- Avoid including wall-clock timestamps unless explicitly requested or necessary.

## Breakdown Tables

For categorical distributions, render aligned tables with count and percentage columns:

```
  category_name
    category  count  percent
    typeA        10   62.50%
    typeB         5   31.25%
    unknown       1    6.25%
```

- Sort rows alphabetically, with unknown/other buckets last.
- Right-align count and percent columns.
- Compute column widths dynamically from data.

## Color Control

Always provide `--color {auto|always|never}` and `--no-color` (alias for `--color never`).

Resolution logic (pseudocode):

```
function resolve_color(output_format, color_mode, no_color):
    if no_color:
        return false
    if output_format != "text":
        return false          // never color structured output
    if color_mode == "always":
        return true
    if color_mode == "never":
        return false
    return stdout.is_terminal()  // auto
```

- `--no-color` takes precedence over `--color` if both are provided.
- Structured output formats (JSON, CSV) disable color unconditionally.
- Auto mode checks `stdout.is_terminal()`.

Implement color through a centralized styles module so all color can be globally disabled via a single flag. In Rust, either raw ANSI escapes via a `Styles` struct or the `colored` crate work well. In Python, `colorama` or `rich` serve the same purpose.

## Dual Output Format

Support `--format {text|json}` (default: `text`).

- **Text**: human-readable, colored output as described in this document.
- **JSON**: machine-readable, pretty-printed. Contains the same data model as text but structured for programmatic consumption.

When `--format json` is selected:
- Disable color unconditionally.
- Disable progress bars/spinners by default to keep automated runs clean and predictable.
- Write the JSON to stdout as a single document.

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success / pass |
| `1` | Tool ran correctly but found problems (e.g., validation failures) |
| `2` | Runtime error (crash, I/O failure, invalid arguments) |

Distinguish between "the tool ran correctly and found problems" (exit 1) and "the tool itself failed" (exit 2). For tools without a pass/fail concept, exit 0 on success and 2 on error.

## Progress Feedback

Use a progress library (`indicatif` in Rust, `tqdm`/`rich` in Python, `ora`/`cli-progress` in Node) for progress indication.

**Progress bars** for bounded work (known item count):
```
Processing files [=========>                    ] 1,234/5,678 (2m 30s)
```

**Spinners** for unbounded work:
```
⠋ Scanning directory...
```

- Progress bars use cyan/blue fill.
- Spinners use cyan.
- Clear progress output when done so it doesn't linger in the final output.
- Tick spinners at ~80ms intervals, progress bars at ~100ms.
- Write progress to **stderr** so stdout remains clean for piping.
- Support `--progress {auto|always|never}` where auto disables progress when stderr is not a terminal.

## stdout vs stderr

Reserve **stdout** for primary output — the data the user asked for. Everything else goes to **stderr**.

| Stream | What goes here |
|--------|----------------|
| stdout | Report output, JSON documents, JSONL records, piped data |
| stderr | Progress bars, spinners, error messages, warnings, debug/diagnostic logs |

This separation is what makes CLI tools composable. When a user pipes output to `jq`, a file, or another program, progress and errors stay visible in the terminal while clean data flows through the pipe.

Rules of thumb:
- If it would corrupt `--format json` output, it belongs on stderr.
- If it's ephemeral (progress, status updates), it belongs on stderr.
- If a downstream program should consume it, it belongs on stdout.

## Error Reporting

Print runtime errors to **stderr** with the tool name prefix:

```
my-tool failed: <error message with context>
```

Use error chaining to preserve context (e.g., `anyhow` in Rust, chained exceptions in Python). Print the full cause chain so users can diagnose the root issue.

## JSONL for Streaming

When a tool produces streaming or append-only results (e.g., writing to a long-running output file, emitting records as they're processed), use newline-delimited JSON (JSONL) rather than a single JSON document. This allows consumers to process records incrementally.

## Unix Composability

Design tools to work well in shell pipelines:

- Write primary output to **stdout**, progress/diagnostics to **stderr**.
- When stdout is not a terminal and color is `auto`, disable color automatically.
- Support structured output (`--format json`) for downstream tooling (`jq`, scripts).
- Use meaningful exit codes so callers can branch on success/failure.
- Keep text output grep-friendly: consistent prefixes, one logical item per line.
