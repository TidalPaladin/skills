---
name: token-file-auth
description: Load API tokens from per-secret files under ~/.codex/env in a safe, reusable way without sourcing shell code or printing secret values. Use when another skill needs credentials from local secret files.
---

# Token File Auth

## Overview

Use this skill to load secrets from `~/.codex/env/<secret_name>` without exposing tokens in logs or conversation output.
`~/.codex/.env` is intentionally avoided because it can interfere with Codex startup.

## Invocation Contract

1. Invoke with a secret name, for example `$token-file-auth circleci`.
2. Read only from `~/.codex/env/<secret_name>` (or `TOKEN_FILE_AUTH_BASE_DIR` when explicitly set).
3. Do not use `source` on secret files.
4. Do not print token values.

## Workflow

1. Validate secret name (`[A-Za-z0-9._-]+`) to block path traversal.
2. Resolve token path from base directory and secret name.
3. Enforce minimal safety checks:
   - file exists
   - file is readable
   - file is a regular file
   - file is not a symlink
   - file content is non-empty
4. Load token as raw text in memory.
5. Return success/failure and sanitized diagnostics.

## Script

- `scripts/token_file_auth.sh`
  - Callable script for validation/self-test.
  - Sourceable helper function for other skills: `load_token_from_file`.

## Troubleshooting

If a token file is missing, create it with secure permissions:

```bash
mkdir -p ~/.codex/env
chmod 700 ~/.codex/env
printf 'YOUR_TOKEN_HERE\n' > ~/.codex/env/<service>
chmod 600 ~/.codex/env/<service>
```
