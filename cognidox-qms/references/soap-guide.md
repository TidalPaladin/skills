# Cognidox SOAP Integration Boundary

## Current Boundary

Use REST for all supported skill operations. Do not execute Cognidox SOAP requests from this skill.

The REST PAT does not authenticate the tested SOAP service. Do not attempt to reuse it for SOAP.

The available Cognidox CLI can access these workflows. Its license is proprietary and all rights are reserved. Do not copy or include that CLI in this repository.

SOAP endpoints and WSDL files contain tenant-specific data. Do not commit a hostname, WSDL, document identifier, or policy record.

For allowed REST gaps, use the guarded authenticated-browser workflow in `browser-workflows.md`. Do not use web search or undocumented SOAP requests as a fallback.

## SOAP Capabilities

The SOAP service describes operations for:

- Review request creation, cancellation, and status.
- Approval request lists and approval queues.
- Document signatures.
- Policy and document tasks.
- Native form data and form searches.
- Reports, briefcases, and saved searches.
- Document publication and obsolescence.

SOAP operations are not implemented by this skill. Review requests and approval requests can use the guarded browser path, but that does not authorize SOAP. Actual approval, rejection, signature, publication, unpublication, obsolescence, policy tasks, and other prohibited actions remain outside the skill boundary.

## Prerequisites For A Future Licensed Integration

Before implementation:

1. Obtain a licensed Cognidox client or written permission to implement the required protocol.
2. Obtain a supported SOAP authentication method from Cognidox.
3. Retrieve the current WSDL at run time.
4. Define the exact request, notification, and cancellation semantics.
5. Add deterministic plans and exact approval gates without weakening the browser or REST contracts.
6. Test only with an intentionally selected non-production record.

Any future action that sends a request to another user must require current approval for the exact plan ID. A future non-browser integration must use a notification-specific confirmation flag.
