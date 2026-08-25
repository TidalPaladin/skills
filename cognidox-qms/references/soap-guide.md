# Cognidox SOAP Integration Boundary

## Current Boundary

Use REST for all supported skill operations. Do not execute Cognidox SOAP requests from this skill.

The REST PAT does not authenticate the tested SOAP service. Review requests, approval queues, policy tasks, and signatures require a separate SOAP authentication path.

The available Cognidox CLI can access these workflows. Its license is proprietary and all rights are reserved. Do not copy or include that CLI in this repository.

SOAP endpoints and WSDL files contain tenant-specific data. Do not commit a hostname, WSDL, document identifier, or policy record.

## Deferred Capabilities

The SOAP service describes operations for:

- Review request creation, cancellation, and status.
- Approval request lists and approval queues.
- Document signatures.
- Policy and document tasks.
- Native form data and form searches.
- Reports, briefcases, and saved searches.
- Document publication and obsolescence.

These operations are not authorized or implemented by this skill.

## Prerequisites For A Licensed Integration

Before implementation:

1. Obtain a licensed Cognidox client or written permission to implement the required protocol.
2. Obtain a supported SOAP authentication method from Cognidox.
3. Retrieve the current WSDL at run time.
4. Define the exact request, notification, and cancellation semantics.
5. Add deterministic plans and exact approval gates.
6. Test only with an intentionally selected non-production record.

Any action that sends a request to another user must require current approval for the exact plan ID. The integration must use a notification-specific confirmation flag.
