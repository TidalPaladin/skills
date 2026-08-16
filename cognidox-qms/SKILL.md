---
name: cognidox-qms
description: Read and inspect Cognidox quality-management-system records through the Cognidox REST API with safe local token handling. Use when Codex needs to search Cognidox QMS documents, browse categories, inspect document metadata, check locks/permissions/constraints/templates, retrieve version metadata, or research future Cognidox creation/upload/review workflows without mutating QMS state.
---

# Cognidox QMS

## Overview

Use this skill to access a configured Cognidox QMS safely through read-only REST calls. Default to REST. Use SOAP only as reference material for legacy/task/form/report workflows that are not covered by REST.

V1 is read-only. Do not create, update, delete, approve, sign, obsolete, check out, check in, upload, or log client events through Cognidox unless a later task explicitly extends this skill.

## Authentication

1. Invoke `$token-file-auth cognidox`.
2. Load the Personal Access Token from `~/.codex/env/cognidox` through `token-file-auth/scripts/token_file_auth.sh`.
3. Never print the token, source arbitrary env files, or pass the token in command arguments.
4. Use `Authorization: Bearer <token>` with the REST API.

Required v1 PAT scopes:
- `read:repository`
- `read:categories`
- `read:documents`
- `read:files` for explicit version downloads

## Quick Start

Use the bundled client for repeatable, token-safe calls:

```bash
export COGNIDOX_QMS_BASE_URL="https://<tenant-host>/api/v1.0"
cognidox-qms/scripts/cognidox_qms.sh --auth-smoke-test
cognidox-qms/scripts/cognidox_qms.sh --repository
cognidox-qms/scripts/cognidox_qms.sh --category-root --filter details --filter categories
cognidox-qms/scripts/cognidox_qms.sh --search --title "<title text>" --limit 10
cognidox-qms/scripts/cognidox_qms.sh --document <part-number> --filter details --filter latest
```

Use `--format json` only when the raw API response is needed. Text mode summarizes results and avoids document bytes. For file export, require both `--download-version` and `--output <path>`:

```bash
cognidox-qms/scripts/cognidox_qms.sh \
  --document-version <part-number> --version <version> --version-format pdf \
  --download-version --output /tmp/document.pdf
```

## REST Workflow

Read `references/rest-api-guide.md` before adding or changing REST usage. Use these common routes:

- Repository: `GET /repository`, `GET /repository/options`, `GET /repository/documentTypes`
- Categories: `GET /categories`, `GET /categories/{categoryId}`, `POST /categories/recommendations/{categoryId}`
- Search: `POST /repository/documents`
- Documents: `GET /documents/{partNumber}`, `/constraints`, `/locks`, `/permissions`, `/templates`, `/versions`

Important search rule: `POST /repository/documents` rejects an empty JSON object. Always provide at least one search criterion, such as title, part number, category ID, published state, metadata JSON, saved search ID, or version information.

## SOAP And Future Write Research

Read `references/soap-guide.md` when a user asks about Cognidox tasks, reviews, forms, reports, briefcases, saved searches, policy tasks, or legacy operations not exposed by REST.

For future creation/upload workflows, research but do not execute these REST operations in v1:
- `newCategory`, `newDocument`, `newFormDocument`
- `createFromTemplate`, `createVersion`, `addVersionSlice`
- `updateDocument`, `deleteDocument`

Before implementing any write capability, require a new approval decision, document the target workflow, add dry-run or confirmation guardrails, and test against a sandbox or intentionally selected non-production record.

## Bundled References

- `references/openapi.yml`: full Cognidox REST OpenAPI 3.0.2 specification.
- `references/rest-api-guide.md`: compact REST workflow, scope, endpoint, and response-shape guide.
- `references/soap-guide.md`: compact SOAP capability map and fallback rules.

## Safety Rules

1. Prefer summaries in text mode. Use JSON mode only when explicitly requested.
2. Do not print tokens, binary document bytes, or bearer headers.
3. Do not use mutating endpoints in v1.
4. Keep live smoke checks metadata-only unless the user asks for a specific document lookup or export.
5. If an endpoint returns 401 or 403, report the missing access surface and do not retry with broader behavior.
