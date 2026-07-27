---
name: review-fix-loop
description: Run bounded review, verification, fix, and validation cycles over uncommitted or current-branch changes. Use only when the user explicitly invokes $review-fix-loop and wants the main task to address findings until a native Codex review is clean or the iteration cap is reached; start Goal Mode automatically when no goal is active.
---

# Review Fix Loop

Use native, read-only Codex reviewers to inspect a pinned Git scope. Verify and fix each valid finding in the main task, then ask a new reviewer to inspect the updated scope.

## Enter Goal Mode

Call `get_goal` before inspecting the repository. Track whether this workflow creates the goal.

- When no goal is active, call `create_goal` before initializing the loop. Build the objective from the requested `scope`, optional `base`, and `max-iterations` values. Require a clean native review and unchanged passing repository gates, preserve unrelated changes, and include the configured stop conditions. For `scope=auto`, describe the runner-selected pinned scope rather than inspecting Git before creating the goal.
- When a goal is already active, retain it and run the loop under that goal. Do not replace an existing goal.
- If goal tools are unavailable, do not claim Goal Mode is active. Stop before repository inspection and tell the user that they must start the equivalent goal with the Goal Mode controls or `/goal`.
- If `create_goal` reports that an unfinished goal already exists, call `get_goal` again and retain that goal. Stop on other goal configuration failures.

Goal activation does not expand the current sandbox, approval policy, or repository permissions. Do not set a goal token budget unless the user explicitly supplied one.

## Parse Inputs

Accept these user-facing inputs:

- `scope=auto`: Default. Select `uncommitted` when staged, unstaged, or untracked changes exist at loop initialization. Otherwise select `session`.
- `scope=uncommitted`: Review only staged, unstaged, and untracked changes. A clean working tree completes without falling back to session scope.
- `scope=session`: Review the current branch relative to a base. Also review current uncommitted changes when the working tree is dirty.
- `base=<ref>`: Override session base selection. It has no effect on uncommitted scope.
- `max-iterations=<N>`: Set a positive integer cap. The default is `10`.

Initialize once. The runner pins the selected scope for the rest of the loop. Do not switch scope after fixes change working-tree state.

For session scope, the runner resolves the first existing ref in this order without fetching: `origin/main`, `origin/master`, `main`, `master`. It records that ref and the merge-base SHA. If none exists, stop and request `base=<ref>`.

Session scope approximates the current Codex task with all branch changes since the merge base. It can include changes that existed before this task began.

## Initialize the Loop

Set `SKILL_DIR` to this skill's directory. Run:

```bash
uv run --no-project python "$SKILL_DIR/scripts/run_review.py" init \
  --repo "$PWD" \
  --scope auto \
  --max-iterations 10
```

Pass `--base <ref>` only when the user supplied a base. Read the returned JSON and retain `state_file`, `selected_scope`, `base_ref`, and `merge_base`. The state and reviewer artifacts are private temporary files unless `--state-root` is supplied for testing.

## Run One Review Round

Run this command once per logical review iteration:

```bash
uv run --no-project python "$SKILL_DIR/scripts/run_review.py" review \
  --state-file <state_file>
```

The runner launches one structured `codex exec` reviewer with these fixed controls:

- model `gpt-5.6-luna` with medium reasoning;
- ephemeral execution;
- read-only sandbox and no approvals;
- JSON events, the schema in `references/review-result.schema.json`, and a structured last message;
- a scope-specific prompt that tells the reviewer which Git diff to inspect.

Do not replace this command with `codex exec review` while that command starts a review request without forwarding `--output-schema`. Native review targets and positional prompts are also mutually exclusive. The structured `codex exec` turn preserves the required schema while keeping the reviewer isolated and read-only.

For session scope, every round includes the base review. A dirty working tree adds an uncommitted review. The runner merges both passes, deduplicates by normalized file path, line range, and title, and records every source target. A session pair consumes one iteration only after both passes return valid structured output.

## Verify and Fix Findings

For each returned finding:

1. Inspect the cited code and relevant diff. Confirm the behavior independently instead of treating reviewer output as authoritative.
2. Reject false positives with a concrete reason. Do not edit code only to silence a finding.
3. For a confirmed bug, add and run the smallest regression test that reproduces it. Verify the test fails before changing production code when a practical automated test exists.
4. Implement the smallest safe fix. Preserve unrelated user changes.
5. Run focused formatting, linting, type checking, and tests for the changed area.

After addressing the round, run another review round. If a finding requires a public API change, dependency change, or material behavior decision, pause and request user direction.

## Confirm a Clean Result

When a round returns `clean`, run the repository's standard formatting, linting, type-checking, and test commands. Prefer project-defined Make targets.

Any edit after the clean review, including an edit made by a formatter or validation fix, invalidates that result. Run another review round before declaring the scope clean. If no edit occurs and all required checks pass, the goal is complete.

If this workflow created the goal and no required work remains, call `update_goal` with `status=complete`. When the workflow reused a broader existing goal, leave it active unless that complete objective is also achieved. Never mark an unfinished goal complete merely to exit the loop.

## Handle Stops and Failures

- `findings`: Fix verified findings in the main task, validate them, and continue.
- `clean`: Run the full project gates. Review again after any subsequent edit.
- `limit_reached`: Stop immediately. Do not make another fix that cannot receive a confirming review.
- Reviewer failure: The runner retries one clearly transient process failure without consuming an iteration. Stop after the second transient failure.
- Configuration, authentication, unavailable-model, and malformed-output failures: Stop on the first failure. Do not change models or weaken the read-only controls.

An iteration limit or first-time failure does not make the goal complete or blocked. Use `update_goal` with `status=blocked` only after the same blocker has recurred for at least three consecutive goal turns and meaningful progress is impossible without user input or an external state change. Otherwise leave the goal active.

Do not stage, commit, push, publish, or fetch while using this skill. Repository edits needed to fix verified findings are allowed in the main task.

## Report the Result

At handoff, report:

- selected scope;
- selected base ref and merge-base SHA for session scope;
- completed logical iterations and the configured cap;
- whether the workflow created or reused the goal and its final state;
- whether a clean review was confirmed;
- last findings or their verified dispositions;
- focused and full validation commands with pass, fail, or not-run state;
- any blocker that needs user direction.
