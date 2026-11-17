import SwiftUI
import AppKit
import KanbanCodeCore
import KanbanCodeRemoteKit

/// Hands the main window's key monitor to the triage view: ContentView owns
/// the one `NSEvent` monitor and its focus gate (no text field, terminal,
/// palette or sheet has the keyboard), and calls `handler` while Triage
/// shows. The handler returns true when it took the key.
@MainActor
final class TriageKeyRouter {
    var handler: ((NSEvent) -> Bool)?
    /// The window the triage view is in: keys from other windows
    /// (Settings, sheets) never reach the handler.
    weak var window: NSWindow?
}

/// Reports the window its view lands in.
private struct TriageWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onWindow = onWindow
    }

    final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}

/// The third board view: one queue of the cards waiting on the user,
/// ranked by bucket then oldest wait (docs/triage-view.md).
struct TriageView: View {
    var store: BoardStore
    let keys: TriageKeyRouter
    /// Selects the card and shows it in the inspector.
    var onOpen: (String) -> Void
    /// Selects the card and switches to expanded (List) mode.
    var onOpenExpanded: (String) -> Void
    /// Archives the card, after the usual confirmation.
    var onArchive: (String) -> Void

    @AppStorage("triage.collapsed") private var collapsedRaw = ""
    @State private var focusedId: String?
    /// Where the focus last was, so it lands on the item that took its
    /// place when the focused one leaves the queue.
    @State private var focusIndex = 0
    @State private var showSnoozed = false
    @State private var bucketFilter: TriageBucket?
    @State private var drafts: [String: String] = [:]
    @State private var composerFocusToken = 0
    @State private var snoozeMenuCardId: String?
    /// Last assistant message per card, keyed by the card's last activity.
    @State private var previews: [String: TriagePreview] = [:]
    @State private var tail: (cardId: String, lines: [String])?
    /// The timeline date the body last rendered with: the keyboard and the
    /// actions build the same queue that is on screen.
    @State private var renderedNow = Date()

