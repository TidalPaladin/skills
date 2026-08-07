# Cognidox REST API Guide

## Basics

- Default base URL: `https://medcognetics.cdox.net/api/v1.0`
- OpenAPI file: `references/openapi.yml`
- Auth: bearer Personal Access Token from `~/.codex/env/cognidox`
- Required v1 scopes: `read:repository`, `read:categories`, `read:documents`
- OAuth2 authorization-code auth also exists, but v1 uses the PAT path.

## Read-Only Endpoints

| Purpose | Method | Path | Scope |
| --- | --- | --- | --- |
| Server metadata | `GET` | `/repository` | `read:repository` |
| Server options | `GET` | `/repository/options` | `read:repository` |
| Document types | `GET` | `/repository/documentTypes` | `read:repository` |
| Types for extension | `GET` | `/repository/documentTypes/{extension}` | `read:repository` |
| Extensions for type | `GET` | `/repository/extensions/{documentType}` | `read:repository` |
| Root category | `GET` | `/categories` | `read:categories` |
| Category by ID | `GET` | `/categories/{categoryId}` | `read:categories` |
| New-document recommendations | `POST` | `/categories/recommendations/{categoryId}` | `read:categories` |
| Document search | `POST` | `/repository/documents` | `read:documents` |
| Document info | `GET` | `/documents/{partNumber}` | `read:documents` |
| Document constraints | `GET` | `/documents/constraints/{partNumber}` | `read:documents` |
| Document lock | `GET` | `/documents/locks/{partNumber}` | `read:documents` |
| Document permissions | `GET` | `/documents/permissions/{partNumber}` | `read:documents` |
| Document templates | `GET` | `/documents/templates/{partNumber}` | `read:documents` |
| Version metadata | `GET` | `/documents/versions/{partNumber}/{version}` | `read:documents` |
| Version slice | `GET` | `/documents/versions/{partNumber}/{version}/{index}` | `read:files` |

## Search

`POST /repository/documents` requires a non-empty request body. Cognidox returned `400` for `{}` during live exploration.

Common criteria:

```json
{
  "title": "quality manual",
  "partNumber": ["DM-000401-AN"],
  "categoryId": 123,
  "published": true,
  "versionInformation": "1A"
}
```

Other supported criteria in the OpenAPI include `metadata`, `license`, `savedSearchId`, `reportId`, `compartmentId`, and `inMainBriefcase`.

## Category Browsing

Use `filter` query parameters to choose returned sections:

- `details`
- `children`
- `documents`
- `categories`

Repeat `filter` for multiple values, for example:

```text
/categories?filter=details&filter=categories&filter=documents&limit=25
```

Use `offset` and `limit` for paged `documents` and `categories` arrays.

## Document Inspection

`GET /documents/{partNumber}` accepts repeated `filter` values:

- `details`
- `latest`
- `versions`
- `workspaces`

Live exploration confirmed document info, constraints, lock, permissions, templates, and version metadata. Some visible documents may not have a latest version available to the token; handle missing versions as a normal response.

## Future Write Surfaces

Document but do not call these in v1:

| Operation | Method/path | Scope |
| --- | --- | --- |
| Create category | `POST /categories` | `write:categories` |
| Update category | `PATCH /categories/{categoryId}` | `write:categories` |
| Delete category | `DELETE /categories/{categoryId}` | `write:categories` |
| Create document | `POST /documents` | `write:documents` |
| Create form document | `POST /documents/forms/{categoryFormId}` | `write:documents` |
| Create temporary document from template | `POST /documents/templates/{partNumber}` | `write:documents` |
| Create document version | `POST /documents/versions/{partNumber}` | `write:documents` |
| Upload version slice | `PATCH /documents/versions/slices/{index}/{uploadId}` | `write:files` |
| Update document | `PATCH /documents/{partNumber}` | `write:documents` |
| Delete document | `DELETE /documents/{partNumber}` | `write:documents` |
| Client logger | `POST /logger` | `write:logger` |

Before implementing any write surface, require user approval, define dry-run behavior, and validate against a sandbox or intentionally selected non-production record.
