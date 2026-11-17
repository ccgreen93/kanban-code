import Foundation
import Testing
@testable import KanbanCode
import KanbanCodeCore

@Suite("Board View Mode")
struct BoardViewModeTests {
    @Test("View mode raw values stay stable for persistence")
    func rawValues() {
        #expect(BoardViewMode.kanban.rawValue == "kanban")
        #expect(BoardViewMode.list.rawValue == "list")
        #expect(BoardViewMode.triage.rawValue == "triage")
        #expect(BoardViewMode.allCases == [.kanban, .list, .triage])
    }

    @Test("Leaving expanded mode returns to the last board")
    func lastBoardRoundTrip() {
        #expect(BoardViewMode.lastBoard(from: BoardViewMode.triage.rawValue) == .triage)
        #expect(BoardViewMode.lastBoard(from: BoardViewMode.kanban.rawValue) == .kanban)
        // List is not a board, and unknown or empty storage falls back to kanban.
        #expect(BoardViewMode.lastBoard(from: BoardViewMode.list.rawValue) == .kanban)
        #expect(BoardViewMode.lastBoard(from: "") == .kanban)
        #expect(BoardViewMode.lastBoard(from: "wall") == .kanban)
    }

    @Test("Triage snoozes round-trip through storage")
    func snoozeStorageRoundTrip() {
        let snoozes: [String: TriageSnooze] = [
            "card_a": .timed(until: Date(timeIntervalSince1970: 2_000), at: Date(timeIntervalSince1970: 1_000)),
            "card_b": .untilChange(from: .needsAttention, at: Date(timeIntervalSince1970: 1_000)),
        ]
        #expect(TriageSnoozeStorage.decode(TriageSnoozeStorage.encode(snoozes)) == snoozes)
        #expect(TriageSnoozeStorage.encode([:]) == "")
        #expect(TriageSnoozeStorage.decode("") == [:])
        #expect(TriageSnoozeStorage.decode("not json") == [:])
    }

    @Test("Collapsed triage buckets round-trip through storage")
    func collapsedBucketsRoundTrip() {
        let ids: Set<String> = [TriageBucket.idle.id, TriageBucket.usageLimited.id]
        #expect(ListSectionCollapseState.decode(ListSectionCollapseState.encode(ids)) == ids)
    }

    @Test("Collapsed list sections round-trip through storage")
    func collapsedSectionsRoundTrip() {
        let encoded = ListSectionCollapseState.encode([SidebarSectionKind.live.id, SidebarSectionKind.column(.waiting).id])
        let decoded = ListSectionCollapseState.decode(encoded)

        #expect(decoded == ["live", "requires_attention"])
        // Sections collapsed before Live existed keep their column names.
        #expect(ListSectionCollapseState.decode("in_review,backlog") == ["in_review", "backlog"])
    }

    @Test("Collapsed list sections ignore empty persisted state")
    func collapsedSectionsEmptyState() {
        #expect(ListSectionCollapseState.encode([]) == "")
        #expect(ListSectionCollapseState.decode("") == [])
    }

    @Test("Pinned and lane rows use distinct SwiftUI identities")
    func pinnedAndLaneRowsUseDistinctIdentities() {
        let cardId = "card_pin1"

        #expect(ListBoardRowIdentity.pinned(cardId) != .section(.column(.waiting), cardId))
        #expect(ListBoardRowIdentity.section(.live, cardId) != .section(.column(.inProgress), cardId))
    }
}
