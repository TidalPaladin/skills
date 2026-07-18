---
name: citation-verifier
description: Verify academic citations in scholarly writing by confirming that the cited work exists, its bibliographic metadata is correct, and the source supports the surrounding claim. Use for every new or changed academic citation and for systematic citation audits.
---

# Citation Verifier

Verify one citation occurrence at a time. Treat repeated uses of the same work
as separate claim checks when their surrounding claims differ.

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
