# CircleCI API Query Examples

These examples assume:

1. `~/.codex/.env/circleci` exists and contains one token line.
2. `jq` and `curl` are installed.
3. You run commands from this repository root.

## Load Token Safely (No Secret Output)

```bash
source token-file-auth/scripts/token_file_auth.sh
load_token_from_file "circleci" "CIRCLECI_TOKEN"
```

The token is kept in memory and not printed.

## 1) Derive Project Slug From `git origin`

These examples assume a GitHub origin remote and convert it to CircleCI slug format `gh/<org>/<repo>`.

```bash
ORIGIN_URL="$(git remote get-url origin)"
PROJECT_SLUG="$(
  printf '%s\n' "${ORIGIN_URL}" \
    | sed -E 's#^git@github.com:##; s#^https://github.com/##; s#\.git$##' \
    | awk -F/ '{print "gh/"$1"/"$2}'
)"
```

## 2) Verify API Authentication

```bash
circleci-job-results/scripts/fetch_circleci_job_results.sh --auth-smoke-test
```

## 3) List Recent Pipelines For A Repository

```bash
curl --silent --show-error --config - <<EOF | jq -r '.items[] | [.id, .state, .created_at] | @tsv'
url = "https://circleci.com/api/v2/project/${PROJECT_SLUG}/pipeline"
request = "GET"
header = "Circle-Token: ${CIRCLECI_TOKEN}"
header = "Accept: application/json"
EOF
```

## 4) Summarize One Pipeline (Workflows + Jobs)

```bash
circleci-job-results/scripts/fetch_circleci_job_results.sh --pipeline-id <pipeline_id>
```

JSON mode:

```bash
circleci-job-results/scripts/fetch_circleci_job_results.sh --pipeline-id <pipeline_id> --format json
```

## 5) Show Failed Jobs In One Pipeline

```bash
circleci-job-results/scripts/fetch_circleci_job_results.sh --pipeline-id <pipeline_id> --format json \
  | jq -r '.workflows[].jobs[] | select(.status != "success") | [.job_number, .name, .status] | @tsv'
```

## 6) Query One Job By Repository + Job Number

```bash
circleci-job-results/scripts/fetch_circleci_job_results.sh \
  --project-slug "${PROJECT_SLUG}" \
  --job-number <job_number>
```

JSON mode:

```bash
circleci-job-results/scripts/fetch_circleci_job_results.sh \
  --project-slug "${PROJECT_SLUG}" \
  --job-number <job_number> \
  --format json
```

## 7) Workflow -> Jobs Chaining (Raw API)

```bash
WORKFLOW_ID="<workflow_id>"

curl --silent --show-error --config - <<EOF | jq -r '.items[] | [.job_number, .name, .status] | @tsv'
url = "https://circleci.com/api/v2/workflow/${WORKFLOW_ID}/job"
request = "GET"
header = "Circle-Token: ${CIRCLECI_TOKEN}"
header = "Accept: application/json"
EOF
```

## Cleanup

Unset token variables when done:

```bash
unset CIRCLECI_TOKEN
```
