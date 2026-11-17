import Foundation
import Testing

@testable import KanbanCodeCore

/// `kanban launch` and `kanban agent add|remove` move cards into and out of
/// the Agents section through the app's command mailbox.
@Suite("setAgent command", .serialized)
@MainActor
struct SetAgentCommandTests {
    let home: String
    let store: BoardStore
    let engine: MasterEngine

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanban-set-agent-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let coordination = CoordinationStore(basePath: home)
        let tmux = TmuxAdapter()
        store = BoardStore(
            effectHandler: EffectHandler(
                coordinationStore: coordination, tmuxAdapter: tmux,
                queuedPromptJournal: QueuedPromptJournal(basePath: home)),
            discovery: ClaudeCodeSessionDiscovery(),
            coordinationStore: coordination
        )
        var platform = MasterPlatform()
        platform.kanbanHome = home
        platform.projectsDirectory = "\(home)/Projects"
        platform.claudeProjectsDirectory = "\(home)/claude-projects"
        engine = MasterEngine(
            store: store,
            settingsStore: SettingsStore(basePath: home),
            launcher: LaunchSession(tmux: tmux),
            tmux: RoutingTmuxAdapter(rush: RushCliAdapter(executable: "/nonexistent/rush")),
            registry: CodingAssistantRegistry(),
            platform: platform
        )
    }

    private func send(_ request: SubagentCommandRequest) async throws -> SubagentCommandResponse {
        let inbox = URL(fileURLWithPath: home).appendingPathComponent("commands/inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try JSONEncoder().encode(request).write(to: inbox.appendingPathComponent("\(request.id).json"))
        await engine.processSubagentCommand(id: request.id)
        let response = URL(fileURLWithPath: home).appendingPathComponent("commands/responses/\(request.id).json")
        return try JSONDecoder().decode(SubagentCommandResponse.self, from: Data(contentsOf: response))
    }

    private func request(cardId: String, sessionId: String? = nil, tmuxName: String? = nil, isAgent: Bool?) -> SubagentCommandRequest {
        SubagentCommandRequest(
            id: UUID().uuidString.lowercased(),
            operation: .setAgent,
            createdAt: ISO8601DateFormatter().string(from: .now),
            parentCardId: cardId,
            cardId: cardId,
            name: tmuxName,
            sessionId: sessionId,
            isAgent: isAgent
        )
    }

    @Test("a launched card the app replaced is found by its session and moved to Agents")
    func findsBySession() async throws {
        // The app's own card for the session, not the one the CLI wrote.
        let card = Link(
            id: "card_app", name: "conductor", column: .inProgress, source: .manual,
            sessionLink: SessionLink(sessionId: "session-1")
        )
        store.dispatch(.createManualTask(card))

        let response = try await send(request(cardId: "card_cli", sessionId: "session-1", isAgent: nil))
        #expect(response.ok, "\(response.error ?? "")")
        #expect(response.cardId == "card_app")
        #expect(store.state.links["card_app"]?.isAgent == true)
    }

    @Test("a card is found by its tmux name, and moves back to the board")
    func findsByTmuxAndRemoves() async throws {
        let card = Link(
            id: "card_app", name: "butler", column: .waiting, source: .manual,
            tmuxLink: TmuxLink(sessionName: "butler"), agentAt: .now
        )
        store.dispatch(.createManualTask(card))

        let response = try await send(request(cardId: "card_cli", tmuxName: "butler", isAgent: false))
        #expect(response.ok, "\(response.error ?? "")")
        #expect(store.state.links["card_app"]?.isAgent == false)
    }

    @Test("a subagent cannot be an agent")
    func refusesSubagents() async throws {
        let parent = Link(id: "card_parent", name: "parent", column: .inProgress, source: .manual)
        let child = Link(id: "card_child", name: "child", column: .inProgress, source: .manual, parentCardId: "card_parent")
        store.dispatch(.createManualTask(parent))
        store.dispatch(.createManualTask(child))

        let response = try await send(request(cardId: "card_child", isAgent: true))
        #expect(!response.ok)
        #expect(response.error?.contains("subagent") == true)
        #expect(store.state.links["card_child"]?.isAgent == false)
    }
}
