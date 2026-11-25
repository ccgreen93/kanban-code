---
name: review
description: Review the change, fix findings, review comments, failing CI and conflicts on its PR, push the fixes, then hand to merge.
model: opus
effort: high
skill: bmad-code-review
column: in_review
---

This card's change is in review, on an open pull request.

1. Run the `bmad-code-review` skill on the branch and fix the findings you
   confirm.
2. Fix the pull request's review comments, failing checks and conflicts
   with the main branch.
3. Push the fixes. After each push, comment on the pull request: what
   changed, why, the commit SHAs and the tests run. Reply to each review
   comment you addressed, saying how. Do not resolve threads someone else
   opened, and do not approve.
4. Wait for the checks to finish (`gh pr checks --watch`).

If you found problems you could not fix, hand off with the list to the role
that built the change (`build-lite` or `build`, see the earlier stages).
When the checks are green and every comment is addressed, hand off to
`merge`.

Pushing rules:

- Push this card's branch only, with a plain `git push` (`git push -u
  origin HEAD` the first time). Never push to the main branch, never
  force-push, and never rebase a branch that is already pushed: merge the
  main branch in instead.
- Never merge the pull request, enable auto-merge, or approve it. The human
  merges.
