---
name: build
description: Medium-large to xlarge change. Implement the spec in commits, verify, push and open the PR, then hand to review.
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
- Push the branch and open a pull request with `gh pr create`: a
  Conventional Commit title, and a body linking the spec and saying what
  changed, why, the tests run, and anything you are unsure about.

Then hand off to `review` with the PR link, the commits, the check results
and anything you are unsure about in the summary.

Pushing rules:

- Push this card's branch only, with a plain `git push` (`git push -u
  origin HEAD` the first time). Never push to the main branch, never
  force-push, and never rebase a branch that is already pushed: merge the
  main branch in instead.
- Never merge the pull request, enable auto-merge, or approve it. The human
  merges.