    private var collapsed: Set<String> { ListSectionCollapseState.decode(collapsedRaw) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let queue = queue(now: context.date)
            let visible = visibleItems(queue)
            let focus = resolvedFocus(in: visible)
            content(queue: queue, visible: visible, focus: focus, now: context.date)
                .onChange(of: visible.map(\.id), initial: true) { syncFocus(visible) }
                .task(id: focus) { await followTail(of: focus) }
                .onChange(of: context.date, initial: true) { renderedNow = context.date }
        }
        .background(TriageWindowReader { [keys] window in keys.window = window })
        .onAppear { keys.handler = { handleKey($0) } }
        .onDisappear { keys.handler = nil }
        .confirmationDialog(
            "Snooze",
            isPresented: Binding(get: { snoozeMenuCardId != nil }, set: { if !$0 { snoozeMenuCardId = nil } })
        ) {
            ForEach(TriageSnoozeChoice.allCases.filter { $0 != .fifteenMinutes }, id: \.self) { choice in
                Button(choice.label) {
                    if let id = snoozeMenuCardId { snooze(id, choice) }
                    snoozeMenuCardId = nil
                }
            }
            Button("Cancel", role: .cancel) { snoozeMenuCardId = nil }
        }
    }

    // MARK: Queue

    private func queue(now: Date? = nil) -> TriageQueue {
        TriageQueue.build(state: store.state, now: now ?? renderedNow, includeSnoozed: showSnoozed)
    }

    /// The items the keyboard walks: filtered, in expanded buckets.
    private func visibleItems(_ queue: TriageQueue) -> [TriageItem] {
        let hidden = collapsed
        return queue.items.filter { item in
            (bucketFilter == nil || item.bucket == bucketFilter) && !hidden.contains(item.bucket.id)
        }
    }

    private func resolvedFocus(in items: [TriageItem]) -> String? {
        guard !items.isEmpty else { return nil }
        if let focusedId, items.contains(where: { $0.id == focusedId }) { return focusedId }
        return items[min(max(focusIndex, 0), items.count - 1)].id
    }

    private func syncFocus(_ items: [TriageItem]) {
        let resolved = resolvedFocus(in: items)
        if resolved != focusedId { focusedId = resolved }
        if let resolved, let index = items.firstIndex(where: { $0.id == resolved }) { focusIndex = index }
    }

    private func setFocus(_ id: String, in items: [TriageItem]) {
        focusedId = id
        if let index = items.firstIndex(where: { $0.id == id }) { focusIndex = index }
    }

    /// Moves the focus to the item after `id` (or before it, at the end):
    /// clearing the queue works through it like an inbox.
    private func advance(past id: String) {
        let items = visibleItems(queue())
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let rest = items.filter { $0.id != id }
        guard !rest.isEmpty else {
            focusedId = nil
            focusIndex = 0
            return
        }
        let next = rest[min(index, rest.count - 1)]
        focusedId = next.id
        // The index the next item has once `id` leaves the queue.
        focusIndex = min(index, rest.count - 1)
    }

    // MARK: Layout

    @ViewBuilder
    private func content(queue: TriageQueue, visible: [TriageItem], focus: String?, now: Date) -> some View {
        VStack(spacing: 0) {
            header(queue)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            if queue.isEmpty {
                emptyState(queue)
            } else if let bucketFilter, queue.buckets[bucketFilter] == nil {
                VStack(spacing: 8) {
                    Text("Nothing in \(bucketFilter.title)")
                        .font(.app(.title3))
                        .foregroundStyle(.secondary)
                    Button("Show all") { self.bucketFilter = nil }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6, pinnedViews: []) {
                            ForEach(TriageBucket.allCases) { bucket in
                                if let items = queue.buckets[bucket], bucketFilter == nil || bucketFilter == bucket {
                                    bucketSection(bucket, items: items, focus: focus, now: now)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    }
                    .onChange(of: focus) {
                        guard let focus else { return }
                        withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(focus, anchor: .center) }
                    }
                }
            }
            if !queue.running.isEmpty {
                Divider()
                runningStrip(queue.running)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.02))
        )
    }

    private func header(_ queue: TriageQueue) -> some View {
        HStack(spacing: 8) {
            Text("Triage")
                .font(.app(.title3, weight: .semibold))
            Text(summary(queue))
                .font(.app(.callout))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Menu(bucketFilter?.title ?? "All") {
                Button("All") { bucketFilter = nil }
                Divider()
                ForEach(TriageBucket.allCases) { bucket in
                    Button(bucket.title) { bucketFilter = bucket }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            if queue.snoozedCount > 0 || showSnoozed {
                Toggle("Show snoozed (\(queue.snoozedCount))", isOn: $showSnoozed)
                    .toggleStyle(.button)
                    .controlSize(.small)
            }
        }
    }

    private func summary(_ queue: TriageQueue) -> String {
        let waiting = queue.items.filter { !$0.isSnoozed }.count
        var parts = ["\(waiting) waiting"]
        if let oldest = queue.oldestWait { parts.append("oldest \(TriageFormat.wait(oldest))") }
        return "· " + parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func bucketSection(_ bucket: TriageBucket, items: [TriageItem], focus: String?, now: Date) -> some View {
        let isCollapsed = collapsed.contains(bucket.id)
        Button {
            toggleCollapsed(bucket)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.app(size: 10, weight: .semibold))
                    .frame(width: 10)
                Circle().fill(bucket.tone.color).frame(width: 6, height: 6)
                Text(bucket.title.uppercased())
                    .font(.app(.caption, weight: .semibold))
                Text("\(items.count)")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.top, 8)
        if !isCollapsed {
            ForEach(items) { item in
                row(item, isFocused: item.id == focus, now: now)
                    .id(item.id)
                    .task(id: TriagePreviewKey(cardId: item.id, lastActivity: item.card.link.lastActivity)) {
                        await loadPreview(item.card)
                    }
            }
        }
    }

    private func row(_ item: TriageItem, isFocused: Bool, now: Date) -> some View {
        let id = item.id
        return TriageItemRow(
            item: item,
            now: now,
            isFocused: isFocused,
            preview: previews[id]?.text,
            tail: tail?.cardId == id ? tail?.lines ?? [] : [],
            draft: Binding(get: { drafts[id] ?? "" }, set: { drafts[id] = $0 }),
            composerFocusToken: isFocused ? composerFocusToken : 0,
            onFocus: {
                if focusedId != id { setFocus(id, in: visibleItems(queue())) }
                // Take the keyboard back from the inspector's terminal or a
                // composer, so the triage keys work after a click.
                NSApp.keyWindow?.makeFirstResponder(nil)
            },
            onOpen: { onOpen(id) },
            onAnswer: { request, index in answer(request, option: index, cardId: id) },
            onShowRequest: { showRequest($0) },
            onSend: { send(cardId: id) },
            onSnooze: { snooze(id, $0) },
            onUnsnooze: { store.dispatch(.unsnoozeTriage(cardId: id)) },
            onComposerEscape: { NSApp.keyWindow?.makeFirstResponder(nil) }
        )
    }

    private func emptyState(_ queue: TriageQueue) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.app(size: 32))
                .foregroundStyle(.tertiary)
            Text("Nothing is waiting on you.")
                .font(.app(.title3))
                .foregroundStyle(.secondary)
            if !queue.running.isEmpty {
                Text("\(queue.running.count) running")
                    .font(.app(.caption))
                    .foregroundStyle(.tertiary)
            }
            if queue.snoozedCount > 0 {
                Button("Show snoozed (\(queue.snoozedCount))") { showSnoozed = true }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func runningStrip(_ running: [KanbanCodeCard]) -> some View {
        HStack(spacing: 6) {
            Text("Running \(running.count):")
                .font(.app(.caption, weight: .medium))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(running) { card in
                        Button { onOpen(card.id) } label: {
                            HStack(spacing: 4) {
                                Circle().fill(CardStatusTone.working.color).frame(width: 6, height: 6)
                                Text(card.displayTitle).lineLimit(1)
                            }
                            .font(.app(.caption))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func toggleCollapsed(_ bucket: TriageBucket) {
        var ids = collapsed
        if ids.contains(bucket.id) { ids.remove(bucket.id) } else { ids.insert(bucket.id) }
        collapsedRaw = ListSectionCollapseState.encode(ids)
    }

    // MARK: Actions

    private func item(_ id: String) -> TriageItem? {
        queue().items.first { $0.id == id }
    }

    /// Sends the draft through the card's prompt queue, the way the chat
    /// does; an open question takes it as its answer when it can.
    private func send(cardId: String) {
        let text = (drafts[cardId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        drafts[cardId] = nil
        let asksQuestion = item(cardId)?.requests.contains { $0.kind == .question || $0.kind == .planApproval } == true
        advance(past: cardId)
        NSApp.keyWindow?.makeFirstResponder(nil)
        if asksQuestion, let answerCard = AppServices.answerCard {
            Task { @MainActor in
                if await answerCard(cardId, text) { return }
                queuePrompt(text, cardId: cardId)
            }
        } else {
            queuePrompt(text, cardId: cardId)
        }
    }

    private func queuePrompt(_ text: String, cardId: String) {
        let prompt = QueuedPrompt(body: text, sendAutomatically: true, humanWrittenAt: .now)
        store.dispatch(.addQueuedPrompt(cardId: cardId, prompt: prompt, placement: .back))
        store.dispatch(.sendQueuedPrompt(cardId: cardId, promptId: prompt.id))
    }

    private func answer(_ request: AttentionRequest, option index: Int, cardId: String) {
        guard request.options.indices.contains(index) else { return }
        guard !request.needsAttentionSheet, let resolve = AppServices.resolveAttention else {
            showRequest(request)
            return
        }
        let id = request.id
        let option = request.options[index]
        advance(past: cardId)
        Task { @MainActor in
            if let problem = await resolve(id, option, nil, false) {
                store.dispatch(.setNotice(problem, kind: .warning))
            }
        }
    }

    private func showRequest(_ request: AttentionRequest) {
        NotificationCenter.default.post(name: .kanbanCodeShowAttention, object: nil, userInfo: ["id": request.id])
    }

    private func snooze(_ cardId: String, _ choice: TriageSnoozeChoice) {
        let activity = store.state.cards.first { $0.id == cardId }?.activityState
        advance(past: cardId)
        store.dispatch(.snoozeTriage(cardId: cardId, snooze: choice.snooze(activity: activity, now: .now)))
    }

    // MARK: Keyboard

    /// Called by ContentView's key monitor only when no text field,
    /// terminal, palette or sheet has the keyboard.
    private func handleKey(_ event: NSEvent) -> Bool {
        // Arrow keys also carry .function and .numericPad: only the real
        // modifiers count.
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let items = visibleItems(queue())
        let focus = resolvedFocus(in: items)
        let index = focus.flatMap { id in items.firstIndex { $0.id == id } }

        func move(_ delta: Int) -> Bool {
            guard !items.isEmpty else { return true }
            let next = index.map { min(max($0 + delta, 0), items.count - 1) } ?? 0
            setFocus(items[next].id, in: items)
            return true
        }

        // A held action key auto-repeats; after each action the focus moves
        // on, so a repeat would act on the next item too. Movement repeats.
        let isRepeat = event.isARepeat

        switch event.specialKey {
        case .downArrow? where flags.isEmpty: return move(1)
        case .upArrow? where flags.isEmpty: return move(-1)
        case .upArrow?, .downArrow?, .leftArrow?, .rightArrow?:
            // Never let an arrow reach the kanban navigation, which would
            // select cards the triage view does not show.
            return true
        case .carriageReturn?, .enter?, .newline?:
            guard let focus, !flags.contains(.command) else { return false }
            guard !isRepeat else { return true }
            if flags.contains(.shift) { onOpenExpanded(focus) } else { onOpen(focus) }
            return true
        default: break
        }

        guard let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1 else { return false }
        if flags == [.command, .shift], chars == "a" {
            guard let focus else { return false }
            guard !isRepeat else { return true }
            onArchive(focus)
            return true
        }
        let shift = flags == [.shift]
        guard flags.isEmpty || shift else { return false }
        switch chars {
        case "j": return move(1)
        case "k": return move(-1)
        case "o":
            guard let focus, !isRepeat else { return true }
            onOpen(focus)
            return true
        case "r":
            guard focus != nil, !isRepeat else { return true }
            composerFocusToken += 1
            return true
        case "s":
            guard let focus, !isRepeat else { return true }
            if shift { snoozeMenuCardId = focus } else { snooze(focus, .fifteenMinutes) }
            return true
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            guard !shift, !isRepeat, let focus, let request = items.first(where: { $0.id == focus })?.requests.first,
                  let number = Int(chars) else { return true }
            answer(request, option: number - 1, cardId: focus)
            return true
        default:
            return false
        }
    }

    // MARK: Context loading

    /// The last assistant message, read off the main actor once per change
    /// of the card's last activity.
    private func loadPreview(_ card: KanbanCodeCard) async {
        let key = card.link.lastActivity
        if let cached = previews[card.id], cached.lastActivity == key { return }
        guard let path = card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath else { return }
        let assistant = card.link.effectiveAssistant
        let text = await Task.detached(priority: .utility) {
            // The whole message: unfocused rows show its first line, the
            // focused row all of it. (`textPreview` keeps only the first
            // line of a long message — it is shaped for push notifications.)
            await TranscriptNotificationReader.lastAssistantText(transcriptPath: path, assistant: assistant)
        }.value
        guard !Task.isCancelled else { return }
        previews[card.id] = TriagePreview(lastActivity: key, text: text)
    }

    /// The end of the focused card's terminal: once when the focus lands
    /// (after 300 ms), then every 10 s while it stays. Only the focused
    /// item ever runs tmux.
    private func followTail(of cardId: String?) async {
        if tail?.cardId != cardId { tail = nil }
        guard let cardId,
              let tmux = store.state.links[cardId]?.tmuxLink,
              tmux.isPrimaryDead != true else { return }
        let session = tmux.sessionName
        try? await Task.sleep(for: .milliseconds(300))
        while !Task.isCancelled {
            if let output = try? await AppServices.tmux.capturePane(sessionName: session), !Task.isCancelled {
                tail = (cardId, TriageFormat.tail(output))
            }
            try? await Task.sleep(for: .seconds(10))
        }
    }
}

struct TriagePreviewKey: Hashable {
    let cardId: String
    let lastActivity: Date?
}

struct TriagePreview: Equatable {
    let lastActivity: Date?
    let text: String?
}
