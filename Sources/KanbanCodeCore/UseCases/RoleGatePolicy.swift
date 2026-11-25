import Foundation

/// `~/.kanban-code/roles/gates.json`: what a role card's agent may run on its
/// own. Each `GateAction` is `allow`, `ask` or `deny`; a project's setting
/// beats a role's, which beats the defaults.
///
/// ```json
/// {
///   "defaults": { "merge": "deny", "deploy": "deny" },
///   "protectedBranches": ["main", "master", "release/*"],
///   "deployPatterns": ["^ssh vx-pi .*compose up"],
///   "roles": { "review": { "merge": "ask" } },
///   "projects": {
///     "~/dev/cg/homelab": { "deploy": "ask", "deployPatterns": ["^./bin/ship"] },
///     "~/dev/cg/scratch": { "merge": "allow" }
///   }
/// }
/// ```
public struct RoleGatePolicy: Sendable, Equatable {
    public static let builtInDefaults: [GateAction: GateMode] = [
        .push: .allow,
        .pr: .allow,
        .protectedPush: .deny,
        .forcePush: .deny,
        .approve: .deny,
        .merge: .deny,
        .deploy: .deny,
    ]

    public struct Overrides: Sendable, Equatable {
        public var modes: [GateAction: GateMode] = [:]
        public var deployPatterns: [String] = []
        public var protectedBranches: [String]?

        public init(modes: [GateAction: GateMode] = [:], deployPatterns: [String] = [], protectedBranches: [String]? = nil) {
            self.modes = modes
            self.deployPatterns = deployPatterns
            self.protectedBranches = protectedBranches
        }
    }

    public var defaults: [GateAction: GateMode]
    public var protectedBranches: [String]
    public var deployPatterns: [String]
    public var roles: [String: Overrides]
    /// Keyed by absolute path.
    public var projects: [String: Overrides]

    public init(
        defaults: [GateAction: GateMode] = builtInDefaults,
        protectedBranches: [String] = RoleGateClassifier.defaultProtectedBranches,
        deployPatterns: [String] = [],
        roles: [String: Overrides] = [:],
        projects: [String: Overrides] = [:]
    ) {
        self.defaults = defaults
        self.protectedBranches = protectedBranches
        self.deployPatterns = deployPatterns
        self.roles = roles
        self.projects = projects
    }

    public static var defaultPath: String {
        (RoleLibrary.defaultDirectory as NSString).appendingPathComponent("gates.json")
    }

    /// The policy in `path`, or the built-in one when there is no file. A file
    /// that does not parse also gives the built-in one, which only refuses more.
    public static func load(path: String = defaultPath) -> RoleGatePolicy {
        guard let data = FileManager.default.contents(atPath: path) else { return RoleGatePolicy() }
        guard let policy = parse(data) else {
            KanbanCodeLog.warn("roles", "Could not read \(path); using the built-in gates")
            return RoleGatePolicy()
        }
        return policy
    }

