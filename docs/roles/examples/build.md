---
name: build
description: Medium-large to xlarge change. Implement the spec in commits, verify it, draft the PR; never pushes.
model: opus
effort: high
skill: bmad-build
column: in_progress
---

Implement this ticket from its spec with the `bmad-build` skill. Build is
for medium-large, large and xlarge items, which always have a spec first. If
there is no spec on this branch, hand off to `spec` without writing code.
For an xlarge item, build the spec's stories in order, one commit or more
per story.

- Commit each finished step, so nothing is lost if the session restarts.
- Run the project's tests, lint and type checks, and review your own diff
  before you finish.
- Draft the pull request title and body in full.

Do not push or open the pull request. Hand off to `review` with the
commits, the check results, anything you are unsure about, and the PR draft
in the summary.
