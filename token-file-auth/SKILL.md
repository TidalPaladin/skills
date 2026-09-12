---
name: token-file-auth
description: Load a named API token from a local secret file without exposing its value.
---

# Token File Auth

Accept `$token-file-auth <secret_name>`.
Use `~/.codex/env/<secret_name>`, or `TOKEN_FILE_AUTH_BASE_DIR` when explicitly set.
Avoid `~/.codex/.env`, which can interfere with Codex startup.

Use `scripts/token_file_auth.sh` for validation or source that helper to call
`load_token_from_file`. Never source the secret file itself.

The helper validates the name against `[A-Za-z0-9._-]+` and rejects path traversal.
Require a readable, non-empty regular file that is not a symlink.
Keep token values in memory. Do not print them or put them in command arguments.
Unset token variables when custom requests finish.

If the file is absent, report its expected location. Have the user supply the
secret through a secure mechanism. Use directory mode `700` and file mode `600`.
Return only sanitized diagnostics.
