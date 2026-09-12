---
name: circleci-job-results
description: Read CircleCI pipeline, workflow, and job results through its API.
---

# CircleCI Job Results

Use `$token-file-auth circleci` for credentials, then the bundled
`scripts/fetch_circleci_job_results.sh`. Resolve paths relative to this skill.

Supported queries:

- `--pipeline-id <id>` for workflows and jobs.
- `--project-slug <slug> --job-number <number>` for one job.
- `--auth-smoke-test` when authentication needs diagnosis.
- `--format json` for machine-readable results.

Use the exact requested pipeline or job. Report its identity, status, and
relevant failure details. A running result is not a successful result.

Never source a secret file, print its token, or pass it in command arguments.
The helper supplies curl headers through stdin. Unset tokens after custom calls.

Read [API examples](references/api-examples.md) only for queries outside the
helper's modes, such as recent pipelines or custom workflow filters.
