import Foundation
import Testing
@testable import KanbanCodeCore
import KanbanCodeRemoteKit

@Suite("Triage queue")
struct TriageQueueTests {
    static let now = Date(timeIntervalSince1970: 1_000_000)

    func card(
        _ id: String,
        _ activity: ActivityState?,
        idleFor seconds: TimeInterval = 600,
        archived: Bool = false,
        column: KanbanCodeColumn = .inProgress,
        agent: Bool = false,
        owner: CardOwner? = nil,
        usageLimit: RemoteUsageLimit? = nil,
        projectPath: String? = "/repo"
    ) -> KanbanCodeCard {
        let link = Link(
            id: id, name: id, projectPath: projectPath, column: column,
            updatedAt: Self.now.addingTimeInterval(-seconds - 100),
            lastActivity: Self.now.addingTimeInterval(-seconds),
            manuallyArchived: archived,
            sessionLink: SessionLink(sessionId: "s-\(id)"),
            agentAt: agent ? Self.now.addingTimeInterval(-86_400) : nil)
        return KanbanCodeCard(link: link, activityState: activity, owner: owner, usageLimit: usageLimit)
    }

    func request(_ cardId: String, ago seconds: TimeInterval, id: String? = nil) -> AttentionRequest {
        AttentionRequest(
            id: id ?? "att-\(cardId)", cardId: cardId, kind: .permission, title: "Allow Bash?", body: "rm -rf build",
            options: ["Approve", "Deny"], createdAt: Self.now.addingTimeInterval(-seconds))
    }

    func build(
        _ cards: [KanbanCodeCard],
        requests: [AttentionRequest] = [],
        since: [String: Date] = [:],
        snoozes: [String: TriageSnooze] = [:],
        now: Date = TriageQueueTests.now
    ) -> TriageQueue {
        TriageQueue.build(cards: cards, openRequests: requests, activitySince: since, snoozes: snoozes, now: now)
    }

    // MARK: Buckets

    @Test("each activity state lands in its bucket")
    func bucketsPerState() {
        let q = build([
            card("b", .blocked), card("y", .needsAttention), card("i", .idleWaiting),
            card("w", .activelyWorking), card("e", .ended), card("st", .stale), card("n", nil),
        ])
        #expect(q.items.map(\.id) == ["b", "y", "i"])
        #expect(q.items.map(\.bucket) == [.blocked, .yourTurn, .idle])
        #expect(q.running.map(\.id) == ["w"])
    }

    @Test("an open request outranks a long idle wait")
    func askedOutranks() {
        let q = build(
            [card("a", .idleWaiting, idleFor: 40 * 60), card("b", .activelyWorking, idleFor: 5)],
            requests: [request("b", ago: 60)])
        #expect(q.items.map(\.id) == ["b", "a"])
        #expect(q.items.map(\.bucket) == [.askedYou, .idle])
        #expect(q.items[0].waitingSince == Self.now.addingTimeInterval(-60))
        #expect(q.running.isEmpty)
    }

    @Test("idle joins only after the 60 s grace")
    func idleGrace() {
        let since = ["s-i": Self.now.addingTimeInterval(-30)]
        #expect(build([card("i", .idleWaiting)], since: since).isEmpty)
        let later = Self.now.addingTimeInterval(31)
        #expect(build([card("i", .idleWaiting)], since: since, now: later).items.map(\.id) == ["i"])
    }

    @Test("an idle agent is not in the queue, a blocked agent is")
    func agents() {
        let q = build([card("idle", .idleWaiting, agent: true), card("blocked", .blocked, agent: true)])
        #expect(q.items.map(\.id) == ["blocked"])
        #expect(q.items.first?.bucket == .blocked)
    }

    @Test("an agent with an open request is asked, and a usage-limited agent shows")
    func agentAskedAndLimited() {
        let limit = RemoteUsageLimit(window: "five_hour", resetsAt: Self.now.addingTimeInterval(3600))
        let q = build(
            [card("asked", .idleWaiting, agent: true), card("limited", .idleWaiting, agent: true, usageLimit: limit)],
            requests: [request("asked", ago: 10)])
        #expect(q.items.map(\.bucket) == [.askedYou, .usageLimited])
    }

