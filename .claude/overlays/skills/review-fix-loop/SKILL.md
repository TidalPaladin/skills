---
name: review-fix-loop
description: Review and fix changes until clean or capped. Use only on explicit /review-fix-loop invocation.
disable-model-invocation: true
---

# Review Fix Loop

Use isolated, read-only Claude reviewers to inspect a pinned Git scope. Verify and fix each valid finding in the main session, then ask a new reviewer to inspect the updated scope.

Claude Code has no native persistent goal. Track the loop in the session task list: one task for the loop objective, updated after each round. Do not mark it complete until the stop conditions below are met.

## Parse Inputs

Accept these user-facing inputs:

- `scope=auto`: Default. Select `uncommitted` when staged, unstaged, or untracked changes exist at loop initialization. Otherwise select `session`.
- `scope=uncommitted`: Review only staged, unstaged, and untracked changes. A clean working tree completes without falling back to session scope.
- `scope=session`: Review the current branch relative to a base. Also review current uncommitted changes when the working tree is dirty.
- `base=<ref>`: Override session base selection. It has no effect on uncommitted scope.
- `max-iterations=<N>`: Set a positive integer cap. The default is `10`.

Initialize once. The runner pins the selected scope for the rest of the loop. Do not switch scope after fixes change working-tree state.

For session scope, the runner resolves the first existing ref in this order without fetching: `origin/main`, `origin/master`, `main`, `master`. It records that ref and the merge-base SHA. If none exists, stop and request `base=<ref>`.

Session scope approximates the current session with all branch changes since the merge base. It can include changes that existed before this session began.

## Initialize the Loop

Set `SKILL_DIR` to this skill's directory. Run:

```bash
uv run --no-project python "$SKILL_DIR/scripts/run_review_claude.py" init \
  --repo "$PWD" \
  --scope auto \
  --max-iterations 10
```

Pass `--base <ref>` only when the user supplied a base. Read the returned JSON and retain `state_file`, `selected_scope`, `base_ref`, and `merge_base`. The state and reviewer artifacts are private temporary files unless `--state-root` is supplied for testing.

## Run One Review Round

Run this command once per logical review iteration:

```bash
uv run --no-project python "$SKILL_DIR/scripts/run_review_claude.py" review \
  --state-file <state_file>
```

The runner launches one headless `claude -p` reviewer with these fixed controls:

- model `sonnet` with medium effort.
- no session persistence.
- read-only tools only: `Read`, `Grep`, `Glob`, and read-only `git` commands. Edit tools are denied and other tool requests are refused without a prompt.
- JSON output validated against `references/review-result.schema.json`.
- a scope-specific prompt that tells the reviewer which Git diff to inspect.

Do not replace this command with a subagent or an interactive review. The headless reviewer keeps the review isolated from the main session and enforces the schema.

For session scope, every round includes the base review. A dirty working tree adds an uncommitted review. The runner merges both passes, deduplicates by normalized file path, line range, and title, and records every source target. A session pair consumes one iteration only after both passes return valid structured output.

## Verify and Fix Findings

For each returned finding:

1. Inspect the cited code and relevant diff. Confirm the behavior independently instead of treating reviewer output as authoritative.
2. Reject false positives with a concrete reason. Do not edit code only to silence a finding.
3. For a confirmed bug, add and run the smallest regression test that reproduces it. Verify the test fails before changing production code when a practical automated test exists.
4. Implement the smallest safe fix. Preserve unrelated user changes.
5. Run focused formatting, linting, type checking, and tests for the changed area.

After addressing the round, run another review round. Ask only when a necessary
API, dependency, or behavior change exceeds the scope already authorized.

## Confirm a Clean Result

When a round returns `clean`, verify the repository's required gates for that state.
Reuse passing results when no relevant input has changed. Prefer project-defined Make targets.

Any edit after the clean review, including an edit made by a formatter or validation fix, invalidates that result. Run another review round before declaring the scope clean. If no edit occurs and all required checks pass, mark the loop task complete.

## Handle Stops and Failures

- `findings`: Fix verified findings in the main session, validate them, and continue.
- `clean`: Run the full project gates. Review again after any subsequent edit.
- `limit_reached`: Stop immediately. Do not make another fix that cannot receive a confirming review.
- Reviewer failure: The runner retries one clearly transient process failure without consuming an iteration. Stop after the second transient failure.
- Configuration, authentication, unavailable-model, and malformed-output failures: Stop on the first failure. Do not change models or weaken the read-only controls.

An iteration limit or first failure leaves the loop task open. Report the blocker.

Do not stage, commit, push, publish, or fetch while using this skill. Repository edits needed to fix verified findings are allowed in the main session.

## Report the Result

At handoff, report:

- selected scope.
- selected base ref and merge-base SHA for session scope.
- completed logical iterations and the configured cap.
- whether a clean review was confirmed.
- last findings or their verified dispositions.
- focused and full validation commands with pass, fail, or not-run state.
- any blocker that needs user direction.
