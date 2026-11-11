import SwiftUI
import KanbanCodeCore
import struct KanbanCodeCore.Link

struct BoardView: View {
    var store: BoardStore
    @State private var dragState = DragState()
    @State private var sidebarReorderState = SidebarReorderState()
    @State private var renamingPinnedCardId: String?
    @State private var collapsedPinnedSubagentParents: Set<String> = []
    @AppStorage("boardRail.agentsCollapsed") private var agentsCollapsed = false
    @AppStorage("boardRail.channelsCollapsed") private var channelsCollapsed = false
    @AppStorage("boardRail.pinnedCollapsed") private var pinnedCollapsed = false
    var onNewAgent: () -> Void = {}
    var onOpenChannel: (String) -> Void = { _ in }
    var onNewChannel: () -> Void = {}
    var onDeleteChannel: (String) -> Void = { _ in }
    var onRenameChannel: (String) -> Void = { _ in }
    var unreadCountForChannel: (Channel) -> Int = { _ in 0 }
    var onlineCountForChannel: (Channel) -> Int = { _ in 0 }
    var onStartCard: (String) -> Void = { _ in }
    var onResumeCard: (String) -> Void = { _ in }
    var onForkCard: (String, Bool) -> Void = { _, _ in }
    var onCopyResumeCmd: (String) -> Void = { _ in }
    var onCopyConversationMarkdown: (String) -> Void = { _ in }
    let onShowSubagents: (String) -> Void
    var onTrimSession: (String) -> Void = { _ in }
    var onDiscoverCard: (String) -> Void = { _ in }
    var onCleanupWorktree: (String) -> Void = { _ in }
    var canCleanupWorktree: (String) -> Bool = { _ in true }
    var onArchiveCard: (String) -> Void = { _ in }
    var onDeleteCard: (String) -> Void = { _ in }
    let onSetCardPinned: (String, Bool) -> Void
    let onSetSelfCompactContextThreshold: (String, Int?) -> Void
    var availableProjects: [(name: String, path: String)] = []
    var onMoveToProject: (String, String) -> Void = { _, _ in }
    var onMoveToFolder: (String) -> Void = { _ in }
    var enabledAssistants: [CodingAssistant] = []
    var onMigrateAssistant: (String, CodingAssistant) -> Void = { _, _ in }
    var onRefreshBacklog: () -> Void = {}

    var canDropCard: (KanbanCodeCard, KanbanCodeColumn) -> Bool = { _, _ in true }
    var onDropCard: (String, KanbanCodeColumn) -> Void = { _, _ in }
    var onMergeCards: (String, String) -> Void = { _, _ in }   // (sourceId, targetId)
    var onNewTask: () -> Void = {}
    var onCardClicked: (String) -> Void = { _ in }
    var onColumnBackgroundClick: (KanbanCodeColumn) -> Void = { _ in }

    var body: some View {
        boardContent
    }

    private var activeSubagentsByParent: [String: [KanbanCodeCard]] {
        store.state.subagentCardsByParent
    }

    private var activeSubagentCardsById: [String: KanbanCodeCard] {
        store.state.subagentCardsById
    }

    private var activeSubagentLinks: [String: Link] {
        activeSubagentCardsById.mapValues(\.link)
    }

    @ViewBuilder
    private var channelsPseudoColumn: some View {
        let channels = store.state.channels
        let pinnedCards = store.state.pinnedCards
        let agentCards = store.state.agentCards
        let descendantCounts = store.state.descendantCounts
        // The rail scrolls on its own. Bare, its height grows with the
        // pinned count, and a rail taller than the window vertically
        // centers the whole horizontal board: every column header and
        // the first cards of every column end up above the screen.
        ScrollView {
            railContent(
                agentCards: agentCards,
                channels: channels,
                pinnedCards: pinnedCards,
                descendantCounts: descendantCounts
            )
            .padding(.horizontal, 6)
        }
        .frame(width: 240, alignment: .top)
    }

