import Foundation

/// The columns on the Kanban board, in display order.
public enum KanbanCodeColumn: String, Codable, CaseIterable, Sendable {
    case backlog
    case inProgress = "in_progress"
    case waiting = "requires_attention"
    case inReview = "in_review"
    case done
    case allSessions = "all_sessions"

    public var displayName: String {
        switch self {
        case .backlog: "Backlog"
        case .inProgress: "In Progress"
        case .waiting: "Waiting"
        case .inReview: "In Review"
        case .done: "Done"
        case .allSessions: "All Sessions"
        }
    }

    public var allowsBoardTaskCreation: Bool {
        self != .allSessions
    }

    /// The lanes the board shows, from the user's column order (Settings >
    /// General > Board). A column missing from `order` is hidden; All
    /// Sessions also hides while it has no cards. An order that would leave
    /// the board empty falls back to the default lanes.
    public static func visibleColumns(order: [KanbanCodeColumn], allSessionsHasCards: Bool) -> [KanbanCodeColumn] {
        var seen: Set<KanbanCodeColumn> = []
        var visible = order.filter { seen.insert($0).inserted }
        if !allSessionsHasCards { visible.removeAll { $0 == .allSessions } }
        if visible.isEmpty {
            visible = allCases.filter { $0 != .allSessions || allSessionsHasCards }
        }
        return visible
    }
}
