# Card roles

A **role** is the job a card's worker does: preset instructions plus the
model and effort to run them with. Pick one in the New Task dialog and the
card launches with that role's instructions ahead of the task, on that
role's model and effort.

Roles are data. Each one is a markdown file; a single `transitions.json`
says which roles may follow which. Adding a role means dropping in a file
and adding one line to the map.

> Status: roles can be picked, are stored on the card, set its model and
> effort, prefix its first prompt and show as a badge. Hand-off between
> roles, approval gates and PR rules come next (see "Roadmap").

## Where roles live

`~/.kanban-code/roles/`, outside any repository, so your own instructions
stay private. Generic examples are in [`docs/roles/examples/`](roles/examples/).
To start from them:

```bash
mkdir -p ~/.kanban-code/roles
cp docs/roles/examples/*.md docs/roles/examples/transitions.json ~/.kanban-code/roles/
```

The folder is read each time the New Task dialog opens and at each
launch, so edits apply without restarting the app. Markdown files with no
frontmatter, or no `name`, are ignored, so notes can sit in the same
folder.

## Role files

```markdown
---
name: build
description: Implement the ticket, verify it, draft the PR, stop before pushing.
model: opus
effort: high
assistant: claude
skill: bmad-build
column: in_progress
singleton: false
---

Instructions for the worker, in any markdown you like.
```

| Field | Meaning |
|---|---|
| `name` | Required. Unique; stored on the card and used in `transitions.json`. |
| `description` | One line shown under the picker. Say what the role does and what needs a yes. |
| `model` | `--model` for the session: an alias (`opus`, `sonnet`, ...) or a full id. Omit for the assistant's default. |
| `effort` | `--effort` (Claude only): `low`, `medium`, `high`, `xhigh`, `max`. `model_effort` also works. |
| `assistant` | `claude`, `codex` or `gemini`. Omit to keep the dialog's choice. |
| `skill` | A skill the instructions use, for example `bmad-build`. Shown in the picker. |
| `column` | Where a hand-off moves the card when the board uses **free placement** (`backlog`, `in_progress`, `in_review`, `done`, ...). Strict placement ignores it: columns follow activity there. |
| `singleton` | `true` if only one card of this role should run at a time. Not enforced yet. |

The model and effort fill in the dialog's pickers and can still be changed
before launching. The card keeps what was picked, so resumes use it.

## What the worker is sent

```
# Role: build

<description>

<role instructions>

# Task

<the task, after the project's prompt template>
```

A prompt that already starts with the role header is not wrapped again.

## Transitions

`transitions.json` maps a role to the roles that may follow it. A plain
name means the hand-off asks the human first; an object with
`"mode": "auto"` lets the worker hand off without asking. A role with no
entry, or an empty list, is terminal.

```json
{
  "triage": ["spec", "build-lite", "build", "adhoc"],
  "build": [{ "role": "review", "mode": "auto" }, "triage"],
  "review": ["build", "merge"],
  "merge": []
}
```

The picker lists roles in pipeline order: walks from the Backlog roles
first, then from roles nothing leads to (side roles), then the rest by name.

## Design choices

- **The role is a card field, not a column.** In strict placement columns
  are worked out from activity (`AssignColumn`): an idle build session
  moves to Waiting, and a role-per-column board would lose its stage. In
  free placement, a hand-off moves the card to the next role's `column`.
- **One card per work item.** Roles run in sequence on the same card;
  subagents are for side work.
- **Transitions in one file**, not in each role, so a role can be added or
  shared without editing the others.
- **Workers stop with drafts in full.** The example roles never push,
  post or merge on their own: they show the exact text and wait for a yes.
  Until gates exist (below) this rests on the instructions alone.

## Roadmap

1. ~~Role files, `Link.role`, picker, model and effort, badge.~~
2. `kanban role handoff <next> "summary"`, run by the worker in its card:
   checks the map, then relaunches the same card in a fresh session with
   the next role (its model, effort and instructions plus the summary).
   In free placement it also moves the card to the next role's column.
3. `ask` hand-offs raise an attention request, answered in the Triage view.
4. Gates, opt-in per role: `git push`, pull request writes and ticket
   writes need an approval in Kanban Code; merging a PR is always denied.
5. Rules on PR data the board already tracks: unresolved review threads,
   failing CI and conflicts queue a prompt to the card's worker.
