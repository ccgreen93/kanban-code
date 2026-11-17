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

    /// A transcript whose newest message is `messageAgo` seconds old and
    /// whose file was last touched `touchedAgo` seconds ago, followed by the
    /// system lines Claude writes while it waits.
    private func transcript(messageAgo: TimeInterval, touchedAgo: TimeInterval? = nil) -> (path: String, cleanup: () -> Void) {
        let dir = NSTemporaryDirectory() + "kanban-code-blocked-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("t.jsonl")
        let text = TranscriptFixture.message(at: Date.now.addingTimeInterval(-messageAgo))
            + TranscriptFixture.systemLine(at: Date.now.addingTimeInterval(-messageAgo + 0.1))
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-(touchedAgo ?? messageAgo))], ofItemAtPath: path)
        return (path, { try? FileManager.default.removeItem(atPath: dir) })
    }

    private func state(
        after event: String, ago: TimeInterval, messageAgo: TimeInterval, touchedAgo: TimeInterval? = nil,
        type: String? = "permission_prompt"
    ) async -> ActivityState {
        let detector = ClaudeCodeActivityDetector()
        await detector.handleHookEvent(HookEvent(
            sessionId: "s1", eventName: event, notificationType: event == "Notification" ? type : nil,
            timestamp: Date.now.addingTimeInterval(-ago)
        ))
        let file = transcript(messageAgo: messageAgo, touchedAgo: touchedAgo)
        defer { file.cleanup() }
        _ = await detector.pollActivity(sessionPaths: ["s1": file.path])
        return await detector.activityState(for: "s1")
    }

    @Test("A prompt still open stays blocked, even right after the question was written")
    func openPromptStaysBlocked() async {
        // Claude writes the question, then the notification fires.
        #expect(await state(after: "Notification", ago: 1, messageAgo: 4) == .blocked)
        #expect(await state(after: "Notification", ago: 600, messageAgo: 606) == .blocked)
    }

    @Test("An answered prompt reads as working through a long quiet tool run")
    func answeredPromptStaysWorking() async {
        // Answered, then a test run writes nothing for a minute: no flicker to red.
        #expect(await state(after: "Notification", ago: 120, messageAgo: 60) == .activelyWorking)
        #expect(await state(after: "Notification", ago: 30, messageAgo: 2) == .activelyWorking)
    }

    @Test("An answered prompt whose turn went silent past the timeout stops reading as working")
    func answeredPromptTimesOut() async {
        #expect(await state(after: "Notification", ago: 900, messageAgo: 400) == .needsAttention)
    }

    @Test("Waking the Mac touches idle transcripts; that is not work")
    func wakeTouchIsNotWork() async {
        // Idle reminder days ago, newest message before it, file touched now.
        let days: TimeInterval = 5 * 86400
        #expect(await state(after: "Notification", ago: days, messageAgo: days + 120, touchedAgo: 1,
                            type: "idle_prompt") == .needsAttention)
        #expect(await state(after: "Notification", ago: days, messageAgo: days + 6, touchedAgo: 1) == .blocked)
        #expect(await state(after: "Stop", ago: days, messageAgo: days + 0.5, touchedAgo: 1) == .needsAttention)
    }

    @Test("The newest message is found past large lines and trailing metadata")
    func readsNewestMessage() throws {
        let dir = NSTemporaryDirectory() + "kanban-code-stamp-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("t.jsonl")
        let when = Date(timeIntervalSince1970: 1_800_000_000.25)
        let big = String(repeating: "x", count: 200_000)
        let text = TranscriptFixture.message(at: when.addingTimeInterval(-60))
            + TranscriptFixture.message(at: when, text: big)
            + "{\"type\":\"bridge-session\",\"sessionId\":\"s1\"}\n"
            + TranscriptFixture.systemLine(at: when.addingTimeInterval(5))
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        let stamp = try #require(ClaudeCodeActivityDetector.readLastConversationStamp(path))
        #expect(abs(stamp.timeIntervalSince(when)) < 0.01)
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

/// Transcript lines shaped like Claude Code's.
enum TranscriptFixture {
    static func stamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func message(at date: Date, text: String = "ok") -> String {
        "{\"type\":\"assistant\",\"sessionId\":\"s1\",\"timestamp\":\"\(stamp(date))\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"\(text)\"}]}}\n"
    }

    static func systemLine(at date: Date) -> String {
        "{\"type\":\"system\",\"subtype\":\"turn_duration\",\"sessionId\":\"s1\",\"timestamp\":\"\(stamp(date))\"}\n"
    }
}