    @Test("usage-limited ranks last and a lifted limit does not count")
    func usageLimited() {
        let active = RemoteUsageLimit(window: "five_hour", resetsAt: Self.now.addingTimeInterval(3600))
        let lifted = RemoteUsageLimit(window: "five_hour", resetsAt: Self.now.addingTimeInterval(-10))
        let q = build([
            card("u", .activelyWorking, idleFor: 9000, usageLimit: active),
            card("l", .activelyWorking, usageLimit: lifted),
            card("i", .idleWaiting, idleFor: 120),
        ])
        #expect(q.items.map(\.id) == ["i", "u"])
        #expect(q.items.last?.bucket == .usageLimited)
        #expect(q.running.map(\.id) == ["l"])
    }

    @Test("archived, ended, stale and foreign cards are excluded")
    func excluded() {
        let foreign = CardOwner(id: "m2", name: "Other Mac", online: true)
        let q = build([
            card("arch", .needsAttention, archived: true),
            card("all", .needsAttention, column: .allSessions),
            card("end", .ended), card("stale", .stale),
            card("foreign", .idleWaiting, owner: foreign),
        ])
        #expect(q.isEmpty)
        #expect(q.running.isEmpty)
    }

    @Test("a foreign card with an open request is asked")
    func foreignWithRequest() {
        let foreign = CardOwner(id: "m2", name: "Other Mac", online: true)
        let q = build([card("foreign", .idleWaiting, owner: foreign)], requests: [request("foreign", ago: 5)])
        #expect(q.items.map(\.bucket) == [.askedYou])
    }

    @Test("an archived card with an open request is still excluded")
    func archivedWithRequest() {
        #expect(build([card("a", .blocked, archived: true)], requests: [request("a", ago: 5)]).isEmpty)
    }

    // MARK: Ordering

    @Test("rank first, then oldest wait, then id")
    func ordering() {
        let q = build([
            card("y-new", .needsAttention, idleFor: 60),
            card("y-old", .needsAttention, idleFor: 600),
            card("b", .blocked, idleFor: 1),
            card("y-tie-b", .needsAttention, idleFor: 300),
            card("y-tie-a", .needsAttention, idleFor: 300),
        ])
        #expect(q.items.map(\.id) == ["b", "y-old", "y-tie-a", "y-tie-b", "y-new"])
        #expect(q.oldestWait == 600)
        #expect(q.buckets[.yourTurn]?.count == 4)
    }

    @Test("the oldest open request sets an asked item's wait")
    func oldestRequest() {
        let q = build([card("a", .blocked)], requests: [request("a", ago: 10, id: "r1"), request("a", ago: 90, id: "r2")])
        #expect(q.items.first?.waitingSince == Self.now.addingTimeInterval(-90))
        #expect(q.items.first?.requests.map(\.id) == ["r2", "r1"])
    }

    @Test("wait comes from activitySince, else lastActivity, else updatedAt")
    func waitingSinceFallback() {
        let stamped = Self.now.addingTimeInterval(-77)
        #expect(build([card("y", .needsAttention)], since: ["s-y": stamped]).items.first?.waitingSince == stamped)
        #expect(build([card("y", .needsAttention, idleFor: 600)]).items.first?.waitingSince == Self.now.addingTimeInterval(-600))

        var link = card("u", .needsAttention).link
        link.lastActivity = nil
        let noActivity = KanbanCodeCard(link: link, activityState: .needsAttention)
        #expect(build([noActivity]).items.first?.waitingSince == link.updatedAt)
    }

    @Test("the project filter of the board applies")
    func projectFilter() {
        var state = AppState()
        _ = Reducer.reduce(state: &state, action: .createManualTask(card("in", .none, projectPath: "/repo").link))
        _ = Reducer.reduce(state: &state, action: .createManualTask(card("out", .none, projectPath: "/other").link))
        _ = Reducer.reduce(state: &state, action: .activityChanged(["s-in": .needsAttention, "s-out": .needsAttention]))
        _ = Reducer.reduce(state: &state, action: .setSelectedProject("/repo"))
        #expect(TriageQueue.build(state: state, now: Self.now).items.map(\.id) == ["in"])
        _ = Reducer.reduce(state: &state, action: .setSelectedProject(nil))
        #expect(Set(TriageQueue.build(state: state, now: Self.now).items.map(\.id)) == ["in", "out"])
    }

    // MARK: Snoozes

    @Test("a timed snooze hides until it expires and is counted")
    func timedSnooze() {
        let snooze = ["y": TriageSnooze.timed(until: Self.now.addingTimeInterval(900), at: Self.now)]
        let hidden = build([card("y", .needsAttention)], snoozes: snooze)
        #expect(hidden.isEmpty)
        #expect(hidden.snoozedCount == 1)
        let shown = build([card("y", .needsAttention)], snoozes: snooze, now: Self.now.addingTimeInterval(901))
        #expect(shown.items.map(\.id) == ["y"])
        #expect(shown.snoozedCount == 0)
    }

