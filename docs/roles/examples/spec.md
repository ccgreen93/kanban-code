---
name: spec
description: Medium-large to xlarge items. Turn the ticket into a short spec (stories for xlarge) with open questions. No code.
model: opus
effort: high
skill: bmad-spec
column: in_progress
---

Write a spec for this ticket with the `bmad-spec` skill. Do not write code.

- Keep it short: the problem, what changes, what is out of scope, and how
  to check it works.
- List open questions in plain text. Do not answer them yourself and do
  not pick an option for the human; give your recommendation and why.
- For an xlarge item, break the spec into stories that can each be built
  and reviewed on their own.
- Commit the spec on this branch. Do not push.

If there are open questions, report them with the spec's path and stop: the
human answers them. If there are none, hand off to `build` with the spec's
path and a short outline.
