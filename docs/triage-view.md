# Triage view

Status: **built on `cg/triage-view`** (off `cg-main`) · Fork-only feature, not upstreamed

## Why

Kanban Code has two views:

| View | Groups cards by | Answers |
|---|---|---|
| Kanban | column (stage) | "Where is each piece of work?" |
| List (expanded detail + sidebar) | sidebar section / project | "Let me drive this one agent." |

With several agents running, the bottleneck is the human, not the agents. Neither view answers
**"which agent is waiting on me, for how long, and what does it want?"** The attention sheet
(`AttentionDetailSheet.swift`) only covers explicit `AttentionRequest`s, such as permission and
vault prompts. The quieter, more common case gets no notice at all: a session that finished its
turn (`idleWaiting` / `needsAttention`) 20 minutes ago.

Triage is the third view. It shows **one queue of cards ordered by how long they have been
waiting on you**, and you act on each item without leaving the queue.

## Goals

1. Show every card that is waiting on the user, with the longest wait first.
2. Show enough context on each item (the question, the last assistant message, the end of the
   terminal output) to act without opening the card.
3. Let the user act in place: reply, answer an attention request, open the card, snooze, archive.
4. Make the queue fully drivable from the keyboard.
5. Reuse existing state and actions. No new detectors and no new persisted card fields in v1.

## Non-goals (v1)

- A live-terminal grid ("wall" view). Considered and deferred: monitoring is a different job
  from triage.
- Timeline or analytics of waiting time (possible v2, since it would reuse `activitySince` below).
- A Triage tab on the iOS remote app.
- Sending triage state to peers or remote machines.

## Queue membership and ordering

A card is a **triage item** if it is not archived, it is in the current project filter (the
same filter as the board), and it matches at least one rule below. Every item gets a bucket; the
item's rank is its highest-rank bucket.

| Rank | Bucket | Rule |
|---|---|---|
| 1 | **Asked you** | `state.openAttentionRequests` contains a request whose `cardId` is this card |
| 2 | **Blocked** | `activityState == .blocked` (mid-turn on a permission prompt or a question) |
| 3 | **Your turn** | `activityState == .needsAttention` |
| 4 | **Idle** | `activityState == .idleWaiting` for more than 60 s, and the card is not an agent (`link.isAgent`) |
| 5 | **Usage-limited** | `usageLimit` is active (`activeUsageLimit`) on an idle or working card that is in no higher bucket |
| — | **Running** (collapsed strip) | `activityState == .activelyWorking`; not a triage item, shown as a count plus chips |

Excluded: archived cards (`manuallyArchived` or column `.allSessions`), `.ended`, `.stale`, `nil`
activity with no open request (even when usage-limited), cards owned by another master
(`owner != nil`) unless they have an open attention request, and snoozed cards (see below).
Agent cards are left out of *Idle* only: they still show in *Asked you*, *Blocked*, *Your turn* and
*Usage-limited*.

**Ordering:** by rank, then by **waiting since**, oldest first. An item that has waited 40
minutes in *Idle* still sorts below a 1-minute *Asked you*. That is deliberate: explicit
questions block real work.

**Waiting since** for an item is:
- *Asked you*: `AttentionRequest.createdAt` (oldest open request on the card)
- otherwise: `state.activitySince[sessionId]` (new, see State), falling back to
  `link.lastActivity ?? link.updatedAt`

All of this is a pure function in Core, `TriageQueue.build(cards:openRequests:activitySince:snoozes:now:)`
(plus `build(state:now:)`, which reads the project-filtered cards), so it can be unit-tested without
SwiftUI.

## Layout

