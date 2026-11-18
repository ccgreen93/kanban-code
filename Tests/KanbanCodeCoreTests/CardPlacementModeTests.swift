import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("CardPlacementMode")
struct CardPlacementModeTests {
    private func placed(_ column: KanbanCodeColumn, prLinks: [PRLink] = []) -> Link {
        var link = Link(column: column, sessionLink: SessionLink(sessionId: "s1"), prLinks: prLinks)
        link.manualOverrides.column = true
        return link
    }

    @Test("Free: a placed card keeps its lane while its session works, whatever the lane")
    func freePlacementHoldsWhileWorking() {
        for column in [KanbanCodeColumn.backlog, .inProgress, .waiting, .inReview, .done] {
            let link = placed(column)
            #expect(AssignColumn.assign(link: link, activityState: .activelyWorking, hasLiveSession: true, placement: .free) == column)
            #expect(AssignColumn.assign(link: link, activityState: .needsAttention, hasLiveSession: true, placement: .free) == column)
            #expect(AssignColumn.assign(link: link, activityState: .idleWaiting, hasPR: true, placement: .free) == column)
        }
    }

    @Test("Free: a placement beats a merged pull request")
    func freePlacementBeatsMergedPR() {
        let link = placed(.waiting, prLinks: [PRLink(number: 1, status: .merged)])
        #expect(AssignColumn.assign(link: link, activityState: .ended, hasPR: true, allPRsDone: true, placement: .free) == .waiting)
    }

    @Test("Free: an archived card keeps the archive rules")
    func freeArchiveUnchanged() {
        var link = placed(.allSessions)
        link.manuallyArchived = true
        #expect(AssignColumn.assign(link: link, activityState: .ended, placement: .free) == .allSessions)
    }

    @Test("Free: a card nobody placed still moves on its own")
    func freeAutomaticUnchanged() {
        let link = Link(column: .done, sessionLink: SessionLink(sessionId: "s1"))
        #expect(AssignColumn.assign(link: link, activityState: .activelyWorking, placement: .free) == .inProgress)
    }

    @Test("Strict is the default and keeps the original rules")
    func strictIsDefault() {
        #expect(Settings().cardPlacement == .strict)
        #expect(AppState().cardPlacement == .strict)
        let link = placed(.done)
        #expect(AssignColumn.assign(link: link, activityState: .activelyWorking) == .inProgress)
        var update = link
        UpdateCardColumn.update(link: &update, activityState: .activelyWorking, hasWorktree: true, hasLiveSession: true, placement: .free)
        #expect(update.column == .done)
    }

    @Test("Settings without the key decode as strict, and the mode round-trips")
    func settingsCoding() throws {
        let decoded = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        #expect(decoded.cardPlacement == .strict)
        var settings = Settings()
        settings.cardPlacement = .free
        let again = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        #expect(again.cardPlacement == .free)
    }

    @Test("cardPlacementLoaded sets the board's mode")
    func reducerSetsMode() {
        var state = AppState()
        _ = Reducer.reduce(state: &state, action: .cardPlacementLoaded(.free))
        #expect(state.cardPlacement == .free)
    }
}
