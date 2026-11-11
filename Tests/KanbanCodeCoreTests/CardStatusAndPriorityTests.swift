import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Card status tone and priority")
struct CardStatusAndPriorityTests {

    // MARK: - Blocked detection

    @Test("Permission prompt notification → blocked")
    func permissionPromptBlocks() async {
        let detector = ClaudeCodeActivityDetector()
        await detector.handleHookEvent(HookEvent(
            sessionId: "s1", eventName: "Notification", notificationType: "permission_prompt"
        ))
        #expect(await detector.activityState(for: "s1") == .blocked)
    }

    @Test("Idle prompt notification → needsAttention, not blocked")
    func idlePromptIsDone() async {
        let detector = ClaudeCodeActivityDetector()
        await detector.handleHookEvent(HookEvent(
            sessionId: "s1", eventName: "Notification", notificationType: "idle_prompt",
            message: "Claude is waiting for your input"
        ))
        #expect(await detector.activityState(for: "s1") == .needsAttention)
    }

    @Test("Permission message without a type → blocked")
    func permissionMessageBlocks() async {
        let detector = ClaudeCodeActivityDetector()
        await detector.handleHookEvent(HookEvent(
            sessionId: "s1", eventName: "Notification",
            message: "Claude needs your permission to use Bash"
        ))
        #expect(await detector.activityState(for: "s1") == .blocked)
    }

    @Test("Blocked cards go to Waiting")
    func blockedAssignsWaiting() {
        let link = Link(column: .inProgress, sessionLink: SessionLink(sessionId: "s1"))
        #expect(AssignColumn.assign(link: link, activityState: .blocked) == .waiting)
    }

    // MARK: - Status tone

    @Test("Status tone follows the session")
    func tones() {
        let link = Link(sessionLink: SessionLink(sessionId: "s1"))
        #expect(KanbanCodeCard(link: link, activityState: .blocked).statusTone() == .blocked)
        #expect(KanbanCodeCard(link: link, activityState: .activelyWorking).statusTone() == .working)
        #expect(KanbanCodeCard(link: link, activityState: .needsAttention).statusTone() == .done)
        #expect(KanbanCodeCard(link: link, activityState: .idleWaiting, sessionStatus: .live).statusTone() == .idle)
        #expect(KanbanCodeCard(link: link, activityState: .ended).statusTone() == nil)
        #expect(KanbanCodeCard(link: link).statusTone() == nil)
    }

    @Test("A failed start reads as blocked, even while busy")
    func failedIsBlocked() {
        let link = Link(sessionLink: SessionLink(sessionId: "s1"))
        let card = KanbanCodeCard(link: link, isBusy: true, sessionStatus: .failed("boom"))
        #expect(card.statusTone() == .blocked)
    }

    // MARK: - Priority

    @Test("setCardPriority sets and clears the priority")
    func reducerSetsPriority() {
        var state = AppState()
        state.links["c1"] = Link(id: "c1")

        let effects = Reducer.reduce(state: &state, action: .setCardPriority(cardId: "c1", priority: .high))
        #expect(state.links["c1"]?.priority == .high)
        #expect(effects.contains(where: { if case .upsertLink = $0 { return true }; return false }))

        let same = Reducer.reduce(state: &state, action: .setCardPriority(cardId: "c1", priority: .high))
        #expect(same.isEmpty, "setting the same priority writes nothing")

        _ = Reducer.reduce(state: &state, action: .setCardPriority(cardId: "c1", priority: nil))
        #expect(state.links["c1"]?.priority == nil)
    }

    @Test("Priority round-trips and an unknown value reads as none")
    func priorityCodable() throws {
        let link = Link(id: "c1", priority: .urgent)
        let data = try JSONEncoder().encode(link)
        #expect(try JSONDecoder().decode(Link.self, from: data).priority == .urgent)

        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["priority"] = "someday"
        let odd = try JSONSerialization.data(withJSONObject: json)
        #expect(try JSONDecoder().decode(Link.self, from: odd).priority == nil)
    }

    @Test("Priority syncs between masters")
    func prioritySyncs() {
        #expect(LinkSync.sharedFields.contains(where: { $0.name == "priority" }))
    }

    @Test("Priorities order by urgency")
    func ordering() {
        #expect(CardPriority.allCases.sorted(by: >) == [.urgent, .high, .medium, .low])
    }
}
