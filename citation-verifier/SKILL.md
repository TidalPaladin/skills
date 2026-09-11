---
name: citation-verifier
description: Verify new or changed academic citations, or audit existing citations against their surrounding claims.
---

# Citation Verifier

Verify one citation occurrence at a time. Treat repeated uses of the same work
as separate claim checks when their surrounding claims differ.

## Parent Assignment

For every citation-verification task, the parent agent must invoke `citation_verifier`.
Establish source order and assign exactly one citation occurrence to each instance.
Include the source path, line or unique context, citation key, complete surrounding claim, and bibliography entry.
Use waves of at most eight instances and preserve their read-only permission mode.
Then consolidate citation reports in source order.
An assigned verifier checks its occurrence directly and does not delegate again.

## Workflow

1. Record the source path, line or unique location, citation key, and complete
   surrounding claim.
2. Read the matching bibliography entry. Identify the intended work from its
   authors, title, venue, year, pages, DOI, ISBN, or stable identifier.
3. Confirm that the work exists using authoritative sources. Prefer the
   publisher, DOI registration record, standards body, official proceedings,
   institutional repository, or the work itself. Use search results only to
   locate stronger sources.
4. Compare every material bibliography field with the authoritative record.
5. Read enough of the cited work to determine whether it supports the complete
   claim in context. Check population, method, assumptions, comparison,
   direction, magnitude, limitations, and whether the citing document
   overstates a result.
6. Report one status:
   - `VERIFIED`: the work and metadata are correct, and the source supports the
     complete claim.
   - `PARTIAL`: the source supports only part of the claim or requires narrower
     wording.
   - `INACCURATE`: the work, metadata, or attribution is wrong, or the source
     contradicts the claim.
   - `UNVERIFIABLE`: authoritative evidence or the necessary full text could
     not be obtained.

## Report

Return this compact structure:

```text
Status: VERIFIED | PARTIAL | INACCURATE | UNVERIFIABLE
Occurrence: path:line or unique location, citation-key
Claim: complete claim being checked
Bibliography: correct | corrections needed
Evidence: concise explanation tied to the source
Sources: authoritative links or identifiers
Recommended action: none | exact metadata or prose correction
```

Do not infer support from a matching title, abstract keyword, or secondary
summary. Do not fabricate inaccessible details. Quote sparingly, distinguish
direct evidence from inference, and state access limitations explicitly.