    public static func parse(_ data: Data) -> RoleGatePolicy? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var policy = RoleGatePolicy()
        if let defaults = root["defaults"] as? [String: Any] {
            for (action, mode) in modes(defaults) { policy.defaults[action] = mode }
        }
        if let branches = root["protectedBranches"] as? [String] { policy.protectedBranches = branches }
        policy.deployPatterns = root["deployPatterns"] as? [String] ?? []
        for (name, value) in root["roles"] as? [String: Any] ?? [:] {
            if let object = value as? [String: Any] { policy.roles[name] = overrides(object) }
        }
        for (path, value) in root["projects"] as? [String: Any] ?? [:] {
            if let object = value as? [String: Any] { policy.projects[expand(path)] = overrides(object) }
        }
        return policy
    }

    private static func modes(_ object: [String: Any]) -> [GateAction: GateMode] {
        var result: [GateAction: GateMode] = [:]
        for (key, value) in object {
            guard let action = GateAction(rawValue: key),
                  let raw = value as? String, let mode = GateMode(rawValue: raw.lowercased()) else { continue }
            result[action] = mode
        }
        return result
    }

    private static func overrides(_ object: [String: Any]) -> Overrides {
        Overrides(
            modes: modes(object),
            deployPatterns: object["deployPatterns"] as? [String] ?? [],
            protectedBranches: object["protectedBranches"] as? [String]
        )
    }

    static func expand(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.count > 1 && expanded.hasSuffix("/") ? String(expanded.dropLast()) : expanded
    }

    /// The project overrides for a card at these paths: the longest key that
    /// is one of them or a folder above one.
    public func project(for paths: [String]) -> Overrides? {
        let candidates = paths.map(Self.expand)
        return projects
            .filter { key, _ in candidates.contains { $0 == key || $0.hasPrefix(key + "/") } }
            .max { $0.key.count < $1.key.count }?
            .value
    }

    public func mode(for action: GateAction, role: String?, project: Overrides?) -> GateMode {
        project?.modes[action]
            ?? role.flatMap { roles[$0]?.modes[action] }
            ?? defaults[action]
            ?? Self.builtInDefaults[action]
            ?? .deny
    }
}

/// Decides what happens to a command a role card's agent wants to run.
public enum RoleGate {
    public enum Decision: Sendable, Equatable {
        case allow
        /// Allowed because the human approved this exact command.
        case approved
        case ask(PendingGate, reason: String)
        case deny(reason: String)
    }

    /// The refusal or hold the CLI hands back to the agent's hook.
    public struct Blocked: LocalizedError {
        public let reason: String
        public var errorDescription: String? { reason }
    }

    public static func decide(
        card: Link,
        command: String,
        branch: String?,
        policy: RoleGatePolicy,
        now: Date = .now
    ) -> Decision {
        guard let role = card.role else { return .allow }
        let paths = [card.projectPath, card.worktreeLink?.path].compactMap { $0 }
        let project = policy.project(for: paths)
        let matches = RoleGateClassifier.classify(
            command,
            branch: branch ?? card.worktreeLink?.branch,
            protectedBranches: project?.protectedBranches ?? policy.protectedBranches,
            deployPatterns: policy.deployPatterns + (project?.deployPatterns ?? [])
        )
        guard !matches.isEmpty else { return .allow }
        let ranked = matches.map { ($0, policy.mode(for: $0.action, role: role, project: project)) }
        guard let (worst, mode) = ranked.max(by: { $0.1 < $1.1 }) else { return .allow }
        switch mode {
        case .allow:
            return .allow
        case .deny:
            return .deny(reason: denyReason(worst, role: role))
        case .ask:
            if card.gateAllowances?.contains(command) == true { return .approved }
            let pending = PendingGate(action: worst.action, command: command, role: role, requestedAt: now)
            return .ask(pending, reason: askReason(worst, role: role))
        }
    }

    static func denyReason(_ match: GateMatch, role: String) -> String {
        let next: String
        switch match.action {
        case .merge, .approve:
            next = "That is the human's step. Report that the pull request is ready, with its link, and stop."
        case .deploy:
            next = "Deploying is the human's step. Report what is ready to deploy and how, and stop."
        case .protectedPush:
            next = "Push your own branch and open a pull request instead."
        case .forcePush:
            next = "Push new commits instead; to catch up with main, merge it in rather than rebasing."
        case .push, .pr:
            next = "Report what you wanted to do and why, and stop."
        }
        return "Refused by the Kanban Code role gate: \(match.action.label) (`\(match.detail)`) is not allowed for the \(role) role here. \(next) Do not look for another way to do it."
    }

    static func askReason(_ match: GateMatch, role: String) -> String {
        "Held by the Kanban Code role gate: \(match.action.label) (`\(match.detail)`) needs the human's approval for the \(role) role, and Kanban Code has asked them on this card. Stop here and wait. You will get a message: if they approve, run the same command again, unchanged; if they reject, do not run it."
    }
}
