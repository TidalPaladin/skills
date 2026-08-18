# ASD-STE100 Simplified Technical English

## Contents

- Baseline and limits
- Priority and classification
- Controlled vocabulary and terminology
- Grammar and sentence structure
- Procedural writing
- Descriptive writing
- Safety instructions
- Punctuation and word count
- Examples
- Local checker
- Manual checklist

## Baseline and Limits

Use [ASD-STE100 Issue 9](https://www.asd-ste100.org/assets/files/ASD-STE100_ISSUE9.pdf), dated January 15, 2025.

The standard has 53 writing rules and a controlled dictionary. This reference summarizes the rules that apply most often.

Use the official standard for the approved dictionary, meanings, parts of speech, technical term categories, and complete rules.

Do not claim formal compliance from this summary or the local checker. A human must review the text against the official standard.

## Priority and Classification

Use ASD-STE100 for technical documents and default user communication.

Do not apply it when the user requests fiction, fantasy, poetry, literary prose, or another nontechnical style.

Follow an explicit user or project style requirement when it conflicts with this reference.

Preserve direct quotations, code, commands, identifiers, and mandatory legal or regulatory wording.

Classify each technical section as one of these types:

- Procedural text tells the reader how to do a task.
- Descriptive text gives information about an item, system, result, or concept.

## Controlled Vocabulary and Terminology

- Use words that the official dictionary approves.
- Use each approved word only with its approved meaning and part of speech.
- Use approved verb and adjective forms.
- Use short technical nouns that the company, industry, or subject field approves.
- Use one technical noun for one item.
- Do not use a technical noun as a verb unless it is also an approved technical verb.
- Use technical verbs only for their approved technical process.
- Use American English unless an applicable directive requires a different spelling.

Do not replace a domain term only because it is absent from the controlled dictionary. First, check its technical noun or technical verb category.

## Grammar and Sentence Structure

- Prefer a multi-word noun of three words or fewer.
- Introduce a long technical noun before you use an approved short form.
- Use only simple approved verb forms and tenses.
- Use an `-ing` form only in an approved technical noun.
- Use active voice when the agent is known.
- Use a direct verb for an action when the dictionary approves that verb.
- Do not omit necessary words.
- Do not use contractions.
- Use a vertical list for complex information.
- Use articles and demonstrative adjectives when they are necessary.

## Procedural Writing

- Use no more than 20 words in a sentence.
- Give one instruction in each sentence.
- Combine actions only when they occur at the same time.
- Use the imperative form for an instruction.
- Put a necessary condition before the command.
- Separate the condition from the command with a comma.
- Use notes for information, not instructions.

## Descriptive Writing

- Use no more than 25 words in a sentence.
- Give information gradually.
- Give each sentence one primary topic.
- Use key words and phrases to connect related information.
- Put related information in one paragraph.
- Give each paragraph one topic.
- Use no more than six sentences in a paragraph.

## Safety Instructions

- Identify the risk level with the applicable word or symbol.
- Start with a clear command or condition.
- Explain the risk or possible result.
- Use the risk categories that the applicable industry or project defines.

## Punctuation and Word Count

- Do not use a semicolon.
- Use hyphens to connect words that function as one unit.
- Use parentheses only for the purposes that the standard permits.
- Count a parenthetical expression as one word.
- Count a number with its unit as one word.
- Count an abbreviation, identifier, quoted text, title, label, or proper noun as one word.
- Count a hyphenated group as one word.

## Examples

### Procedure

Non-STE:

```text
Prior to commencing the pressure test, ensure that the valve has been placed in the closed position.
```

STE:

```text
Before you start the pressure test, close the valve.
```

### Description

Non-STE:

```text
The inlet pressure is continuously monitored by the controller, which then provides a signal that causes the pump to start.
```

STE:

```text
The controller monitors the inlet pressure. It sends a signal to the pump. The signal starts the pump.
```

### Long Technical Noun

Non-STE:

```text
battery temperature monitoring system warning threshold
```

STE:

```text
warning limit for the battery temperature monitor
```

### User Communication

Non-STE:

```text
It is worth noting that the validation wasn't successful due to the fact that the input file could not be located.
```

STE:

```text
The validation failed because the input file does not exist.
```

## Local Checker

Run the checker from the `emend` skill directory:

```text
python scripts/check_asd_ste100.py --document-type descriptive PATH
python scripts/check_asd_ste100.py --document-type procedural PATH
cat PATH | python scripts/check_asd_ste100.py - --format json
```

The checker reports these deterministic findings:

- Contractions
- Semicolons
- Sentence word limits
- Descriptive paragraph sentence limits

The checker reports possible passive voice and `-ing` forms as advisories. Use `--strict` to make advisories return exit code 1.

The checker skips Markdown front matter, fenced code, inline code, and block quotations.

Use `--verbose` or JSON output to see the rule categories that require manual review.

## Manual Checklist

- [ ] Verify each general word in the official controlled dictionary.
- [ ] Verify the approved meaning and part of speech.
- [ ] Verify technical nouns and technical verbs against the applicable terminology source.
- [ ] Use one term for each item or process.
- [ ] Check multi-word nouns and approved short forms.
- [ ] Check verb forms, tenses, active voice, and direct action verbs.
- [ ] Check procedure or description sentence limits.
- [ ] Check paragraph length and topic focus.
- [ ] Check instruction count, imperative form, conditions, and notes.
- [ ] Check each safety level, command or condition, and risk explanation.
- [ ] Check punctuation and the complete word-count rules.
- [ ] Confirm that the final text keeps the correct technical meaning.
