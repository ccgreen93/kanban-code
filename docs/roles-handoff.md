# Handoff: card roles (in progress)

Card roles are being built on the fork in steps, each a PR into `cg-main`.
The user-facing doc is [`docs/roles.md`](roles.md); this note keeps the
decisions and what is left.

## ⚠️ This repo is public

`ccgreen93/kanban-code` is a public fork. **Do not commit anything copied
from the work tool** that inspired this: not its role instructions or
prompts, not its name, not ticket keys, repo names or anything else from
work.

- Real role definitions live **outside the repo** in `~/.kanban-code/roles/`.
- The repo only gets the loader and generic example roles written from
  scratch (`docs/roles/examples/`).

## Goal

Each role is a worker session with a preset model, effort and
instructions, and roles hand work to each other. Line them up with the
board's columns, use BMAD skills where they fit, and (for value3) take
issues from Linear.

## Decisions (agreed 2026-11-19)

1. **The role is a card field (`Link.role`); columns stay automatic** in
   strict placement. In **free placement** a hand-off moves the card to
   the next role's `column` (triage → Backlog; spec, build-lite, build →
   In Progress; review → In Review; merge → Done).
2. **The worker triggers hand-offs** (`kanban role handoff`); the human
   approves only `ask` edges.
3. **One card per work item**, roles in sequence on it; subagents only for
   side work.
4. **A fresh session per role** to start with; same-session hand-off
   (model switch plus self-compact) maybe later.
5. **Gates are opt-in per role**. Day one: `git push`, PR open, comment,
   review and resolve, ticket writes. `gh pr merge` is always denied.
6. **No LLM supervisor**: rules in the daemon plus the Triage view.
7. **One `transitions.json`**, not `next` in each role file, with `auto`
   or `ask` per edge.
8. Triage is the role imported cards start in; adhoc is for manual tasks
   with no ticket.

## Steps

1. **Done (branch `cg/roles`):** role loader (`RoleLibrary`, `Role`,
   `RoleTransitions`), `Link.role` (synced and kept by the reconciler),
   role picker in the New Task dialog that fills model, effort and
   assistant, role instructions put ahead of the task at launch
   (`PromptBuilder.wrap`), badge on cards, `role:` and `effort:` in
   `kanban list/show`, generic example roles.
2. `kanban role handoff <next> "summary"`: validate against the map, end
   the session, relaunch the same card with the next role's model, effort
   and instructions plus the summary; move the column in free placement.
3. `ask` edges as `AttentionRequest`s answered in the Triage view.
4. Gates in the `PreToolUse` Bash hook (`VaultHook` is the precedent):
   deny with "report your draft and stop", released once from Triage.
5. Rules for unresolved review threads, failing CI and conflicts, as
   queued prompts from the daemon, each firing once per condition.
6. Linear as `LinkSource.linearIssue` (separate track), key in `kv`.

## Still open

- What pr-watch should become once step 5's rules exist (probably
  replaced by them).
- Whether the role picker should also live on the card (change role
  without a hand-off).
- `singleton` is parsed but not enforced.

Build and test without Xcode: `swift test` with
`-Xswiftc -F<CLT>/Library/Developer/Frameworks` plus rpaths to that folder
and `<CLT>/Library/Developer/usr/lib`, where
`CLT=/Library/Developer/CommandLineTools`.
