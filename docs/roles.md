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
cp docs/roles/examples/*.md docs/roles/examples/*.json ~/.kanban-code/roles/
```

| File | What it holds |
|---|---|
| `<role>.md` | One role: frontmatter and instructions (see "Role files"). |
| `transitions.json` | Which role may follow which (see "Transitions"). |
| `gates.json` | What role cards may push, merge or deploy on their own (see "Gates"). Optional: without it the built-in defaults apply. |

The folder is read each time the New Task dialog opens, at each launch and
at each gated command, so edits apply without restarting the app. Markdown
files with no frontmatter, or no `name`, are ignored, so notes can sit in
the same folder.

## In the app

| Where | What |
|---|---|
| New Task dialog | **Role** picker; it fills in the assistant, model and effort. |
| Card | A role badge, and an orange **Needs approval** badge while a gate holds a command (click it to approve or reject). |
| Card menu | **Role** (set or clear, no restart), **Hand Off To** (any role, next roles first), **Approve** / **Reject Held Command**. |
| Card detail, Prompt tab | **Role Stages**: each finished stage with its summary and a button that copies the command to resume its session. |
| `kanban list`, `kanban show` | `role:` and `effort:` lines. |
| `kanban role handoff` | The worker's hand-off (see "Hand-off"). |
| `kanban subagent spawn --role` | A child card in a role. |

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

It can also start a new, independent card for separate work, in any role:
`kanban new --role spec --name x "..."`, or with `--backlog` to park it. A
card that was itself started by another card may not start more unless its
role controls the board, and no card may have more than 8 active cards it
started.

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

A held command stays on the card until it is answered; the agent stops
and waits for the message. An approval is for that exact text: if the
agent changes the command, it is held again.

### How it works

1. Kanban Code's Bash `PreToolUse` hook (`~/.kanban-code/vault-hook.sh`,
   for Claude Code and Codex; see [the vault](vault.md#bash-hook)) runs a
   quick text match first. A command in a card's session that mentions
   none of `push`, `merge`, `gh `, `deploy`, `publish`, `release`, `ship`,
   `ssh`, `scp`, `rsync`, `pulumi`, `terraform`, `kubectl`, `helm`, the
   other deploy tools in the table, `eval` or `-c ` goes straight on.
2. Otherwise it runs `kanban role gate`, which finds the card from the
   tmux session. A card without a role goes straight on.
3. The CLI sends the command and the checkout's branch to the app, which
   classifies it (`RoleGateClassifier`), looks up the modes
   (`RoleGatePolicy`, from `gates.json`) and answers. The strictest match
   wins: a command with a push and a merge is refused for the merge.
4. A refusal or hold reaches the agent as the hook's `deny` reason. If the
   app does not answer within 15 seconds, the command is refused.

The classifier reads the command as a shell would: it splits at `;`,
`&&`, `||`, `|` and newlines, skips heredoc bodies and quoted text (a
commit message that says "gh pr merge" is fine), drops redirections,
peels off `sudo`, `env`, `VAR=value`, `kv env <file> --`, `npx` and the
like, and looks inside `bash -c`, `eval` and the remote command of `ssh`.
A push with no refspec counts as a push of the current branch, so
`git push` from main is a protected push.

A custom `deployPatterns` entry is only tried on commands that pass the
quick text match in step 1, so give it one of those words (`^ssh box`,
`^./bin/ship`), or it never fires.

### Limits

- Only Bash commands are checked. A merge through an MCP tool (a GitHub
  MCP server's merge tool) is not.
- It is a guardrail against an agent bending its instructions, not a
  security boundary: a command inside a script the agent wrote, or built
  from variables, is not seen.
- Cards on remote machines (boxd, ssh) have not been tried with the gate yet.

### Troubleshooting

Every hold and refusal is logged in `~/.kanban-code/logs/kanban-code.log`
under `[roles]`, with the card and the reason. A `gates.json` that does not
parse is logged there too, and the built-in defaults apply until it is
fixed (they only refuse more).

The code: `Sources/KanbanCodeCore/UseCases/RoleGateClassifier.swift`,
`RoleGatePolicy.swift`, the gate stage in
`Adapters/ClaudeCode/VaultHook.swift`, and `cli/src/role-gate.ts`. The
tests in `RoleGateTests.swift` list what each action catches and what
passes.

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
