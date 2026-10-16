---
name: review-fix-loop
description: Review and fix local changes with Claude and Codex reviewers until clean, capped, or judged complete. Use for complex or risky changes before handoff or PR, or when the user asks for a review-fix loop.
---

# Review Fix Loop

Use isolated, read-only reviewers from two model families, Claude and Codex, to inspect a pinned Git scope. Verify and fix each valid finding in the main session, then ask new reviewers to inspect the updated scope. End with one native `code-review` pass.

Claude Code has no native persistent goal. Track the loop in the session task list: one task for the loop objective, updated after each round. Do not mark it complete until the stop conditions below are met.

## Decide When to Invoke

Invoke this skill when the user asks for a review-fix loop or a local review. Also invoke it on your own judgment before handoff or PR when the change has sufficient complexity or risk, for example:

- concurrency, ordering, or retry logic.
- trust boundaries, input validation, authentication, or secrets.
- data integrity, persistence, or migrations.
- I/O boundaries and error paths.
- nontrivial algorithms or numerics.
- refactors across many files.
- released or medical device software.

Do not invoke it for trivial edits, documentation-only changes, formatting, mechanical renames, or generated files. Each round runs two reviewers. Compare that cost with the risk of the change.

## Parse Inputs

Accept these user-facing inputs:

- `scope=auto`: Default. Select `uncommitted` when staged, unstaged, or untracked changes exist at loop initialization. Otherwise select `session`.
- `scope=uncommitted`: Review only staged, unstaged, and untracked changes. A clean working tree completes without falling back to session scope.
- `scope=session`: Review the current branch relative to a base. Also review current uncommitted changes when the working tree is dirty.
- `base=<ref>`: Override session base selection. It has no effect on uncommitted scope.
- `max-iterations=<N>`: Set a positive integer cap. The default is `5`.
- `reviewers=both`: Default. Use the Claude and Codex reviewers. `reviewers=claude` uses only the same-family reviewer.
- `claude-model=<model>` and `codex-model=<model>`: Override a reviewer model for this loop.

Initialize once. The runner pins the selected scope for the rest of the loop. Do not switch scope after fixes change working-tree state.

For session scope, the runner resolves the first existing ref in this order without fetching: `origin/main`, `origin/master`, `main`, `master`. It records that ref and the merge-base SHA. If none exists, stop and request `base=<ref>`.

Session scope approximates the current session with all branch changes since the merge base. It can include changes that existed before this session began.

## Initialize the Loop

Set `SKILL_DIR` to this skill's directory. Run:

```bash
uv run --no-project python "$SKILL_DIR/scripts/run_review.py" init \
  --repo "$PWD" \
  --host claude \
  --scope auto \
  --max-iterations 5
```

`--host claude` identifies the same-family reviewer. Pass `--base <ref>`, `--reviewers <value>`, `--claude-model <model>`, or `--codex-model <model>` only when the user supplied that value. Read the returned JSON and retain `state_file`, `selected_scope`, `base_ref`, `merge_base`, `active_reviewers`, and `fallback`. The state and reviewer artifacts are private temporary files unless `--state-root` is supplied for testing.

## Run One Review Round

Run this command once per logical review iteration:

```bash
uv run --no-project python "$SKILL_DIR/scripts/run_review.py" review \
  --state-file <state_file>
```

The runner runs every active reviewer concurrently. Each reviewer is ephemeral, read-only, and bound to the schema in `references/review-result.schema.json`. All reviewers get the same scope-specific prompt.

- Claude: headless `claude -p` with model `opus`, unless `claude-model` overrides it, and high effort. It has only read-only tools (`Read`, `Grep`, `Glob`, and read-only `git` commands), `dontAsk` permissions, no session persistence, and `--json-schema`.
- Codex: `codex exec` with the model from the user's Codex configuration, unless `codex-model` overrides it, and high reasoning effort. It uses a read-only sandbox, no approvals, JSON events, and `--output-schema`.

Do not replace this command with a subagent or an interactive review. The headless reviewers keep the review isolated from the main session and enforce the schema.

