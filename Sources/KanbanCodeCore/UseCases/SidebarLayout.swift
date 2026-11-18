import Foundation

/// A section of the card list in the Mac sidebar.
public enum SidebarSectionKind: Hashable, Sendable {
    /// Long-running agent cards, above everything else.
    case agents
    case pinned
    /// Cards whose assistant session runs now, whatever their column.
    case live
    case column(KanbanCodeColumn)

    /// Stable key, for collapse state and row identity.
    public var id: String {
        switch self {
        case .agents: "agents"
        case .pinned: "pinned"
        case .live: "live"
        case .column(let column): column.rawValue
        }
    }

    public var title: String {
        switch self {
        case .agents: "Agents"
        case .pinned: "Pinned"
        case .live: "Live"
        case .column(let column): column.displayName
        }
    }

    public var column: KanbanCodeColumn? {
        if case .column(let column) = self { return column }
        return nil
    }
}

public struct SidebarSection: Equatable, Sendable {
    public let kind: SidebarSectionKind
    public let cards: [KanbanCodeCard]

    public init(kind: SidebarSectionKind, cards: [KanbanCodeCard]) {
        self.kind = kind
        self.cards = cards
    }
}

/// The sidebar lists cards the way the phone does: Pinned, then the cards
/// running now, then the columns in the phone's order with Backlog last.
/// All Sessions is not listed; the board view keeps it.
public enum SidebarLayout {
    /// Columns after Pinned and Live, while the board keeps its default
    /// column order.
    public static let columnOrder: [KanbanCodeColumn] = [.waiting, .inProgress, .inReview, .done, .backlog]

    /// The list's columns for the board's column setting: the phone's order
    /// while the setting is the default, otherwise the user's order with
    /// their hidden columns left out. All Sessions is never listed.
    public static func columns(forBoardOrder order: [KanbanCodeColumn]) -> [KanbanCodeColumn] {
        if order == KanbanCodeColumn.allCases { return columnOrder }
        var seen: Set<KanbanCodeColumn> = []
        let listed = order.filter { $0 != .allSessions && seen.insert($0).inserted }
        return listed.isEmpty ? columnOrder : listed
    }

    /// `cardsByColumn` holds the unpinned top-level cards of each column in
    /// their board order. Empty sections are left out, except Backlog, which
    /// stays as the place to drop and refresh tasks. `columns` are the
    /// column sections in order (`columns(forBoardOrder:)`). Without
    /// `showsLive` (free placement) there is no Live section: every card is
    /// listed in its column, running or not. With `showsEmptyColumns` (free
    /// placement) every listed column shows, so each one takes drops.
    public static func sections(
        agents: [KanbanCodeCard] = [],
        pinned: [KanbanCodeCard],
        cardsByColumn: [KanbanCodeColumn: [KanbanCodeCard]],
        columns: [KanbanCodeColumn] = columnOrder,
        showsLive: Bool = true,
        showsEmptyColumns: Bool = false,
        isLive: (KanbanCodeCard) -> Bool,
        isBusy: (KanbanCodeCard) -> Bool
    ) -> [SidebarSection] {
        var out: [SidebarSection] = []
        if !agents.isEmpty { out.append(SidebarSection(kind: .agents, cards: agents)) }
        if !pinned.isEmpty { out.append(SidebarSection(kind: .pinned, cards: pinned)) }
        let live = !showsLive ? [] : columns.flatMap { cardsByColumn[$0] ?? [] }.filter(isLive).sorted { a, b in
            let busyA = isBusy(a), busyB = isBusy(b)
            if busyA != busyB { return busyA }
            let timeA = a.link.lastActivity ?? a.link.updatedAt
            let timeB = b.link.lastActivity ?? b.link.updatedAt
            return timeA != timeB ? timeA > timeB : a.id < b.id
        }
        if !live.isEmpty { out.append(SidebarSection(kind: .live, cards: live)) }
        let liveIds = Set(live.map(\.id))
        for column in columns {
            let cards = (cardsByColumn[column] ?? []).filter { !liveIds.contains($0.id) }
            if !cards.isEmpty || column == .backlog || showsEmptyColumns {
                out.append(SidebarSection(kind: .column(column), cards: cards))
            }
        }
        return out
    }
}