    @Test("snoozed items can be listed, marked, without counting toward the wait")
    func includeSnoozed() {
        let snooze = ["y": TriageSnooze.timed(until: Self.now.addingTimeInterval(900), at: Self.now)]
        let q = TriageQueue.build(
            cards: [card("y", .needsAttention, idleFor: 9000), card("b", .blocked, idleFor: 60)],
            openRequests: [], activitySince: [:], snoozes: snooze, now: Self.now, includeSnoozed: true)
        #expect(q.items.map(\.id) == ["b", "y"])
        #expect(q.items.map(\.isSnoozed) == [false, true])
        #expect(q.snoozedCount == 1)
        #expect(q.oldestWait == 60)
    }

    @Test("an until-it-changes snooze reappears when the activity differs")
    func untilChangeSnooze() {
        let snooze = ["y": TriageSnooze.untilChange(from: .needsAttention, at: Self.now)]
        #expect(build([card("y", .needsAttention)], snoozes: snooze).isEmpty)
        #expect(build([card("y", .blocked)], snoozes: snooze).items.map(\.id) == ["y"])
    }

    @Test("a request opened after the snooze breaks it; one already open does not")
    func requestBreaksSnooze() {
        let snoozedAt = Self.now.addingTimeInterval(-100)
        let snooze = ["a": TriageSnooze.timed(until: Self.now.addingTimeInterval(900), at: snoozedAt)]
        #expect(build([card("a", .blocked)], requests: [request("a", ago: 200)], snoozes: snooze).isEmpty)
        #expect(build([card("a", .blocked)], requests: [request("a", ago: 50)], snoozes: snooze).items.map(\.id) == ["a"])
    }

    @Test("pruning drops the expired snoozes and keeps the live ones")
    func pruning() {
        let snoozes: [String: TriageSnooze] = [
            "timed-out": .timed(until: Self.now.addingTimeInterval(-1), at: Self.now.addingTimeInterval(-100)),
            "timed": .timed(until: Self.now.addingTimeInterval(100), at: Self.now),
            "changed": .untilChange(from: .needsAttention, at: Self.now),
            "same": .untilChange(from: .needsAttention, at: Self.now),
            "unknown": .untilChange(from: .needsAttention, at: Self.now),
            "missing": .timed(until: Self.now.addingTimeInterval(100), at: Self.now),
        ]
        let cards = [
            card("timed-out", .needsAttention), card("timed", .needsAttention),
            card("changed", .activelyWorking), card("same", .needsAttention), card("unknown", nil),
        ]
        let kept = TriageSnooze.pruned(snoozes, cards: cards, openRequests: [], dropMissing: false, now: Self.now)
        #expect(Set(kept.keys) == ["timed", "same", "unknown", "missing"])
        let dropped = TriageSnooze.pruned(snoozes, cards: cards, openRequests: [], dropMissing: true, now: Self.now)
        #expect(Set(dropped.keys) == ["timed", "same", "unknown"])
    }

    @Test("snoozes survive a JSON round trip")
    func snoozeCodable() throws {
        let snoozes: [String: TriageSnooze] = [
            "a": .untilChange(from: .needsAttention, at: Self.now),
            "b": .timed(until: Self.now.addingTimeInterval(60), at: Self.now),
        ]
        let data = try JSONEncoder().encode(snoozes)
        #expect(try JSONDecoder().decode([String: TriageSnooze].self, from: data) == snoozes)
    }

    // MARK: Reducer

    @Test("activitySince is stamped on a change only and drops gone sessions")
    func activitySinceReducer() {
        var state = AppState()
        _ = Reducer.reduce(state: &state, action: .activityChanged(["s1": .activelyWorking, "s2": .idleWaiting]))
        // First sight: no stamp, so the wait falls back to lastActivity.
        #expect(state.activitySince.isEmpty)

        _ = Reducer.reduce(state: &state, action: .activityChanged(["s1": .needsAttention, "s2": .idleWaiting]))
        let stamped = state.activitySince["s1"]
        #expect(stamped != nil)
        #expect(state.activitySince["s2"] == nil)

        _ = Reducer.reduce(state: &state, action: .activityChanged(["s1": .needsAttention, "s2": .blocked]))
        #expect(state.activitySince["s1"] == stamped)
        #expect(state.activitySince["s2"] != nil)

        _ = Reducer.reduce(state: &state, action: .activityChanged(["s2": .blocked]))
        #expect(state.activitySince["s1"] == nil)
        #expect(state.activitySince["s2"] != nil)
    }

