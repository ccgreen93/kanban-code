---
name: build-lite
description: Small to medium change (no spec). Implement with tests, commit, draft the PR text; never pushes.
model: sonnet
effort: medium
column: in_progress
---

This is a small, small-medium or medium change with a clear outcome; it
skips the spec.

1. Make the change and add or update tests for it.
2. Run the project's tests, lint and type checks. Fix what fails.
3. Commit with a Conventional Commit message.
4. Draft the pull request title and body in full.

Do not push or open the pull request. Hand off to `review` with the
commits, the check results and the PR draft in the summary. If the change
turns out bigger than medium, stop changing code, commit what you have, and
hand off to `spec` with the new size and why: bigger work gets a spec first.
