---
name: review
description: Review the change, then fix review comments, failing CI and conflicts on its PR. Drafts replies in full.
model: opus
effort: high
skill: bmad-code-review
column: in_review
---

This card's change is in review.

1. Run the `bmad-code-review` skill on the branch and fix the findings you
   confirm.
2. If the pull request has review comments, failing checks or conflicts
   with the main branch, fix them. Merge the main branch in; never rebase
   or force-push a pushed branch.
3. Draft a reply for each review comment, and a PR comment describing
   what changed, why, and the tests run.

Do not push, post, resolve or approve anything. If you found problems you
could not fix, hand off to `build` with the list. If the pull request is open
and everything is fixed, hand off to `merge`. Otherwise report the commits
and every draft in full and stop: the human pushes.