    @Test("the reconcile reducer stamps changed sessions and drops removed ones")
    func activitySinceReconciled() {
        var state = AppState()
        func reconcile(_ map: [String: ActivityState]) {
            _ = Reducer.reduce(state: &state, action: .reconciled(ReconciliationResult(
                links: [], sessions: [], activityMap: map, tmuxSessions: [])))
        }
        reconcile(["s1": .activelyWorking, "s2": .idleWaiting])
        #expect(state.activitySince.isEmpty)

        let before = Date()
        reconcile(["s1": .needsAttention, "s2": .blocked])
        let s1 = state.activitySince["s1"]
        #expect(s1 != nil && s1! >= before)
        #expect(state.activitySince["s2"] != nil)

        // s1 unchanged keeps its stamp; s2 is gone from the scan.
        reconcile(["s1": .needsAttention])
        #expect(state.activitySince["s1"] == s1)
        #expect(state.activitySince["s2"] == nil)
    }

    @Test("updatedActivitySince keeps, stamps and drops")
    func updatedActivitySincePure() {
        let earlier = Self.now.addingTimeInterval(-500)
        let result = TriageQueue.updatedActivitySince(
            ["same": earlier, "gone": earlier, "changed": earlier],
            old: ["same": .idleWaiting, "gone": .idleWaiting, "changed": .activelyWorking],
            new: ["same": .idleWaiting, "changed": .needsAttention, "new": .blocked],
            now: Self.now)
        #expect(result == ["same": earlier, "changed": Self.now])
    }

    @Test("snooze and unsnooze go through the reducer")
    func snoozeActions() {
        var state = AppState()
        let snooze = TriageSnooze.timed(until: Date().addingTimeInterval(900))
        _ = Reducer.reduce(state: &state, action: .snoozeTriage(cardId: "c1", snooze: snooze))
        #expect(state.triageSnoozes["c1"] == snooze)
        _ = Reducer.reduce(state: &state, action: .unsnoozeTriage(cardId: "c1"))
        #expect(state.triageSnoozes["c1"] == nil)
    }

    @Test("restoring keeps live snoozes and drops timed-out ones")
    func restoreSnoozes() {
        var state = AppState()
        let live = TriageSnooze.timed(until: Date().addingTimeInterval(900))
        let change = TriageSnooze.untilChange(from: .needsAttention)
        let old = TriageSnooze.timed(until: Date().addingTimeInterval(-1), at: Date().addingTimeInterval(-100))
        _ = Reducer.reduce(state: &state, action: .restoreTriageSnoozes(["live": live, "change": change, "old": old]))
        #expect(Set(state.triageSnoozes.keys) == ["live", "change"])
    }

    @Test("a new attention request breaks the card's snooze")
    func attentionBreaksSnooze() {
        var state = AppState()
        _ = Reducer.reduce(state: &state, action: .snoozeTriage(
            cardId: "c1", snooze: .timed(until: Date().addingTimeInterval(900))))
        _ = Reducer.reduce(state: &state, action: .snoozeTriage(
            cardId: "c2", snooze: .timed(until: Date().addingTimeInterval(900))))
        _ = Reducer.reduce(state: &state, action: .attentionRaised(AttentionRequest(
            id: "att", cardId: "c1", kind: .question, title: "?", body: "?")))
        #expect(state.triageSnoozes["c1"] == nil)
        #expect(state.triageSnoozes["c2"] != nil)
    }

    @Test("a snooze on a card whose activity changed is pruned by the reducer")
    func reducerPrunesChangedSnooze() {
        var state = AppState()
        _ = Reducer.reduce(state: &state, action: .createManualTask(card("c", nil).link))
        _ = Reducer.reduce(state: &state, action: .activityChanged(["s-c": .needsAttention]))
        _ = Reducer.reduce(state: &state, action: .snoozeTriage(cardId: "c", snooze: .untilChange(from: .needsAttention)))
        #expect(state.triageSnoozes["c"] != nil)
        _ = Reducer.reduce(state: &state, action: .activityChanged(["s-c": .activelyWorking]))
        #expect(state.triageSnoozes["c"] == nil)
        // Back to the snoozed state: it does not hide again.
        _ = Reducer.reduce(state: &state, action: .activityChanged(["s-c": .needsAttention]))
        #expect(TriageQueue.build(state: state, now: Date()).items.map(\.id) == ["c"])
    }
}
