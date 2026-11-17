import SwiftUI
import KanbanCodeCore

enum BoardViewMode: String, CaseIterable {
    case kanban
    case list
    case triage

    var label: String {
        switch self {
        case .kanban: "Kanban"
        case .list: "List"
        case .triage: "Triage"
        }
    }

    var icon: String {
        switch self {
        case .kanban: "square.split.2x1"
        case .list: "list.bullet"
        case .triage: "scope"
        }
    }

    /// Whether it is a board shown outside expanded mode (kanban or triage).
    var isBoard: Bool { self != .list }

    /// The board kept in `boardViewMode.lastBoard`: what leaving expanded
    /// mode returns to. Anything unknown reads as kanban.
    static func lastBoard(from rawValue: String) -> BoardViewMode {
        let mode = BoardViewMode(rawValue: rawValue) ?? .kanban
        return mode.isBoard ? mode : .kanban
    }
}

/// Triage snoozes as kept in `@AppStorage("triage.snoozes")`: JSON of the
/// card id → snooze dictionary. Unreadable storage reads as no snoozes.
enum TriageSnoozeStorage {
    static func encode(_ snoozes: [String: TriageSnooze]) -> String {
        guard !snoozes.isEmpty, let data = try? JSONEncoder().encode(snoozes) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ rawValue: String) -> [String: TriageSnooze] {
        guard !rawValue.isEmpty,
              let decoded = try? JSONDecoder().decode([String: TriageSnooze].self, from: Data(rawValue.utf8))
        else { return [:] }
        return decoded
    }
}

/// SwiftUI row identity includes presentation location so pinning is modeled
/// as a clean lane removal plus pinned insertion, never as a cross-section move.
enum ListBoardRowIdentity: Hashable {
    case pinned(String)
    case section(SidebarSectionKind, String)
}

/// Collapsed sidebar sections, stored by `SidebarSectionKind.id`.
enum ListSectionCollapseState {
    static func encode(_ ids: Set<String>) -> String {
        ids.sorted().joined(separator: ",")
    }

    static func decode(_ rawValue: String) -> Set<String> {
        Set(rawValue.split(separator: ",").map(String.init))
    }
}
