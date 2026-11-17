import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("ColumnOrder")
struct ColumnOrderTests {

    @Test("The board shows the saved order and hides left-out columns")
    func savedOrderAndHidden() {
        let visible = KanbanCodeColumn.visibleColumns(
            order: [.backlog, .waiting, .inProgress, .done],
            allSessionsHasCards: true
        )
        #expect(visible == [.backlog, .waiting, .inProgress, .done])
    }

    @Test("All Sessions shows only while it has cards, wherever it sits")
    func allSessionsNeedsCards() {
        let order: [KanbanCodeColumn] = [.allSessions, .backlog, .inProgress]
        #expect(KanbanCodeColumn.visibleColumns(order: order, allSessionsHasCards: false) == [.backlog, .inProgress])
        #expect(KanbanCodeColumn.visibleColumns(order: order, allSessionsHasCards: true) == order)
    }

    @Test("Duplicates are dropped and an empty order falls back to the defaults")
    func duplicatesAndEmpty() {
        #expect(KanbanCodeColumn.visibleColumns(order: [.done, .done, .backlog], allSessionsHasCards: false) == [.done, .backlog])
        #expect(KanbanCodeColumn.visibleColumns(order: [], allSessionsHasCards: false) == [.backlog, .inProgress, .waiting, .inReview, .done])
        #expect(KanbanCodeColumn.visibleColumns(order: [.allSessions], allSessionsHasCards: false) == [.backlog, .inProgress, .waiting, .inReview, .done])
    }

    @Test("columnOrderLoaded reorders the board's visible lanes")
    func reducerAppliesOrder() {
        var state = AppState()
        _ = Reducer.reduce(state: &state, action: .columnOrderLoaded([.backlog, .waiting, .inProgress, .inReview, .done]))
        #expect(state.columnOrder == [.backlog, .waiting, .inProgress, .inReview, .done])
        #expect(state.visibleColumns == [.backlog, .waiting, .inProgress, .inReview, .done])
    }
}
