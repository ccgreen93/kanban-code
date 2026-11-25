# Card roles

A **role** is the job a card's worker does: preset instructions plus the
model and effort to run them with. Pick one in the New Task dialog and the
card launches with that role's instructions ahead of the task, on that
role's model and effort.

Roles are data. Each one is a markdown file; a single `transitions.json`
says which roles may follow which. Adding a role means dropping in a file
and adding one line to the map.

> Status: roles can be picked, set the card's model and effort, prefix its
> first prompt and show as a badge. Workers hand off to the next role in a
> fresh session; a control role can run the board. Gates refuse merges and
> deploys, or hold them for the human. Approval of `ask` hand-offs and PR
> rules come next (see "Roadmap").

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
description: Implement the spec, verify it, push and open the PR, then hand to review.
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
| `controls` | `true` for a control role: its card may hand off other cards (see "Control agent"). It gets no hand-off footer. |

The model and effort fill in the dialog's pickers and can still be changed
before launching. The card keeps what was picked, so resumes use it.

## What the worker is sent

```
# Role: build

<description>

<role instructions>

# Task

<the task, after the project's prompt template>

# Earlier stages on this card        (after a hand-off)

## build → review (2026-11-22 14:05)

<the summary build handed off with>

# When you are done

<how to run `kanban role handoff`, and the next roles: auto ones to hand
off to, ask ones to recommend before stopping>
```

A prompt that is already wrapped (one recovered from a transcript) is
unwrapped first, so roles never nest.

## Hand-off

When its stage is done, the worker commits and runs, inside its card:

```bash
kanban role handoff review - <<'END'
Implemented X in a.swift and b.swift, tests pass. Risky: Y.
END
```

Kanban Code checks the arrow in `transitions.json`, then:

1. records the finished stage on the card: role, session, summary, time;
2. switches the card's role, model and effort (and assistant, if the role
   names one);
3. ends the old session two seconds later, and starts a fresh one in the
   same worktree with the next role's prompt, which carries every summary
   so far;
4. in free placement, moves the card to the next role's `column`.

The card keeps its worktree, branch, pull requests, children and prompt.
The new session does not see the old conversation, only the summaries, so
roles should commit their work and write a summary the next role can
start from.

Finished stages are listed under **Role Stages** in the card's Prompt tab.
Each one can copy a command that resumes its session in a terminal. The
reconciler never links a past stage's session back onto the card.

The human can also, from the card menu:

- **Role**: set or clear the role without restarting (model and effort
  apply from the next launch or resume);
- **Hand Off To**: move to any role now, next roles listed first.

`kanban subagent spawn --role <role>` starts a child in a role.

## Control agent

A role with `controls: true` runs the board instead of a stage. Its card
(usually in the Agents section) may hand off other cards:

```bash
kanban role handoff review --card card_abc123 "Build finished but did not hand off."
```

It follows the same rules as a worker: only `auto` arrows. It may also give
a first role to a started card that has none. The example
[`control`](roles/examples/control.md) reads the board each pass, hands off
cards that finished without handing off, nudges idle or stuck workers with
queued prompts, and ends with the open decisions for the human. It never
edits code, pushes or merges.

## Transitions

`transitions.json` maps a role to the roles that may follow it. An object
with `"mode": "auto"` lets the worker (or a control agent) hand off without
asking. A plain name is an `ask` arrow: Kanban Code refuses it from an
agent, which reports and stops, and the human hands off from the card menu.
A role with no entry, or an empty list, is terminal.

```json
{
  "triage": [{ "role": "build", "mode": "auto" }, "spec"],
  "build": [{ "role": "review", "mode": "auto" }],
  "review": [{ "role": "build", "mode": "auto" }, "merge"],
  "merge": []
}
```

The example map is all `auto`, for an unattended pipeline, and routes by
the size triage gives the work item:

| Size | Pipeline |
|---|---|
| small, small-medium, medium | triage → build-lite → review → merge |
| medium-large, large, xlarge | triage → spec → build → review → merge |

The map enforces "spec before build" for agents: `build` is reachable only
from `spec` (and back from `review`), and `build-lite` steps up to `spec`
when an item turns out bigger than medium. An xlarge spec is split into
stories that build works through in order.