```
┌ toolbar: [＋][↻] Project ▾  [▦ | ☰ | ◎]                                    ┐
├──────────────────────────────────────────────────────────────────────────┤
│ Triage · 5 waiting · oldest 42m            [All ▾]  [Show snoozed (2)]   │
│                                                                          │
│ ▸ ASKED YOU                                                              │
│ ┌──────────────────────────────────────────────────────────────────────┐ │
│ │● fix-auth-flow           vx · cg/auth           waiting 12m          │ │
│ │  "Allow Bash(rm -rf build/)?"                                        │ │
│ │  [Approve] [Deny] [Always allow…]                  open ⏎ · snooze s │ │
│ └──────────────────────────────────────────────────────────────────────┘ │
│ ▸ YOUR TURN                                                              │
│ ┌──────────────────────────────────────────────────────────────────────┐ │
│ │● triage-view-spec        kanban-code            waiting 42m   ◀ focus│ │
│ │  Claude: "Spec written to docs/triage-view.md. Want me to start…"    │ │
│ │  ▏$ swift test …  142 passed                                         │ │
│ │  ┌ reply… ───────────────────────────────────────────── ⌘⏎ send ┐   │ │
│ │  └──────────────────────────────────────────────────────────────┘   │ │
│ └──────────────────────────────────────────────────────────────────────┘ │
│ ▸ IDLE (2)  …                                                            │
├──────────────────────────────────────────────────────────────────────────┤
│ Running 3:  [● game-loop] [● vx-backtest] [● kanban-roles]               │
└──────────────────────────────────────────────────────────────────────────┘
```

- Items are vertical rows, full width, grouped under bucket headers that can be collapsed.
  The collapse state is kept in `@AppStorage("triage.collapsed")` using the same encoding as
  `ListSectionCollapseState`.
- The **focused** item is expanded: it shows the reply composer and up to 3 lines from the end
  of the terminal. Unfocused items show one line of context.
- Clicking an item focuses it. **Open** (⏎ / double-click) selects the card and shows its full
  detail in the **existing inspector** (`inspectorContent`), exactly as the kanban board does.
  The user stays in Triage.
- The Agents & Channels rail (`boardRailHidden`) shows on the left exactly as it does on the
  kanban board, and ⌘B toggles it the same way.
- Empty state: "Nothing is waiting on you." plus the Running strip, so it is clear that agents
  are still working.

### Item contents

| Element | Source |
|---|---|
| Status dot and bucket colour | existing `CardStatusTone` mapping |
| Priority, title | `link.priority`, `card.displayTitle`, plus a spinner while the card is busy |
| Card details (second line) | the card label, the column name, the same `CardBadgesRow` as the kanban and list cards (role, held gate, session and model, PRs, limits, issue, images, machine), project and `link.worktreeLink?.branch` |
| Waiting time | "waiting since" (above), refreshed by a 30 s `TimelineView` |
| The ask (*Asked you*) | `AttentionRequest.title` / `body`, with `options` as buttons |
| Last assistant message | `TranscriptNotificationReader.lastAssistantText(transcriptPath:assistant:)` on the session's transcript path, then `textPreview`, loaded off the main actor in `.task(id:)` keyed by `link.lastActivity` and cached per card in `TriageView` |
| Terminal tail (focused item only) | last 3 non-empty lines of `TmuxAdapter.capturePane(sessionName:)`, run **only for the focused item**: once when focus lands on it (debounced 300 ms), then every 10 s while it stays focused. Omitted when the card has no `tmuxLink`. `TerminalCache` holds SwiftTerm views with no text-tail API, so it is not used here. Never poll every row: recent commits removed a tmux process per scroll event for performance reasons |
| Queued prompts | count badge if `link.queuedPrompts` is not empty ("2 queued") |

## Actions

| Action | Key | Implementation |
|---|---|---|
| Next / previous item | `j` / `k`, `↓` / `↑` | view-local focus |
| Reply | `r`, or type in the composer; `⌘⏎` sends | same path as `ConversationViews.send`: dispatch `.addQueuedPrompt(..., placement: .back)` then `.sendQueuedPrompt` with `humanWrittenAt: .now` |
| Answer an attention option | `1`…`9` for options in order | `AppServices.resolveAttention(id, option, nil, false)`. Requests with `requiresBiometry` or a `vault` / `unseal` payload **do not** resolve inline: the button opens the existing `AttentionDetailSheet` (`.kanbanCodeShowAttention`) |
| Open card | `⏎` / `o` | `.selectCard(cardId:)`; opens the inspector |
| Open in expanded mode | `⇧⏎` | select the card, then switch to List mode |
| Snooze | `s` (15 m), `⇧S` (menu: 1 h / until it changes / tomorrow 9 am) | `.snoozeTriage(cardId:snooze:)` (new) |
| Archive | `⌘⇧A` | the existing `archiveCard` with its confirmation |
| Resume ended session | n/a | not in v1 (ended cards are not items) |

