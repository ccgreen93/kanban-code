import Foundation
import Testing

@testable import KanbanCodeCore

/// A session whose main agent is back at the prompt can still have subagents
/// working under it. Claude Code says so with SubagentStart and SubagentStop,
/// which carry the session that started them.
@Suite("Subagents working under a stopped session")
struct SubagentActivityTests {

    private func detector() -> ClaudeCodeActivityDetector {
        // No grace period, so a Stop is final the moment it lands.
        ClaudeCodeActivityDetector(stopDelay: 0)
    }

    @Test("a session that stopped with a subagent running is still working")
    func stopWithRunningSubagent() async {
        let detector = detector()

        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "UserPromptSubmit"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStart"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Stop"))

        #expect(await detector.activityState(for: "s1") == .activelyWorking)
    }

    @Test("the session goes idle when its last subagent stops")
    func lastSubagentStopEndsTheWork() async {
        let detector = detector()

        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStart"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Stop"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStop"))

        #expect(await detector.activityState(for: "s1") == .needsAttention)
    }

    @Test("one of three subagents finishing leaves the session working")
    func remainingSubagentsKeepWorking() async {
        let detector = detector()

        for _ in 0..<3 {
            await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStart"))
        }
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Stop"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStop"))

        #expect(await detector.activityState(for: "s1") == .activelyWorking)

        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStop"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStop"))

        #expect(await detector.activityState(for: "s1") == .needsAttention)
    }

    /// The app reads the event file from where it stopped, so it can see a
    /// stop whose start it never read.
    @Test("a stop with no start of its own leaves the session idle")
    func unmatchedStopIsNotCountedBelowZero() async {
        let detector = detector()

        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Stop"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStop"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStart"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStop"))

        #expect(await detector.activityState(for: "s1") == .needsAttention)
    }

    @Test("subagent events belong to the session that started them")
    func subagentsAreCountedPerSession() async {
        let detector = detector()

        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Stop"))
        await detector.handleHookEvent(HookEvent(sessionId: "s2", eventName: "Stop"))
        await detector.handleHookEvent(HookEvent(sessionId: "s2", eventName: "SubagentStart"))

        #expect(await detector.activityState(for: "s1") == .needsAttention)
        #expect(await detector.activityState(for: "s2") == .activelyWorking)
    }

    /// A session killed while its subagents work never sends their stops.
    @Test("a subagent that never stopped stops counting after its timeout")
    func abandonedSubagentExpires() async {
        let detector = ClaudeCodeActivityDetector(stopDelay: 0, subagentTimeout: 1)

        await detector.handleHookEvent(
            HookEvent(
                sessionId: "s1", eventName: "SubagentStart",
                timestamp: Date.now.addingTimeInterval(-60))
        )
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Stop"))

        #expect(await detector.activityState(for: "s1") == .needsAttention)
    }

    @Test("a subagent still inside its timeout counts")
    func freshSubagentCounts() async {
        let detector = ClaudeCodeActivityDetector(stopDelay: 0, subagentTimeout: 3600)

        await detector.handleHookEvent(
            HookEvent(
                sessionId: "s1", eventName: "SubagentStart",
                timestamp: Date.now.addingTimeInterval(-60))
        )
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Stop"))

        #expect(await detector.activityState(for: "s1") == .activelyWorking)
    }

    @Test("a closed session is ended, whatever it had running")
    func sessionEndWins() async {
        let detector = detector()

        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStart"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SessionEnd"))

        #expect(await detector.activityState(for: "s1") == .ended)
    }

    @Test("a resumed session starts counting again from nothing")
    func sessionStartClearsSubagents() async {
        let detector = detector()

        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStart"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SessionStart"))

        #expect(await detector.activityState(for: "s1") == .idleWaiting)
    }

    @Test("a real fresh start clears subagents whatever its source says")
    func explicitStartupClearsSubagents() async {
        let detector = detector()

        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStart"))
        await detector.handleHookEvent(
            HookEvent(sessionId: "s1", eventName: "SessionStart", source: "startup"))

        #expect(await detector.activityState(for: "s1") == .idleWaiting)
    }

    /// A compaction fires SessionStart, but the process lives on and its
    /// background subagents keep running. One compaction mid-task turned
    /// off the spinner of a session with two subagents still at work.
    @Test("a compaction does not clear running subagents")
    func compactionKeepsSubagents() async {
        let detector = detector()

        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStart"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStart"))
        await detector.handleHookEvent(
            HookEvent(sessionId: "s1", eventName: "SessionStart", source: "compact"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStop"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Stop"))

        #expect(await detector.activityState(for: "s1") == .activelyWorking)

        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStop"))

        #expect(await detector.activityState(for: "s1") == .needsAttention)
    }

    @Test("a compaction does not interrupt the turn it lands in")
    func compactionKeepsTheTurn() async {
        let detector = detector()

        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "UserPromptSubmit"))
        await detector.handleHookEvent(
            HookEvent(sessionId: "s1", eventName: "SessionStart", source: "compact"))

        #expect(await detector.activityState(for: "s1") == .activelyWorking)
    }

    /// Subagent events say what runs under the session, not what the session
    /// is doing, so they must not take the place of its own last event.
    @Test("a subagent event does not overwrite what the session last did")
    func subagentEventIsNotTheSessionsLastEvent() async {
        let detector = detector()

        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "UserPromptSubmit"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStart"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStop"))

        // Still mid-turn: the prompt is the last thing the session itself did.
        #expect(await detector.activityState(for: "s1") == .activelyWorking)
    }

    @Test("a session with subagents running lands in the in progress column")
    func workingSessionMovesToInProgress() async {
        var link = Link(id: "card_1", column: .waiting)

        UpdateCardColumn.update(link: &link, activityState: .activelyWorking, hasWorktree: true, hasLiveSession: true)

        #expect(link.column == .inProgress)
    }

    @Test("the hooks the app installs cover subagents")
    func requiredHooksCoverSubagents() {
        let hooks = HookManager.requiredHooks(for: .claude)

        #expect(hooks.contains("SubagentStart"))
        #expect(hooks.contains("SubagentStop"))
    }

    // MARK: - Subagent transcripts

    /// A session transcript with a `subagents` folder whose newest transcript
    /// was written `quietFor` seconds ago.
    private func session(subagentsQuietFor quietFor: TimeInterval) throws -> (path: String, cleanup: () -> Void) {
        let dir = NSTemporaryDirectory() + "kanban-code-subagents-\(UUID().uuidString)"
        let sub = dir + "/s1/subagents"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        let path = dir + "/s1.jsonl"
        try "".write(toFile: path, atomically: true, encoding: .utf8)
        for (name, age) in [("agent-a.jsonl", quietFor), ("agent-b.jsonl", quietFor + 600)] {
            let file = sub + "/" + name
            try "{}\n".write(toFile: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-age)], ofItemAtPath: file)
        }
        try "{}".write(toFile: sub + "/agent-c.meta.json", atomically: true, encoding: .utf8)
        return (path, { try? FileManager.default.removeItem(atPath: dir) })
    }

    private func stateWithOldStart(subagentsQuietFor quietFor: TimeInterval) async throws -> ActivityState {
        let detector = ClaudeCodeActivityDetector(stopDelay: 0)
        await detector.handleHookEvent(HookEvent(
            sessionId: "s1", eventName: "SubagentStart", timestamp: Date.now.addingTimeInterval(-1800)))
        await detector.handleHookEvent(HookEvent(
            sessionId: "s1", eventName: "Stop", timestamp: Date.now.addingTimeInterval(-1700)))
        let file = try session(subagentsQuietFor: quietFor)
        defer { file.cleanup() }
        _ = await detector.pollActivity(sessionPaths: ["s1": file.path])
        return await detector.activityState(for: "s1")
    }

    /// A stop hook that never reached the app kept a finished session on the
    /// in progress column for two hours.
    @Test("subagents whose transcripts went quiet are not running, stop or no stop")
    func quietSubagentsAreDone() async throws {
        #expect(try await stateWithOldStart(subagentsQuietFor: 900) == .needsAttention)
    }

    @Test("a subagent still writing its transcript keeps the session working")
    func writingSubagentKeepsWorking() async throws {
        #expect(try await stateWithOldStart(subagentsQuietFor: 20) == .activelyWorking)
    }

    @Test("a subagent that just started counts before it writes anything")
    func freshStartCountsBeforeItsTranscript() async throws {
        let detector = ClaudeCodeActivityDetector(stopDelay: 0)
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "SubagentStart"))
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "Stop"))
        let file = try session(subagentsQuietFor: 3600)
        defer { file.cleanup() }
        _ = await detector.pollActivity(sessionPaths: ["s1": file.path])
        #expect(await detector.activityState(for: "s1") == .activelyWorking)
    }
}
