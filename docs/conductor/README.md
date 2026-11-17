# Conductor

A long-running Claude session that watches the board, nudges stuck cards,
delivers follow-ups when cards go idle, spawns helpers, and posts a short
summary to `#control`. It lives in the **Agents** section beside the board.

- `instructions.md`: its standing instructions. It re-reads this file after
  every compaction or resume, so edits here take effect on its next pass after
  you tell it to re-read (or the next compaction).
- `init-prompt.md`: the first prompt of a fresh session. It only points the
  agent at the instructions and kicks off the first pass.

## Start it

Needs a `kanban` CLI and app with `kanban launch --prompt-file` and agent
cards (cg-main with "kanban launch lands new agents in the Agents section").

```bash
kanban channel create control --as-user    # once; harmless if it exists
kanban launch conductor --cwd ~/dev/cg --model opus \
  --prompt-file ~/dev/cg/kanban-code/docs/conductor/init-prompt.md
```

- The card appears under Agents. With the app running the move goes through the
  app's command mailbox, so allow a few seconds for the app to pick up the new
  session. If it lands in a lane anyway, `kanban agent add conductor`.
- `kanban launch` is idempotent: run it again and a live conductor is left
  alone; a dead one resumes its transcript (the init prompt is not resent).
  `--no-resume` starts it over from scratch.
- It runs with `--dangerously-skip-permissions` like every launched agent; its
  instructions forbid outward-facing actions and value3 cards.

## Talk to it

- `kanban dm conductor "when add-3rd-view is done, tell it to run the e2e suite"`
- Or post in `#control`, or open its card and type.
- Read it in `#control` in the app. Its summaries are written with
  `--no-fanout`, so they never paste into anyone's pane.

## Stop it

`tmux kill-session -t conductor`, then `kanban agent remove conductor` and
archive the card if you want it gone. Its notes stay in
`~/.kanban-code/conductor/notes.md`.