After a reply, an answer, a snooze or an archive, focus moves to the **next** item, not back to
the top. Clearing the queue should feel like working through an inbox. Held action keys do not
auto-repeat (only `j`/`k`/arrows do), so holding `1` cannot approve several items in a row.

Single-letter keys apply only when the composer is not first responder. ContentView's single
`NSEvent` key monitor forwards keys to the view through `TriageKeyRouter`, only for the window that
hosts Triage, and never while the palette, a dialog, a sheet, a text field or a terminal has focus.
While Triage shows, it swallows every arrow key so none reaches the kanban navigation. Opening a
card from Triage does not move the keyboard into the inspector's terminal.

## State changes (Core)

All changes go through the reducer, following `docs/architecture.md`.

1. **`AppState.activitySince: [String: Date]`** (keyed by sessionId). In the reducer branch that
   assigns `state.activityMap = result.activityMap` (`BoardStore.swift`, around line 2712), add
   `now` for every sessionId whose state *changed*, and drop the keys that are gone (the same is
   done in `.activityChanged`). A session seen for the first time gets no stamp. It is not
   persisted. After a relaunch, "waiting since" falls back to `lastActivity`, which is close enough.
2. **`AppState.triageSnoozes: [String: TriageSnooze]`** (keyed by cardId), where
   `TriageSnooze = { until: Date?, untilActivityChange: Bool, stateAtSnooze: ActivityState?, snoozedAt: Date }`.
   - Action `.snoozeTriage(cardId:, snooze:)` and `.unsnoozeTriage(cardId:)`.
   - A snooze expires when `until` passes, or, for "until it changes", when the card's activity
     differs from `stateAtSnooze` **or** a new attention request opens for the card. A new
     attention request always breaks a snooze: the reducer drops it on `.attentionRaised`, and the
     builder ignores a snooze older than an open request (`createdAt > snoozedAt`). An unknown
     (`nil`) activity does not count as a change, so snoozes survive a relaunch.
   - Expired snoozes are pruned after every reduce (a no-op without snoozes). Snoozes on cards
     that no longer exist are dropped once the links are loaded.
   - v1 persistence: `@AppStorage("triage.snoozes")` JSON written from the view layer when the
     dictionary changes, and loaded at launch through a dispatched `.restoreTriageSnoozes`, both in
     `ContentView`, so it works whatever view shows. This
     keeps snoozes out of `links.json` and away from peers.
3. **`TriageQueue`** (`Sources/KanbanCodeCore/UseCases/TriageQueue.swift`): a pure builder
   returning `[TriageBucket: [TriageItem]]`, `running: [KanbanCodeCard]`, `snoozedCount`, and
   `oldestWait`.

## View-mode plumbing (App)

`BoardViewMode` gains `case triage` (raw value `"triage"`, label "Triage", icon `scope`;
alternatively `tray.full`).

The current picker binding derives the mode from `isExpandedDetail` alone, and the
`detailExpanded` `onChange` forces `boardViewModeRaw = .kanban` whenever expanded mode closes.
With three modes this changes as follows:

- `.list` ⇔ `isExpandedDetail == true` (unchanged).
- When not expanded, `boardViewMode.lastBoard` picks `.kanban` or `.triage`. In Triage,
  `BoardView(replacementContent:)` shows `TriageView` beside the Agents & Channels rail in place of
  the columns, keeping the same `.inspector`.
- Add `@AppStorage("boardViewMode.lastBoard")` (kanban or triage). Leaving expanded mode
  (⌘⇧⏎, the picker, the `detailExpanded` change) returns to **lastBoard**, not always to kanban.