    /// A collapsible section header for the rail. Subtle, so the rail reads
    /// as a side panel without competing with the real columns.
    private func railHeader(
        _ title: String,
        icon: String,
        count: Int,
        isCollapsed: Binding<Bool>,
        addHelp: String? = nil,
        onAdd: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isCollapsed.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isCollapsed.wrappedValue ? 0 : 90))
                        .frame(width: 10)
                    Image(systemName: icon)
                    Text(title)
                    if count > 0 { Text("\(count)") }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed.wrappedValue ? "Expand \(title)" : "Collapse \(title)")
            if let onAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.app(.caption))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(addHelp ?? "New")
            }
        }
        .font(.app(.caption, weight: .semibold))
        .foregroundStyle(.tertiary)
        .textCase(.uppercase)
        .padding(.horizontal, 10)
        .padding(.top, 2)
    }

    private func railContent(
        agentCards: [KanbanCodeCard],
        channels: [Channel],
        pinnedCards: [KanbanCodeCard],
        descendantCounts: [String: Int]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
                railHeader(
                    "Agents", icon: "person.2.wave.2", count: agentCards.count,
                    isCollapsed: $agentsCollapsed,
                    addHelp: "New long-running agent", onAdd: onNewAgent
                )
                if !agentsCollapsed {
                    if agentCards.isEmpty {
                        Text("Long-running sessions (conductor, butler) live here. Add one with +, or right-click a card → Move to Agents.")
                            .font(.app(.caption))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                    }
                    ForEach(agentCards) { card in
                        pinnedCardView(for: card, descendantCounts: descendantCounts)
                        ForEach(visiblePinnedSubagents(for: card.id)) { row in
                            if let child = activeSubagentCardsById[row.cardId] {
                                pinnedCardView(for: child, descendantCounts: descendantCounts)
                                    .padding(.leading, CGFloat(row.depth * 16))
                            }
                        }
                    }
                }

                railHeader(
                    "Channels", icon: "number", count: channels.count,
                    isCollapsed: $channelsCollapsed,
                    addHelp: "New chat channel", onAdd: onNewChannel
                )
                .padding(.top, 6)
                if !channelsCollapsed {
                    ForEach(channels) { ch in
                        let msgs = store.state.channelMessages[ch.name]
                        let last = msgs?.last
                        SidebarReorderableRow(
                            item: .channel(ch.id),
                            reorderState: sidebarReorderState,
                            onMove: reorderChannel
                        ) {
                            ChannelTile(
                                channel: ch,
                                onlineCount: onlineCountForChannel(ch),
                                lastMessageAt: last?.ts,
                                lastMessageBody: last?.body,
                                isSelected: store.state.selectedChannelName == ch.name,
                                unreadCount: unreadCountForChannel(ch),
                                onOpen: { onOpenChannel(ch.name) },
                                onDelete: { onDeleteChannel(ch.name) },
                                onRename: { onRenameChannel(ch.name) }
                            )
                        }
                    }
                    if channels.count > 1 {
                        SidebarReorderEndTarget(
                            kind: .channel(""),
                            reorderState: sidebarReorderState,
                            onMove: reorderChannel
                        )
                    }
                }

                if !pinnedCards.isEmpty {
                    railHeader(
                        "Pinned", icon: "pin.fill", count: pinnedCards.count,
                        isCollapsed: $pinnedCollapsed
                    )
                    .padding(.top, 6)
                }
                if !pinnedCards.isEmpty && !pinnedCollapsed {
                    ForEach(pinnedCards) { card in
                        SidebarReorderableRow(
                            item: .pinnedCard(card.id),
                            reorderState: sidebarReorderState,
                            onMove: reorderPinnedCard
                        ) {
                            pinnedCardView(for: card, descendantCounts: descendantCounts)
                        }
                        ForEach(visiblePinnedSubagents(for: card.id)) { row in
                            if let child = activeSubagentCardsById[row.cardId] {
                                pinnedCardView(for: child, descendantCounts: descendantCounts)
                                    .padding(.leading, CGFloat(row.depth * 16))
                            }
                        }
                    }
                    if pinnedCards.count > 1 {
                        SidebarReorderEndTarget(
                            kind: .pinnedCard(""),
                            reorderState: sidebarReorderState,
                            onMove: reorderPinnedCard
                        )
                    }
                }
            }
    }

    private func reorderChannel(_ channelId: String, _ targetChannelId: String?, _ above: Bool) {
        store.dispatch(.reorderChannel(channelId: channelId, targetChannelId: targetChannelId, above: above))
    }

    private func reorderPinnedCard(_ cardId: String, _ targetCardId: String?, _ above: Bool) {
        store.dispatch(.reorderPinnedCard(cardId: cardId, targetCardId: targetCardId, above: above))
    }

    private var boardContent: some View {
        let descendantCounts = store.state.descendantCounts
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 6) {
                    channelsPseudoColumn
                        .id("channels")
                    ForEach(store.state.visibleColumns, id: \.self) { column in
                        DroppableColumnView(
                            column: column,
                            cards: store.state.unpinnedCards(in: column),
                            selectedCardId: Binding(
                                get: { store.state.selectedCardId },
                                set: { store.dispatch(.selectCard(cardId: $0)) }
                            ),
                            dragState: dragState,
                            canDropCard: canDropCard,
                            isRefreshingBacklog: store.state.isRefreshingBacklog,
                            onMoveCard: { cardId, targetColumn in
                                onDropCard(cardId, targetColumn)
                            },
                            onMergeCards: { sourceId, targetId in
                                onMergeCards(sourceId, targetId)
                            },
                            onReorderCard: { cardId, targetCardId, above in
                                store.dispatch(.reorderCard(cardId: cardId, targetCardId: targetCardId, above: above))
                            },
                            onRenameCard: { cardId, name in
                                store.dispatch(.renameCard(cardId: cardId, name: name))
                            },
                            onArchiveCard: { cardId in
                                onArchiveCard(cardId)
                            },
                            onStartCard: onStartCard,
                            onResumeCard: onResumeCard,
                            onForkCard: onForkCard,
                            onCopyResumeCmd: onCopyResumeCmd,
                            onCopyConversationMarkdown: onCopyConversationMarkdown,
                            onShowSubagents: onShowSubagents,
                            subagentsByParent: activeSubagentsByParent,
                            descendantCounts: descendantCounts,
                            onTrimSession: onTrimSession,
                            onSetCardPinned: onSetCardPinned,
                            onSetSelfCompactContextThreshold: onSetSelfCompactContextThreshold,
                            onDiscoverCard: onDiscoverCard,
                            onCleanupWorktree: onCleanupWorktree,
                            canCleanupWorktree: canCleanupWorktree,
                            onDeleteCard: onDeleteCard,
                            availableProjects: availableProjects,
                            onMoveToProject: onMoveToProject,
                            onMoveToFolder: onMoveToFolder,
                            enabledAssistants: enabledAssistants,
                            onMigrateAssistant: onMigrateAssistant,
                            onRefreshBacklog: column == .backlog ? onRefreshBacklog : nil,
                            onCardClicked: onCardClicked,
                            onColumnBackgroundClick: onColumnBackgroundClick
                        )
                        .id(column)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 52)
                .padding(.bottom, 16)
            }
            .onChange(of: store.state.selectedCardId) {
                // Scroll to the column containing the selected card
                guard let selectedId = store.state.selectedCardId else { return }
                let rootId = SubagentHierarchy.rootId(of: selectedId, in: store.state.links)
                if store.state.pinnedCards.contains(where: { $0.id == rootId })
                    || store.state.agentCards.contains(where: { $0.id == rootId }) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo("channels", anchor: .leading)
                    }
                    return
                }
                for col in store.state.visibleColumns {
                    if store.state.cards(in: col).contains(where: { $0.id == rootId }) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(col, anchor: .center)
                        }
                        break
                    }
                }
            }
        }
        // Empty board hint
        .overlay {
            if store.state.filteredCards.isEmpty && !store.state.isLoading {
                VStack(spacing: 12) {
                    if let projectPath = store.state.selectedProjectPath {
                        let name = store.state.configuredProjects.first(where: { $0.path == projectPath })?.name
                            ?? (projectPath as NSString).lastPathComponent
                        Text("No sessions yet for \(name)")
                            .font(.app(.title3))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No sessions found")
                            .font(.app(.title3))
                            .foregroundStyle(.secondary)
                    }
                    Text("Create a new task or start an assistant session to get going.")
                        .font(.app(.caption))
                        .foregroundStyle(.tertiary)

                    Button(action: onNewTask) {
                        Label("New Task  \(AppShortcut.newTask.displayString)", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { renamingPinnedCardId != nil },
            set: { if !$0 { renamingPinnedCardId = nil } }
        )) {
            if let cardId = renamingPinnedCardId,
               let card = store.state.filteredCards.first(where: { $0.id == cardId }) {
                RenameSessionDialog(
                    currentName: card.link.name ?? card.displayTitle,
                    isPresented: Binding(
                        get: { renamingPinnedCardId != nil },
                        set: { if !$0 { renamingPinnedCardId = nil } }
                    ),
                    onRename: { name in store.dispatch(.renameCard(cardId: cardId, name: name)) }
                )
            }
        }
    }

    private func pinnedCardView(
        for card: KanbanCodeCard,
        descendantCounts: [String: Int]
    ) -> CardView {
        CardView(
            card: card,
            isSelected: card.id == store.state.selectedCardId,
            onCopyConversationMarkdown: { onCopyConversationMarkdown(card.id) },
            subagentCount: descendantCounts[card.id] ?? 0,
            activeDirectSubagentCount: activeSubagentsByParent[card.id]?.count ?? 0,
            onShowSubagents: { onShowSubagents(card.id) },
            subagentsExpanded: !collapsedPinnedSubagentParents.contains(card.id),
            onToggleSubagents: { togglePinnedSubagents(card.id) },
            onSetPinned: { isPinned in onSetCardPinned(card.id, isPinned) },
            onSetSelfCompactContextThreshold: { threshold in
                onSetSelfCompactContextThreshold(card.id, threshold)
            },
            onSelect: {
                let newId = store.state.selectedCardId == card.id ? nil : card.id
                store.dispatch(.selectCard(cardId: newId))
                if newId != nil { onCardClicked(card.id) }
            },
            onStart: { onStartCard(card.id) },
            onResume: { onResumeCard(card.id) },
            onFork: { keepWorktree in onForkCard(card.id, keepWorktree) },
            onRenameRequest: { renamingPinnedCardId = card.id },
            onCopyResumeCmd: { onCopyResumeCmd(card.id) },
            onTrimSession: { onTrimSession(card.id) },
            onDiscover: { onDiscoverCard(card.id) },
            onCleanupWorktree: { onCleanupWorktree(card.id) },
            canCleanupWorktree: canCleanupWorktree(card.id),
            onArchive: { onArchiveCard(card.id) },
            onDelete: { onDeleteCard(card.id) },
            availableProjects: availableProjects,
            onMoveToProject: { projectPath in onMoveToProject(card.id, projectPath) },
            onMoveToFolder: { onMoveToFolder(card.id) },
            enabledAssistants: enabledAssistants,
            onMigrateAssistant: { target in onMigrateAssistant(card.id, target) }
        )
    }

    private func visiblePinnedSubagents(for parentId: String) -> [SubagentHierarchyRow] {
        SubagentHierarchy.visibleDescendants(
            of: parentId,
            in: activeSubagentLinks,
            collapsedParentIds: collapsedPinnedSubagentParents
        )
    }

    private func togglePinnedSubagents(_ cardId: String) {
        if collapsedPinnedSubagentParents.contains(cardId) {
            collapsedPinnedSubagentParents.remove(cardId)
        } else {
            collapsedPinnedSubagentParents.insert(cardId)
        }
    }
}
