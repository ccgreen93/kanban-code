---
name: build
description: Implement the ticket or spec in commits, verify it, draft the PR, stop before pushing.
model: opus
effort: high
skill: bmad-build
column: in_progress
---

Implement this ticket with the `bmad-build` skill. If a spec exists on this
branch, build from it.

- Commit each finished step, so nothing is lost if the session restarts.
- Run the project's tests, lint and type checks, and review your own diff
  before you finish.
- Draft the pull request title and body in full.

Do not push or open the pull request. Finish with the commits, the check
results, anything you are unsure about, and the PR draft, then stop for a
yes.
