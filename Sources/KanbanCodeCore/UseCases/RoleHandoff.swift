import Foundation

/// Moving a card from one role to the next. The worker runs
/// `kanban role handoff <next> "summary"` in its own card, or the human
/// picks Hand Off in the card menu. Either way the card keeps its worktree,
/// branch and pull requests, records the finished stage, and starts a fresh
/// session with the next role's model, effort and instructions plus the
/// summaries so far.
public enum RoleHandoff {

    public enum Failure: Error, LocalizedError, Equatable {
        case cardNotFound(String)
        case unknownRole(String)
        case cardHasNoRole
        case notAllowed(from: String, to: String, allowed: [String])
        case needsApproval(from: String, to: String)
        case remoteCard
        case notStarted
        case notAController(String)

        public var errorDescription: String? {
            switch self {
            case .cardNotFound(let id):
                return "Card \(id) was not found."
            case .unknownRole(let name):
                return "There is no role named \"\(name)\" in ~/.kanban-code/roles."
            case .cardHasNoRole:
                return "This card has no role, so it has no hand-offs. Report and stop; the human can give it a role."
            case .notAllowed(let from, let to, let allowed):
                let list = allowed.isEmpty ? "none, \(from) is the last role" : allowed.joined(separator: ", ")
                return "\(from) cannot hand off to \(to). Allowed: \(list)."
            case .needsApproval(let from, let to):
                return "Handing off from \(from) to \(to) needs the human's yes. Report what you did and that you recommend \(to), then stop. The human hands off from the card."
            case .remoteCard:
                return "Role hand-off does not support cards running on another machine yet."
            case .notAController(let role):
                return "Only a card whose role controls other cards (controls: true) can hand off another card; this card's role is \(role)."
            case .notStarted:
                return "This card has not started yet. Pick its role and start it instead."
            }
        }
    }

    /// Who asks for a hand-off.
    public enum Requester: Equatable, Sendable {
        /// The card's own agent.
        case worker
        /// A card whose role has `controls: true`, acting on another card.
        case controller
        /// The human, from the card menu.
        case human
    }

    /// Checks a hand-off and returns the next role. A worker or a control
    /// agent may follow only the `auto` arrows out of the card's role; a
    /// control agent may also give a first role to a card without one. The
    /// human may move a card to any role.
    public static func validate(
        card: Link,
        next: String,
        library: RoleLibrary,
        requester: Requester
    ) throws -> Role {
        guard let nextRole = library.role(named: next) else { throw Failure.unknownRole(next) }
        // Ownership by another master is checked by the engine, which knows
        // this machine's id.
        guard card.remote == nil, !card.isRemote else { throw Failure.remoteCard }
        guard card.sessionLink != nil || card.tmuxLink != nil else { throw Failure.notStarted }
        if requester == .human { return nextRole }

        guard let current = card.role else {
            if requester == .controller { return nextRole }
            throw Failure.cardHasNoRole
        }
        let edges = library.transitions.next(after: current)
        guard let edge = edges.first(where: { $0.role == next }) else {
            throw Failure.notAllowed(from: current, to: next, allowed: edges.map(\.role))
        }
        guard edge.mode == .auto else { throw Failure.needsApproval(from: current, to: next) }
        return nextRole
    }

    /// The card after the hand-off: the finished stage recorded with its
    /// session, the next role's settings, and no session link, so the
    /// relaunch links the new session. The reconciler skips the recorded
    /// sessions, so the old one is never linked back.
    public static func apply(to link: Link, next: Role, summary: String?, now: Date = .now) -> Link {
        var link = link
        let trimmed = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stage = RoleStage(
            role: link.role,
            sessionId: link.sessionLink?.sessionId,
            sessionPath: link.sessionLink?.sessionPath,
            summary: (trimmed?.isEmpty ?? true) ? nil : trimmed,
            handedOffTo: next.name,
            endedAt: now
        )
        link.roleHistory = (link.roleHistory ?? []) + [stage]
        link.role = next.name
        if let assistant = next.assistant, assistant != link.effectiveAssistant {
            link.assistant = assistant
            link.apiServiceId = nil
        }
        // A role without a model or effort runs on the assistant's default,
        // not on whatever the previous role picked.
        link.modelOverride = next.model
        link.effortOverride = link.effectiveAssistant.supportsEffort ? next.effort : nil
        link.sessionLink = nil
        // Until the relaunch, the reconciler may give a card without a
        // session one that started after its launch. Counting from now keeps
        // it from picking up any session started in the project since the
        // old one.
        link.launchedAt = now
        link.updatedAt = now
        return link
    }

    /// The new session's first prompt: the role, the card's task, every
    /// earlier stage's summary, and how to hand off in turn.
    public static func prompt(
        for link: Link,
        library: RoleLibrary,
        project: Project? = nil,
        settings: Settings? = nil
    ) -> String {
        PromptBuilder.buildPrompt(card: link, project: project, settings: settings, roles: library)
    }

    /// Where a hand-off moves the card in free placement: the next role's
    /// column. Strict placement and roles without a column leave it to the
    /// activity rules. All Sessions is never a target, since moving there
    /// archives the card.
    public static func column(for role: Role, placement: CardPlacementMode) -> KanbanCodeColumn? {
        guard placement == .free, let column = role.column, column != .allSessions else { return nil }
        return column
    }
}
