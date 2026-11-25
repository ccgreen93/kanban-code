import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Role hand-off")
struct RoleHandoffTests {

    private let library = RoleLibrary(
        roles: [
            Role(name: "triage", column: .backlog, body: "Triage."),
            Role(name: "build", model: "opus", effort: "high", column: .inProgress, body: "Build."),
            Role(name: "review", model: "sonnet", effort: "medium", column: .inReview, body: "Review."),
            Role(name: "merge", column: .done, body: "Merge."),
            Role(name: "codex-build", effort: "high", assistant: .codex, body: "Build with Codex."),
        ],
        transitions: RoleTransitions([
            "triage": [RoleEdge(role: "build", mode: .auto)],
            "build": [RoleEdge(role: "review", mode: .auto), RoleEdge(role: "triage")],
            "review": [RoleEdge(role: "merge")],
        ])
    )

    private func card(role: String? = "build", started: Bool = true) -> Link {
        var link = Link(
            id: "card_1", name: "Card", projectPath: "/repo", column: .inProgress, source: .manual,
            promptBody: "Add dark mode",
            sessionLink: started ? SessionLink(sessionId: "s-build", sessionPath: "/p/s-build.jsonl") : nil,
            tmuxLink: started ? TmuxLink(sessionName: "repo-card_1") : nil,
            worktreeLink: WorktreeLink(path: "/repo/.claude/worktrees/dark", branch: "dark"),
            assistant: .claude
        )
        link.role = role
        link.modelOverride = "opus"
        link.effortOverride = "high"
        return link
    }

    // MARK: - Validate

    @Test("a worker may follow an auto arrow out of its role")
    func workerAutoEdge() throws {
        let next = try RoleHandoff.validate(card: card(), next: "review", library: library, requester: .worker)
        #expect(next.name == "review")
    }

