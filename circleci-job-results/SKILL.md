---
name: circleci-job-results
description: Read CircleCI job and pipeline results with safe local token loading. Use when the user asks to inspect CircleCI statuses, failures, or workflow/job outcomes from the CircleCI API.
---

# CircleCI Job Results

## Overview

Use this skill to fetch CircleCI execution results while keeping token handling centralized and safe.
Start by invoking `$token-file-auth circleci`, then execute CircleCI API reads.

## Invocation Contract

1. Use token workflow:
   - Invoke `$token-file-auth circleci`.
   - Load token from `~/.codex/.env/circleci` via script helper.
2. Supported query modes:
   - Auth smoke test (`--auth-smoke-test`)
   - Pipeline workflow + jobs (`--pipeline-id <id>`)
   - Single job lookup (`--project-slug <slug> --job-number <number>`)
3. Output modes:
   - Default text summary
   - `--format json` for machine-readable output

## Security Requirements

1. Never `source` secret files.
2. Never print token values.
3. Never pass token in command args.
4. Pass auth headers to `curl` using `--config -` via stdin.
5. Unset token after requests complete.

## Script

- `scripts/fetch_circleci_job_results.sh`
  - `--auth-smoke-test` validates live auth against CircleCI.
  - Produces text or JSON summaries for pipeline/job reads.

## Examples

Use these common commands with the bundled script:

```bash
# 1) Verify token + CircleCI auth
circleci-job-results/scripts/fetch_circleci_job_results.sh --auth-smoke-test

# 2) Get human-readable summary for a specific pipeline
circleci-job-results/scripts/fetch_circleci_job_results.sh --pipeline-id <pipeline_id>

# 3) Get machine-readable JSON for a specific pipeline
circleci-job-results/scripts/fetch_circleci_job_results.sh --pipeline-id <pipeline_id> --format json

# 4) Derive project slug from git origin (GitHub remote)
ORIGIN_URL="$(git remote get-url origin)"
PROJECT_SLUG="$(
  printf '%s\n' "${ORIGIN_URL}" \
    | sed -E 's#^git@github.com:##; s#^https://github.com/##; s#\.git$##' \
    | awk -F/ '{print "gh/"$1"/"$2}'
)"

# 5) Query a specific job in this repository
circleci-job-results/scripts/fetch_circleci_job_results.sh \
  --project-slug "${PROJECT_SLUG}" \
  --job-number <job_number>

# 6) Query the same job in JSON mode
circleci-job-results/scripts/fetch_circleci_job_results.sh \
  --project-slug "${PROJECT_SLUG}" \
  --job-number <job_number> \
  --format json
```

For additional API recipes (recent pipelines by repository, workflow/job chaining, and failed-job filters), see:
- `references/api-examples.md`

## Troubleshooting

If `~/.codex/.env/circleci` is missing, create it with secure permissions:

```bash
mkdir -p ~/.codex/.env
chmod 700 ~/.codex/.env
printf 'YOUR_CIRCLECI_TOKEN\n' > ~/.codex/.env/circleci
chmod 600 ~/.codex/.env/circleci
```
