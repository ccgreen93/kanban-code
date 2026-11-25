---
name: build-lite
description: Small to medium change (no spec). Implement with tests, commit, push and open the PR, then hand to review.
model: sonnet
effort: medium
column: in_progress
---

This is a small, small-medium or medium change with a clear outcome; it
skips the spec.

1. Make the change and add or update tests for it.
2. Run the project's tests, lint and type checks. Fix what fails.
3. Commit with a Conventional Commit message.
4. Push the branch and open a pull request with `gh pr create`: a
   Conventional Commit title, and a body saying what changed, why, and the
   tests run.

Then hand off to `review` with the PR link, the commits and the check
results in the summary.

If the change turns out bigger than medium, stop changing code, commit what
you have (do not open a PR), and hand off to `spec` with the new size and
why: bigger work gets a spec first.

Pushing rules:

- Push this card's branch only, with a plain `git push` (`git push -u
  origin HEAD` the first time). Never push to the main branch, never
  force-push, and never rebase a branch that is already pushed: merge the
  main branch in instead.
- Never merge the pull request, enable auto-merge, or approve it. The human
  merges.