For session scope, every round includes the base review. A dirty working tree adds an uncommitted review. Each active reviewer runs each target. The runner merges all passes, deduplicates by normalized file path, line range, and title, and records sources such as `claude:base` and `codex:uncommitted`. Each finding's `reviewers` field lists every family that reported it or an overlapping range in the same file. Agreement between families can help you set the order of work. It does not replace verification.

## Fall Back to the Same Family

The loop continues with the Claude reviewer when the Codex reviewer is not available:

- At initialization, a missing `codex` CLI removes the Codex reviewer.
- During a round, a Codex reviewer failure removes the Codex reviewer for the rest of the loop. This includes authentication, unavailable-model, configuration, and malformed-output failures, and a second transient failure. The round still counts when all Claude passes return valid output.
- A Claude reviewer failure stops the loop, and the round does not count.

The runner records each removal in `fallback` with the round and the reason. It never substitutes a different model in the same family. Report a loop with a non-empty `fallback` as a single-family review from that point. Do not call it a cross-family review.

A nested reviewer CLI needs network access and write access to its configuration directory. If a reviewer fails because the sandbox blocks that access, run the runner command again outside the sandbox when your permissions allow it. Use the fallback only when that is unavailable or denied. Do not weaken the reviewer's read-only controls.

## Verify and Fix Findings

For each returned finding:

1. Inspect the cited code and relevant diff. Confirm the behavior independently instead of treating reviewer output as authoritative.
2. Reject false positives with a concrete reason. Do not edit code only to silence a finding.
3. For a confirmed bug, add and run the smallest regression test that reproduces it. Verify the test fails before changing production code when a practical automated test exists.
4. Implement the smallest safe fix. Preserve unrelated user changes.
5. Run focused formatting, linting, type checking, and tests for the changed area.

After addressing the round, run another review round, or stop early as described below. Ask only when a necessary
API, dependency, or behavior change exceeds the scope already authorized.

## Stop Early on Judgment

You can stop before a clean round when the remaining findings show diminishing returns, for example:

- only P2 or P3 findings about style or preference remain.
- reviewers raise findings again that you rejected with a concrete reason.
- the findings ask for scope or behavior changes outside the task.

Do not stop early while a verified P0 or P1 finding is still open. An early stop is not a clean review. Report `stopped_early` with the reason and every open finding with its disposition.

## Confirm the Result

After a clean round or a justified early stop, verify the repository's required gates for that state.
Reuse passing results when no relevant input has changed. Prefer project-defined Make targets.

Then run the final gate once: invoke `code-review high` through the Skill tool on the same scope. Verify each of its findings as above.

Any edit after the clean review or the final gate, including an edit made by a formatter or validation fix, invalidates that result. If iterations remain, run another loop round, and then repeat the gates and the final gate. Otherwise report `limit_reached`. If no edit occurs and all required checks pass, mark the loop task complete.

## Handle Stops and Failures

- `findings`: Fix verified findings in the main session, validate them, and continue.
- `clean`: Run the full project gates and the final gate. Review again after any subsequent edit.
- `limit_reached`: Stop immediately. Do not make another fix that cannot receive a confirming review.
- Reviewer failure: The runner retries one clearly transient process failure without consuming an iteration. A Codex failure after that falls back to the Claude reviewer. A Claude failure stops the loop.
- Claude configuration, authentication, unavailable-model, and malformed-output failures: Stop on the first failure. Do not change models or weaken the read-only controls.

An iteration limit or a loop-stopping failure leaves the loop task open. Report the blocker.

Do not stage, commit, push, publish, or fetch while using this skill. Repository edits needed to fix verified findings are allowed in the main session.

## Report the Result

At handoff, report:

- selected scope.
- selected base ref and merge-base SHA for session scope.
- active reviewers and each `fallback` entry with its reason.
- completed logical iterations and the configured cap.
- whether a clean review was confirmed, or the reason for an early stop.
- final gate result.
- last findings or their verified dispositions.
- focused and full validation commands with pass, fail, or not-run state.
- any blocker that needs user direction.