    @Test("a worker may not take an ask arrow; the error tells it to report and stop")
    func workerAskEdge() {
        #expect(throws: RoleHandoff.Failure.needsApproval(from: "build", to: "triage")) {
            try RoleHandoff.validate(card: card(), next: "triage", library: library, requester: .worker)
        }
        let message = RoleHandoff.Failure.needsApproval(from: "build", to: "triage").errorDescription ?? ""
        #expect(message.contains("stop"))
    }

    @Test("a worker may not leave the map, and the error lists the allowed roles")
    func workerOffMap() {
        let failure = RoleHandoff.Failure.notAllowed(from: "build", to: "merge", allowed: ["review", "triage"])
        #expect(throws: failure) {
            try RoleHandoff.validate(card: card(), next: "merge", library: library, requester: .worker)
        }
        #expect(failure.errorDescription?.contains("review, triage") == true)
        #expect(throws: RoleHandoff.Failure.notAllowed(from: "merge", to: "build", allowed: [])) {
            try RoleHandoff.validate(card: card(role: "merge"), next: "build", library: library, requester: .worker)
        }
    }

    @Test("a worker on a card with no role cannot hand off")
    func workerNoRole() {
        #expect(throws: RoleHandoff.Failure.cardHasNoRole) {
            try RoleHandoff.validate(card: card(role: nil), next: "build", library: library, requester: .worker)
        }
    }

    @Test("the human may move a card to any role, including from no role")
    func humanAnyRole() throws {
        #expect(try RoleHandoff.validate(card: card(), next: "merge", library: library, requester: .human).name == "merge")
        #expect(try RoleHandoff.validate(card: card(role: nil), next: "triage", library: library, requester: .human).name == "triage")
    }

    @Test("a control agent follows the same auto arrows, and may give a first role")
    func controllerRules() throws {
        #expect(try RoleHandoff.validate(card: card(), next: "review", library: library, requester: .controller).name == "review")
        #expect(throws: RoleHandoff.Failure.needsApproval(from: "build", to: "triage")) {
            try RoleHandoff.validate(card: card(), next: "triage", library: library, requester: .controller)
        }
        #expect(throws: RoleHandoff.Failure.notAllowed(from: "build", to: "merge", allowed: ["review", "triage"])) {
            try RoleHandoff.validate(card: card(), next: "merge", library: library, requester: .controller)
        }
        #expect(try RoleHandoff.validate(card: card(role: nil), next: "triage", library: library, requester: .controller).name == "triage")
    }

    @Test("unknown roles, cards not started and remote cards are refused")
    func refusals() {
        #expect(throws: RoleHandoff.Failure.unknownRole("ship")) {
            try RoleHandoff.validate(card: card(), next: "ship", library: library, requester: .human)
        }
        #expect(throws: RoleHandoff.Failure.notStarted) {
            try RoleHandoff.validate(card: card(started: false), next: "review", library: library, requester: .human)
        }
        var remote = card()
        remote.isRemote = true
        #expect(throws: RoleHandoff.Failure.remoteCard) {
            try RoleHandoff.validate(card: remote, next: "review", library: library, requester: .human)
        }
    }

    // MARK: - Apply

    @Test("applying records the stage with its session and switches role, model and effort")
    func applyRecordsStage() throws {
        let now = Date(timeIntervalSince1970: 5_000)
        let review = try #require(library.role(named: "review"))
        let after = RoleHandoff.apply(to: card(), next: review, summary: "  Built it, tests pass.  ", now: now)

        #expect(after.roleHistory == [RoleStage(
            role: "build", sessionId: "s-build", sessionPath: "/p/s-build.jsonl",
            summary: "Built it, tests pass.", handedOffTo: "review", endedAt: now)])
        #expect(after.role == "review")
        #expect(after.modelOverride == "sonnet")
        #expect(after.effortOverride == "medium")
        #expect(after.sessionLink == nil)
        #expect(after.launchedAt == now)
        // The card keeps its work.
        #expect(after.worktreeLink?.branch == "dark")
        #expect(after.promptBody == "Add dark mode")
        #expect(after.tmuxLink?.sessionName == "repo-card_1")
    }

    @Test("stages accumulate, and a role without model or effort clears the old ones")
    func applyAccumulates() throws {
        let review = try #require(library.role(named: "review"))
        let merge = try #require(library.role(named: "merge"))
        var link = RoleHandoff.apply(to: card(), next: review, summary: "one")
        link.sessionLink = SessionLink(sessionId: "s-review")
        link = RoleHandoff.apply(to: link, next: merge, summary: "")
        #expect(link.roleHistory?.map(\.role) == ["build", "review"])
        #expect(link.roleHistory?.last?.summary == nil)
        #expect(link.pastRoleSessionIds == ["s-build", "s-review"])
        #expect(link.modelOverride == nil)
        #expect(link.effortOverride == nil)
    }

    @Test("a role on another assistant switches it and drops effort the assistant lacks")
    func applySwitchesAssistant() throws {
        var start = card()
        start.apiServiceId = "svc"
        let codex = try #require(library.role(named: "codex-build"))
        let after = RoleHandoff.apply(to: start, next: codex, summary: nil)
        #expect(after.effectiveAssistant == .codex)
        #expect(after.apiServiceId == nil)
        #expect(after.effortOverride == nil)
    }

    @Test("the next prompt carries the role, the task, the summaries and the next arrows")
    func nextPrompt() throws {
        let review = try #require(library.role(named: "review"))
        let after = RoleHandoff.apply(to: card(), next: review, summary: "Built it.")
        let prompt = RoleHandoff.prompt(for: after, library: library)
        #expect(prompt.hasPrefix("# Role: review\n\nReview.\n\n# Task\n\nAdd dark mode"))
        #expect(prompt.contains("## build → review"))
        #expect(prompt.contains("Built it."))
        #expect(prompt.contains("- `merge`: needs the human's yes"))
    }

    // MARK: - Column

    @Test("free placement moves the card to the role's column; strict placement does not")
    func columnByPlacement() throws {
        let review = try #require(library.role(named: "review"))
        #expect(RoleHandoff.column(for: review, placement: .free) == .inReview)
        #expect(RoleHandoff.column(for: review, placement: .strict) == nil)
        #expect(RoleHandoff.column(for: Role(name: "x"), placement: .free) == nil)
        #expect(RoleHandoff.column(for: Role(name: "x", column: .allSessions), placement: .free) == nil)
    }

    // MARK: - Reducer

    @Test("the reducer applies a hand-off and sets a role without one")
    func reducer() throws {
        var state = AppState()
        state.links["card_1"] = card()
        let review = try #require(library.role(named: "review"))

        let effects = Reducer.reduce(state: &state, action: .applyRoleHandoff(cardId: "card_1", next: review, summary: "done"))
        #expect(state.links["card_1"]?.role == "review")
        #expect(state.links["card_1"]?.roleHistory?.count == 1)
        #expect(!effects.isEmpty)

        _ = Reducer.reduce(state: &state, action: .setCardRole(cardId: "card_1", role: library.role(named: "build")))
        #expect(state.links["card_1"]?.role == "build")
        #expect(state.links["card_1"]?.modelOverride == "opus")
        #expect(state.links["card_1"]?.roleHistory?.count == 1, "setting a role is not a stage")

        _ = Reducer.reduce(state: &state, action: .setCardRole(cardId: "card_1", role: nil))
        #expect(state.links["card_1"]?.role == nil)
        #expect(state.links["card_1"]?.modelOverride == "opus", "clearing the role keeps the model")
    }

    // MARK: - Reconciler

    @Test("the reconciler never links a past role session back onto its card")
    func reconcilerSkipsPastSessions() throws {
        let review = try #require(library.role(named: "review"))
        let handedOff = RoleHandoff.apply(to: card(), next: review, summary: "x", now: .now)
        // The old session still sits in the worktree, on the card's branch,
        // and the card has no session yet: every fuzzy rule would match it.
        let old = Session(id: "s-build", projectPath: "/repo/.claude/worktrees/dark", gitBranch: "dark",
                          messageCount: 9, modifiedTime: .now, jsonlPath: "/p/s-build.jsonl")
        let fresh = Session(id: "s-review", projectPath: "/repo/.claude/worktrees/dark", gitBranch: "dark",
                            messageCount: 1, modifiedTime: .now.addingTimeInterval(5), jsonlPath: "/p/s-review.jsonl")

        let onlyOld = CardReconciler.reconcile(existing: [handedOff], snapshot: .init(sessions: [old]))
        #expect(onlyOld.first?.sessionLink == nil)

        let both = CardReconciler.reconcile(existing: [handedOff], snapshot: .init(sessions: [old, fresh]))
        #expect(both.first?.sessionLink?.sessionId == "s-review")
    }
}
