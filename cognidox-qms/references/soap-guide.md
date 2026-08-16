# Cognidox SOAP Guide

## Use REST First

The REST API covers the v1 read workflows. Use SOAP as reference material when a user asks for workflows that REST does not expose or when comparing legacy behavior.

SOAP endpoints and WSDLs are tenant-specific. Obtain the current WSDL from Cognidox support or the configured tenant when SOAP research is required. Do not commit tenant hostnames or tenant-derived WSDLs to a public repository.

## Useful SOAP Capability Map

Read/search:
- `CogniDoxDocSearch`
- `CogniDoxDocInfo`
- `CogniDoxDocSecurity`
- `CogniDoxDocLockInfo`
- `CogniDoxDocFileInfo`
- `CogniDoxDocRelationships`
- `CogniDoxDocTemplates`
- `CogniDoxDocReviewStatus`

Categories and repository:
- `CogniDoxCategorySearch`
- `CogniDoxCategoryList`
- `CogniDoxCategoryInfo`
- `CogniDoxCategoryTitles`
- `CogniDoxSystemInfo`
- `CogniDoxListDocumentTypes`
- `CogniDoxListFilenameExtensions`

Tasks, reviews, policy work:
- `CogniDoxListReviewRequests`
- `CogniDoxListApprovalRequests`
- `CogniDoxListPolicyTasks`
- `CogniDoxTasksListTypes`
- `CogniDoxTasksListDocumentTaskRequests`
- `CogniDoxTasksListDocumentTasks`
- `CogniDoxTasksListUserTasks`
- `CogniDoxTasksListUserTaskRequests`

Forms and reports:
- `CogniDoxListForms`
- `CogniDoxDocFormData`
- `CogniDoxDocFormSearch`
- `CogniDoxCustomReportList`
- `CogniDoxDocCustomReportSearch`
- `CogniDoxListCustomReports`

Briefcases and saved searches:
- `CogniDoxBriefcaseList`
- `CogniDoxBriefcaseCompartmentsList`
- `CogniDoxListSavedSearches`
- `CogniDoxDocSavedSearch`

Write and workflow actions to keep disabled in v1:
- create/delete/rename category
- create/delete/rename/obsolete/unobsolete/publish/unpublish document
- create versions or add PDF versions
- checkout/checkin
- create/cancel reviews
- sign documents
- create/forward/cancel/set task state
- briefcase add/remove/rename actions
- license creation/deletion

## SOAP Implementation Notes

Do not add SOAP execution unless REST lacks a required read-only operation. If SOAP execution is needed later, first determine the authentication mechanism from Cognidox support or a known working client. Do not assume the REST PAT applies to SOAP.