`build-lite` and `build` push the card's branch and open the pull request;
`review` pushes fixes and comments on the PR after each push. No role
merges: `merge` checks the PR is ready and reports it, and the human
merges. The roles push with a plain `git push`, never to the main branch,
never forced.

The picker lists roles in pipeline order: walks from the Backlog roles
first, then from roles nothing leads to (side roles), then the rest by name.

## Gates

On a card with a role, a command that might push, merge, deploy or
publish is checked before it runs. `~/.kanban-code/roles/gates.json` (see
[the example](roles/examples/gates.json)) gives each action `allow`, `ask`
or `deny`:

| Action | Catches | Default |
|---|---|---|
| `push` | `git push` of the card's own branch | allow |
| `pr` | `gh pr create`, `comment`, `edit`, `review` without approving | allow |
| `push-protected` | a push to `protectedBranches` (main, master, release/*…) or `--all` | deny |
| `force-push` | `--force`, `--force-with-lease`, `+ref`, deleting a branch | deny |
| `approve` | `gh pr review --approve`, an `APPROVE` review through the API | deny |
| `merge` | `gh pr merge` (also `--auto`), the merge API, auto-merge and the merge queue | deny |
| `deploy` | `pulumi up`, `terraform apply`, `kubectl apply`, `helm upgrade`, `docker push`, `npm`/`cargo`/`uv publish`, `gh release create`, `gh workflow run`, tag pushes, `fly`/`vercel --prod`/`firebase`/`wrangler` deploys, `make deploy`, `deploy.sh`, and over `ssh`: `docker compose up`, `systemctl restart`, `scp`/`rsync` onto a server | deny |

`deployPatterns` adds regular expressions for a project's own deploys.
Settings in `roles` apply to a role, and settings in `projects` (keyed by
path, `~` allowed) to the cards of a project and its worktrees; a project
beats a role, which beats `defaults`:

```json
{
  "roles": { "review": { "merge": "ask" } },
  "projects": {
    "~/dev/homelab": { "deploy": "ask", "deployPatterns": ["^ssh pi .*compose up"] },
    "~/dev/scratch": { "merge": "allow" }
  }
}
```

- **deny**: the command does not run, and the agent is told why and to
  report and stop.
- **ask**: the command does not run either; the card shows **Needs
  approval** with the exact command. **Approve** (from the badge or the
  card menu) lets that exact command run once and tells the agent to run
  it again; **Reject** tells it not to. A hand-off clears both.

The check is a stage of Kanban Code's Bash `PreToolUse` hook (the vault
hook, for Claude Code and Codex): a quick text match skips every other
command, then `kanban role gate` asks the app. If the app does not answer,
the command is refused. It reads the command as a shell would, skipping
heredoc bodies and quoted text and looking inside `bash -c`, `eval` and
`ssh`, but it is a guardrail, not a security boundary: a command inside a
script the agent wrote is not seen.

## Design choices

- **The role is a card field, not a column.** In strict placement columns
  are worked out from activity (`AssignColumn`): an idle build session
  moves to Waiting, and a role-per-column board would lose its stage. In
  free placement, a hand-off moves the card to the next role's `column`.
- **One card per work item.** Roles run in sequence on the same card;
  subagents are for side work.
- **Transitions in one file**, not in each role, so a role can be added or
  shared without editing the others.
- **A fresh session per role**, with summaries as the hand-off memory:
  a clean context and the right model for each stage.
- **Workers push and open PRs; only the human merges or deploys,** held
  by the gates (above) as well as the instructions.
- **No LLM supervisor is required.** The control role is optional, and has
  no more authority than a worker.

## Roadmap

1. ~~Role files, `Link.role`, picker, model and effort, badge.~~
2. ~~`kanban role handoff`, role stages, card menu, `--role` on spawn,
   control role.~~
3. `ask` hand-offs raise an attention request, answered in the Triage view.
4. ~~Gates in the `PreToolUse` hook: merges, deploys, force-pushes and
   pushes to main refused or held for approval, per role and project.~~
5. Rules on PR data the board already tracks: unresolved review threads,
   failing CI and conflicts queue a prompt to the card's worker.
