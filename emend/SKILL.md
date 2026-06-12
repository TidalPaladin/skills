---
name: emend
description: Edit prose so it reads like researched human writing, not AI output. Use when asked to draft, revise, review, or clean prose, documentation, reports, articles, essays, headings, comments, release notes, or any explicit target passed to `$emend`.
---

# Emend

## Overview

Use this skill to remove AI-like texture from prose while preserving the writer's meaning, facts, and domain voice.

The full banned-term reference is `references/ai-writing-detection.md`. Read it for a full prose pass, for long documents, or whenever the user asks for strict cleanup.

## Invocation Contract

Supported forms:
- `$emend`
- `$emend <path-or-prose-target> ...`

Target priority:
1. If one or more targets are passed, edit or review only those targets.
2. If no target is passed and prose or docs have active working-tree changes, use those changed files.
3. If no target and no relevant changes exist, choose prose or documentation targets at your discretion.

When choosing targets at discretion:
- Prefer user-facing prose before internal notes.
- Prefer docs with repeated generic phrasing, dramatic headings, or weak sourcing.
- Avoid broad churn across many files unless the user asks for it.

## Editing Rules

1. Remove every em dash. Use a period, comma, semicolon, colon, parentheses, or a rewritten sentence.
2. Replace vague claims with specific, checkable facts. If the needed fact is missing, either ask for it or cut the claim.
3. Remove filler openers, empty transitions, and intensifiers that do not add evidence.
4. Use plain verbs and concrete nouns. Prefer the simplest word that preserves the technical meaning.
5. Keep headings descriptive. A heading should name the section content, not tease it.
6. Vary paragraph shape and sentence rhythm when the text has repeated section templates.
7. Attribute only what a person or source actually said or did. Do not infer motives, beliefs, or positions from related actions.
8. When contrasting two things, name the part, date, version, mechanism, policy, or supply-chain change that makes the difference real.
9. Preserve the writer's domain voice. Remove AI texture without flattening useful specificity.
10. Do not invent numbers, sources, quotations, or attribution while making prose more concrete.

## Safe Zones

Do not flag or rewrite these unless the user explicitly asks:
- Direct quotes from cited sources.
- Titles, names, identifiers, and other verbatim source text.
- Code, configuration, command output, and markup examples.
- Required legal, regulatory, or academic wording.

If a banned pattern appears in a safe zone, leave it alone and mention the reason if reporting findings.

## Workflow

1. Resolve the target using the invocation contract.
2. For a full pass, read `references/ai-writing-detection.md` before editing.
3. Scan the target for:
   - em dashes,
   - banned verbs, adjectives, transitions, and filler phrases from the reference,
   - hollow claims that end on importance instead of detail,
   - unsupported numbers or attribution,
   - dramatic headings,
   - repeated paragraph or section shapes,
   - overloaded hedging,
   - hallucinated AI markup artifacts.
4. Rewrite conservatively:
   - Keep factual scope unchanged unless the source material supports a stronger claim.
   - Replace generic phrasing with concrete details already present in the target.
   - Cut unsupported claims rather than making up support.
   - Mark any facts that need source verification instead of inventing citations.
5. Run a final self-check:
   - Search for em dashes and remove all matches.
   - Recheck headings for descriptive wording.
   - Confirm every changed claim remains attributable to the available source text.
   - Read the result for natural phrasing.

## Output Contract

Return a concise summary with:
- Targets selected and why.
- Main prose issues fixed.
- Any claims that still need sourcing or user input.
- Any safe-zone text intentionally left unchanged.

When editing files, also report validation commands run and any remaining failures.
