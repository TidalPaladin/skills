---
name: cli-design
description: Design or review CLI flags, output, progress, and exit behavior.
---

# CLI Design

Preserve the existing command contract unless the task includes changing it.
Use the relevant sections of
[CLI conventions](references/cli-design.md) for output or flag design.

Choose features that serve the command. A small command does not need every
format, verbosity, color, or progress option.

Keep primary data on stdout and diagnostics on stderr. Structured output must
remain parseable and free of terminal escapes. Define exit codes that distinguish
success, reported findings, and execution failure.

For new output modes, specify precedence, deterministic ordering, and behavior
with redirected streams. Test applicable terminal, pipe, error, and machine
output paths. Report the resulting contract and validation.
