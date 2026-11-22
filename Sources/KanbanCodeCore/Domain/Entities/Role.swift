import Foundation

/// A role a card's worker plays: preset instructions plus the model and
/// effort to run them with. Roles are data: a markdown file with a small
/// frontmatter header in `~/.kanban-code/roles/`, whose body is the
/// worker's instructions. See `docs/roles.md`.
public struct Role: Codable, Sendable, Equatable, Identifiable {
    /// Unique name, used on cards (`Link.role`) and in `transitions.json`.
    public var name: String
    /// What the role does and what needs a human yes.
    public var description: String?
    /// Model passed as `--model` (an alias like `opus` or a full id).
    public var model: String?
    /// Reasoning effort passed as `--effort` (Claude only).
    public var effort: String?
    /// Assistant the role runs on. Nil keeps the dialog's choice.
    public var assistant: CodingAssistant?
    /// Skill the instructions lean on, for example `bmad-build`. Shown in
    /// pickers; the body says how to use it.
    public var skill: String?
    /// Column a hand-off moves the card to when the board uses free
    /// placement. Ignored in strict placement, where columns follow activity.
    public var column: KanbanCodeColumn?
    /// Only one card of this role may run at a time (shared ports, a shared
    /// browser). Not enforced yet.
    public var singleton: Bool
    /// A control role: its card may hand off other cards
    /// (`kanban role handoff <next> --card <id>`), under the same rules as
    /// their own workers.
    public var controls: Bool
    /// The worker's instructions (the markdown after the frontmatter).
    public var body: String

    public var id: String { name }

    public init(
        name: String,
        description: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        assistant: CodingAssistant? = nil,
        skill: String? = nil,
        column: KanbanCodeColumn? = nil,
        singleton: Bool = false,
        controls: Bool = false,
        body: String = ""
    ) {
        self.name = name
        self.description = description
        self.model = model
        self.effort = effort
        self.assistant = assistant
        self.skill = skill
        self.column = column
        self.singleton = singleton
        self.controls = controls
        self.body = body
    }
}

/// One arrow in the role pipeline.
public struct RoleEdge: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable {
        /// The worker may hand off without asking.
        case auto
        /// The hand-off waits for the human's yes.
        case ask
    }

    public var role: String
    public var mode: Mode

    public init(role: String, mode: Mode = .ask) {
        self.role = role
        self.mode = mode
    }

    /// Accepts `"review"` (an `ask` edge) or `{"role": "review", "mode": "auto"}`.
    public init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self.init(role: name)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            role: try c.decode(String.self, forKey: .role),
            mode: try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .ask
        )
    }

    public func encode(to encoder: Encoder) throws {
        if mode == .ask {
            var c = encoder.singleValueContainer()
            try c.encode(role)
        } else {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(role, forKey: .role)
            try c.encode(mode, forKey: .mode)
        }
    }

    private enum CodingKeys: String, CodingKey { case role, mode }
}

/// The pipeline: which roles may follow which. Kept in one file
/// (`transitions.json`) so a role can be added or shared without editing
/// the others. A role with no entry, or an empty list, is terminal.
public struct RoleTransitions: Codable, Sendable, Equatable {
    public var edges: [String: [RoleEdge]]

    public init(_ edges: [String: [RoleEdge]] = [:]) {
        self.edges = edges
    }

    public init(from decoder: Decoder) throws {
        edges = try decoder.singleValueContainer().decode([String: [RoleEdge]].self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(edges)
    }

    public func next(after role: String) -> [RoleEdge] {
        edges[role] ?? []
    }

    public func isTerminal(_ role: String) -> Bool {
        next(after: role).isEmpty
    }
}

/// One finished stage of a card's role pipeline. A hand-off ends the
/// card's session and starts a fresh one for the next role, so the stage
/// keeps the old session: it stays readable and resumable, and the
/// reconciler never links it back onto the card.
public struct RoleStage: Codable, Sendable, Equatable {
    /// The role that ran this stage. Nil when the card had no role yet.
    public var role: String?
    public var sessionId: String?
    public var sessionPath: String?
    /// What the worker (or the human) said when handing off.
    public var summary: String?
    /// The role the card moved to.
    public var handedOffTo: String
    public var endedAt: Date

    public init(
        role: String?,
        sessionId: String? = nil,
        sessionPath: String? = nil,
        summary: String? = nil,
        handedOffTo: String,
        endedAt: Date = .now
    ) {
        self.role = role
        self.sessionId = sessionId
        self.sessionPath = sessionPath
        self.summary = summary
        self.handedOffTo = handedOffTo
        self.endedAt = endedAt
    }
}