- ⌘⇧⏎ keeps toggling between expanded and lastBoard. The **new shortcut `⌘⇧T`** is already
  taken by `reopenClosedTab`, so use **`⌘⇧U`** ("up next") to jump to Triage from anywhere. Add
  it to `AppShortcut` and to the palette ("Show Triage"). There is no keyboard-shortcuts list in
  Settings to add it to.
- `ToolbarVisibility` needs no change: board controls show whenever the sidebar is hidden.
  Add a test asserting that this holds in triage mode.
- **Dock badge / menu bar:** out of scope, but `TriageQueue.count` is the natural number for a
  later dock badge (`DockAttentionNotifier.swift`).

## Files

| File | Change |
|---|---|
| `Sources/KanbanCodeCore/UseCases/TriageQueue.swift` | **new**: buckets, ordering, snooze expiry (pure) |
| `Sources/KanbanCodeCore/UseCases/BoardStore.swift` | `activitySince`, `triageSnoozes`, actions and reducer cases |
| `Sources/KanbanCode/BoardViewMode.swift` | `case triage`, `lastBoard`, `TriageSnoozeStorage` |
| `Sources/KanbanCode/BoardView.swift` | `replacementContent` beside the rail; rename sheet moved to `body` |
| `Sources/KanbanCode/TriageView.swift` | **new**: queue, buckets, focus, keyboard, transcript preview loader, terminal tail |
| `Sources/KanbanCode/TriageItemRow.swift` | **new**: row, composer, attention buttons, snooze choices, format helpers |
| `Sources/KanbanCode/ContentView.swift` | picker binding, `boardWithOverlays` branch, lastBoard, ⌘⇧U, palette |
| `Sources/KanbanCode/KeyboardShortcuts.swift` | `showTriage` |
| `Tests/KanbanCodeCoreTests/TriageQueueTests.swift` | **new** |
| `Tests/KanbanCodeTests/BoardViewModeTests.swift` | raw value `"triage"`, lastBoard round-trip, snooze storage |
| `Tests/KanbanCodeTests/ToolbarVisibilityTests.swift` | board controls show in triage mode |
| `Tests/KanbanCodeTests/TriageViewHelpersTests.swift` | **new**: snooze choices, wait labels, terminal tail |

## Tests

`TriageQueueTests` (Core, pure):
- bucket assignment for each `ActivityState`; an open attention request outranks any activity state
- ordering: rank first, then oldest waiting-since; ties broken by card id (stable)
- waiting-since falls back to `lastActivity` when `activitySince` has no entry
- archived, ended, stale and foreign-owned cards are excluded; a foreign card *with* an open
  request is included
- the project filter is respected
- snooze: a timed snooze hides until expiry; "until it changes" reappears when activity changes;
  a new attention request breaks any snooze
- `activelyWorking` goes to `running`, not to items

Reducer tests:
- `activitySince` is set only on a state change, keeps its time when the state stays the same,
  and drops removed sessions
- snooze and unsnooze actions

App tests:
- `BoardViewMode` raw values are stable; leaving expanded mode returns to lastBoard

Manual check (`make app NO_REGISTER=1` in this worktree): run 3 agents, take one to a permission
prompt and let one go idle, then clear the queue with only `j`, `1`, `r`, `⌘⏎` and `s`.

## Decisions

1. **Idle counts as waiting only after 60 s.** An `idleWaiting` card joins the queue once it has
   been idle for more than 60 s (`TriageQueue.idleGrace`).
2. **Snoozes persist across relaunches** in `@AppStorage("triage.snoozes")` (JSON), never in
   `links.json`.
3. **Agent cards are excluded from *Idle*** but still appear in *Asked you*, *Blocked*,
   *Your turn* and *Usage-limited*.
4. **Triage is not the default view.** It stays opt-in.
5. **Not upstreamed.** Fork-only on `cg/triage-view`, cut from `cg-main`. If it is ever
   upstreamed, cut the branch from `upstream/main`.
