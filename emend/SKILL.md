---
name: emend
description: Edit prose to remove AI-like phrasing and apply ASD-STE100 Simplified Technical English to technical documents and user communication. Use when asked to draft, revise, review, or clean prose, documentation, reports, articles, essays, headings, comments, release notes, or an explicit target passed to `$emend`. Preserve a requested creative or nontechnical style.
---

# Emend

## Overview

Remove AI-like texture while you preserve meaning, facts, attribution, and domain terms.

Use ASD-STE100 Issue 9 for technical text and technical user communication. Read
`references/asd-ste100.md` before you write or edit technical text.

Read `references/ai-writing-detection.md` for a full prose pass, a long document, or a strict cleanup.

## Invocation Contract

Support these forms:

- `$emend`
- `$emend <path-or-prose-target> ...`

Select targets in this order:

1. If the user gives targets, edit or review only those targets.
2. If the user gives no target, use changed prose or documentation files.
3. If there are no applicable changes, select prose or documentation at your discretion.

When you select a target:

- Prefer user-facing prose before internal notes.
- Prefer documents with generic phrasing, weak sourcing, or dramatic headings.
- Do not make broad changes unless the user requests them.

## Target Classification

Treat documentation, reports, instructions, explanations, code comments, release notes, and professional messages as technical text.

Treat text as nontechnical only when the user requests creative, literary, personal, or other expressive prose. Examples include fiction, fantasy, and poetry.

An explicit user style requirement takes precedence. Also preserve mandatory legal, regulatory, academic, and contractual wording.

## Editing Rules

1. Preserve the factual scope and the writer's domain terms.
2. Replace vague claims with specific, verifiable facts from the available source.
3. Remove filler, empty transitions, and unnecessary intensifiers.
4. Use plain verbs and concrete nouns.
5. Use headings that describe the section content.
6. Attribute only what a person or source said or did.
7. Name the exact part, date, version, mechanism, or policy in a comparison.
8. Do not invent numbers, sources, quotations, or attribution.
9. Remove em dashes outside safe zones.
10. For technical text, apply the ASD-STE100 rules in the reference.

## Safe Zones

Do not change these items unless the user requests the change:

- Direct quotations from cited sources
- Titles, names, identifiers, and other verbatim values
- Code, configuration, commands, output, and markup examples
- Mandatory legal, regulatory, academic, or contractual wording

If a safe zone contains a flagged pattern, preserve it. Report the reason when the result includes findings.

## Workflow

1. Resolve and classify the target.
2. Read the applicable references.
3. Verify facts, scope, attribution, and required wording.
4. Remove AI-like patterns without changing the meaning.
5. For technical text, apply ASD-STE100 after the factual pass.
6. Run the local checker on applicable UTF-8 text or Markdown files:

   ```text
   python scripts/check_asd_ste100.py --document-type descriptive PATH
   python scripts/check_asd_ste100.py --document-type procedural PATH
   ```

7. Correct deterministic findings. Review each advisory in its technical context.
8. Complete the manual checklist in `references/asd-ste100.md`.
9. Do not state that the text is fully compliant from the local checker alone.

## Final Check

- Confirm that each changed claim has support in the source.
- Confirm that terminology is consistent.
- Remove contractions, em dashes, and semicolons from technical text outside safe zones.
- Check sentence and paragraph limits.
- Check active voice, verb forms, technical nouns, technical verbs, and safety instructions manually.
- Read the result for clarity and correct technical meaning.

## Output Contract

Use ASD-STE100 in the response unless the user requests nontechnical prose.

Return a concise summary with:

- The selected targets
- The primary changes
- Claims that need a source or user decision
- Safe-zone text that you preserved
- Validation commands and remaining failures when you edit files
