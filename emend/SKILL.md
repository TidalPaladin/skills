---
name: emend
description: Revise or review prose for clarity and factual precision, using ASD-STE100 for technical text.
---

# Emend

Accept `$emend` with prose or file targets. Without a target, use changed
prose first, then a document with a concrete clarity problem.

Preserve meaning, evidence, attribution, and domain terms. Remove filler,
vague claims, unnecessary intensifiers, and dramatic headings. Use plain verbs
and concrete nouns. Do not infer authorship from writing style.

For technical documents, read
[ASD-STE100 guidance](references/asd-ste100.md).
Apply that standard to technical communication. Preserve a requested creative
or nontechnical style. For a full prose review, also use
[editing patterns](references/ai-writing-detection.md).

Preserve quotations, names, titles, identifiers, code, commands, and mandatory
legal or regulatory wording unless the task authorizes changing them.
Do not invent evidence or replace domain terms merely to satisfy a word list.

For edited files, run the bundled checker from this skill directory:

```bash
uv run python scripts/check_asd_ste100.py --document-type procedural PATH
uv run python scripts/check_asd_ste100.py --document-type descriptive PATH
```

Choose the document type for the text. Correct deterministic findings and
review advisories in context. Use the manual checklist for technical wording.
The checker does not establish formal compliance.

Report the main changes, verification limits, and any claim that still needs
evidence. Keep short edits and their responses short.
