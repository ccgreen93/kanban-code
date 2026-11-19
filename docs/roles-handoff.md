# Handoff: card roles (unfinished)

Branch `feat/roles`, cut from `cg-main` on 2026-11-17. This is a design
note only; no code has been written yet. It is for a Claude session on
Chris's machine that has the work role-pipeline tool installed, which is
where the role definitions live.

## ⚠️ This repo is public

`ccgreen93/kanban-code` is a public fork. **Do not commit anything copied
from the work tool**: not its role instructions or prompts, not its name,
not ticket keys, repo names or anything else from work. Ask Chris for the
tool's name if you don't know it.

- Real role definitions live **outside the repo** in `~/.kanban-code/roles/`.
- The repo only gets the loader and generic example roles written from
  scratch (`docs/roles.md` plus a sample like `examples/roles/build.md`).

## Goal

The work tool runs "roles": each is a worker session with a preset model,
effort and instructions, and roles hand work to each other. Chris wants
the same in Kanban Code, lined up with the board's columns, with Linear
as the issue source for value3 (instead of Jira at work). Use BMAD skills
where they fit.

Roles (generic names, from Chris's screenshot):

| Role | Model / effort | Typical next | BMAD skill |
|---|---|---|---|
| triage | sonnet / medium | spec, build, build-lite, pr-review | none |
| adhoc | sonnet / medium | build, build-lite | none |
| spec | opus / high | build | `bmad-spec` |
| build-lite | sonnet / high | review | `bmad-build` (light) |
| build | opus / high | review | `bmad-build` |
| review | opus / high | merge | `bmad-code-review` |
| merge | none | — | none |
| pr-review, pr-watch (side roles) | ? | — | `bmad-code-review`, CI watcher |

Chris's column mapping: triage ≈ Backlog + In Progress; spec, build-lite
and build are In Progress; review is In Review; merge is Done.

## Proposed design (not yet agreed with Chris)

**Columns stay automatic. The role is a separate field.** Columns are
worked out from session activity in
`Sources/KanbanCodeCore/UseCases/AssignColumn.swift`: a running turn goes
to In Progress, idle goes to Waiting, a PR goes to In Review, and a
merged PR goes to Done. If roles became columns, an idle build session
would jump to Waiting and lose its stage. So:

1. **Role files:** `~/.kanban-code/roles/<name>.md`. The frontmatter holds
   `model`, `effort`, `skill` and `next: [roles]`; the body holds the
   instructions.
2. **On the card:** a `role: String?` field on `Link`
   (`Domain/Entities/Link.swift`). It sets the existing `modelOverride`
   and `effortOverride` (`effortOverride` landed in 3160fbd, "pick model
   and effort in the new task dialog"). The card shows a role badge, and
   In Progress can group cards by role, like the work tool's pipeline
   view.
3. **Handoff:** `kanban role handoff <next> "summary"`. It checks `next`,
   ends the current session and relaunches **the same card** with a fresh
   session: the next role's model and effort, and a prompt of its
   instructions plus the handoff summary. One card per ticket, with a
   clean context for each stage. A role picker in the new-task dialog and
   on the card belongs here too.
4. **Linear (value3 project only):** a new `LinkSource.linearIssue`
   alongside the GitHub-issue import (`GhCliAdapter.fetchIssues`,
   `githubIssuePromptTemplate`). Linear issues come in as Backlog cards,
   and role changes update the Linear status. The API key goes in the
   vault (`kv`), never in a file.

## Open questions for Chris

- Triage covers two columns. Is it just the role that cards start in?
- What exactly does pr-watch do (CI, review comments, merge readiness)?
- Who triggers a handoff: the agent itself, Chris, or either?
- Does the same card keep its history across roles (proposed), or does
  each role get its own child card?

## Next steps

1. Read the role definitions from the work tool on this machine. Turn
   them into `~/.kanban-code/roles/*.md` **locally**, with no commit.
2. Go through the open questions with Chris, then write the spec (use
   `bmad-spec`). Put the spec outside this public repo, or keep it free
   of anything from work.
3. Build on this branch and merge into `cg-main`. This is a personal
   feature, not an upstream PR.

Build and test without Xcode: see the `swift test` flags in the fork's
setup notes (`-F <CLT>/Library/Developer/Frameworks` plus rpaths). On a
machine with Xcode, plain `swift test` works.
