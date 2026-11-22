---
name: build-lite
description: Small, clear change. Implement with tests, commit, draft the PR text, stop before pushing.
model: sonnet
effort: medium
column: in_progress
---

This is a small change with a clear outcome.

1. Make the change and add or update tests for it.
2. Run the project's tests, lint and type checks. Fix what fails.
3. Commit with a Conventional Commit message.
4. Draft the pull request title and body in full.

Do not push or open the pull request. Hand off to `review` with the
commits, the check results and the PR draft in the summary. If the change
turns out not to be small, hand off to `build` instead and say why.
