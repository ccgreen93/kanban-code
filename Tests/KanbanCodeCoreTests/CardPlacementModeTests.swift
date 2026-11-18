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

@Suite("CardPlacementMode: list view")
struct CardPlacementSidebarTests {
    private func placedLive(_ id: String, _ column: KanbanCodeColumn) -> Link {
        var link = Link(id: id, name: id, projectPath: "/repo", column: column, source: .manual)
        link.manualOverrides.column = true
        link.tmuxLink = TmuxLink(sessionName: "repo-\(id)")
        return link
    }

    private func sections(_ placement: CardPlacementMode, order: [KanbanCodeColumn] = KanbanCodeColumn.allCases) -> [SidebarSection] {
        let state = AppState()
        state.cardPlacement = placement
        state.columnOrder = order
        let placed = placedLive("card_parked", .backlog)
        var auto = Link(id: "card_auto", name: "card_auto", projectPath: "/repo", column: .waiting, source: .manual)
        auto.tmuxLink = TmuxLink(sessionName: "repo-card_auto")
        let done = Link(id: "card_done", name: "card_done", projectPath: "/repo", column: .done, source: .manual)
        state.links = [placed.id: placed, auto.id: auto, done.id: done]
        state.tmuxSessions = ["repo-card_parked", "repo-card_auto"]
        state.rebuildCards()
        return state.sidebarSections
    }

    @Test("Free: no Live section; every card is listed in its column, running or not")
    func freeHasNoLiveSection() {
        let s = sections(.free)
        #expect(!s.contains { $0.kind == .live })
        #expect(s.first { $0.kind == .column(.backlog) }?.cards.map(\.id) == ["card_parked"])
        #expect(s.first { $0.kind == .column(.waiting) }?.cards.map(\.id) == ["card_auto"])
    }

    @Test("Strict: every live card is listed under Live, as before")
    func strictListsLiveCardsUnderLive() {
        let s = sections(.strict)
        #expect(Set(s.first { $0.kind == .live }?.cards.map(\.id) ?? []) == ["card_parked", "card_auto"])
        #expect(s.first { $0.kind == .column(.backlog) }?.cards.isEmpty == true)
    }

    @Test("The default column setting keeps the list's original order")
    func defaultOrderUnchanged() {
        #expect(SidebarLayout.columns(forBoardOrder: KanbanCodeColumn.allCases) == [.waiting, .inProgress, .inReview, .done, .backlog])
        let kinds = sections(.free).map(\.kind)
        #expect(kinds == [.column(.waiting), .column(.done), .column(.backlog)])
    }

    @Test("A custom column setting sets the list's order and hides its hidden columns")
    func customOrderAndHidden() {
        let order: [KanbanCodeColumn] = [.backlog, .waiting, .inProgress, .inReview, .allSessions]
        #expect(SidebarLayout.columns(forBoardOrder: order) == [.backlog, .waiting, .inProgress, .inReview])
        // Done is hidden, so its card is not listed; empty columns stay out, Backlog stays.
        #expect(sections(.free, order: order).map(\.kind) == [.column(.backlog), .column(.waiting)])
        #expect(SidebarLayout.columns(forBoardOrder: [.allSessions]) == SidebarLayout.columnOrder)
    }
}
