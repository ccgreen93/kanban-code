import Foundation

/// A kind of command a role card's agent may be stopped from running on its
/// own: see `RoleGateClassifier` for what matches each one.
public enum GateAction: String, Codable, Sendable, CaseIterable {
    /// A plain push of the card's own branch.
    case push
    /// A push to main, master or another protected branch, or of every branch.
    case protectedPush = "push-protected"
    /// A force-push, a deleted branch, or any other history rewrite of a remote.
    case forcePush = "force-push"
    /// Opening, editing or commenting on a pull request.
    case pr
    /// Approving a pull request.
    case approve
    /// Merging a pull request, auto-merge, or the merge queue.
    case merge
    /// Deploying, releasing or publishing: infrastructure changes, package
    /// publishes, releases, tag pushes, workflow runs, changes on a server.
    case deploy

    /// What the agent and the human read.
    public var label: String {
        switch self {
        case .push: "pushing"
        case .protectedPush: "pushing to a protected branch"
        case .forcePush: "force-pushing or deleting a pushed branch"
        case .pr: "writing to a pull request"
        case .approve: "approving a pull request"
        case .merge: "merging a pull request"
        case .deploy: "deploying, releasing or publishing"
        }
    }
}

/// What happens to a gated command.
public enum GateMode: String, Codable, Sendable, Comparable {
    /// It runs.
    case allow
    /// It is held until the human approves it on the card.
    case ask
    /// It is refused, and the agent is told to report and stop.
    case deny

    private var rank: Int {
        switch self {
        case .allow: 0
        case .ask: 1
        case .deny: 2
        }
    }

    public static func < (lhs: GateMode, rhs: GateMode) -> Bool { lhs.rank < rhs.rank }
}

/// One gated command found in what the agent asked to run.
public struct GateMatch: Sendable, Equatable {
    public let action: GateAction
    /// The command it was found in, e.g. `gh pr merge 12 --squash`.
    public let detail: String

    public init(action: GateAction, detail: String) {
        self.action = action
        self.detail = detail
    }
}

/// A command held for the human's approval, shown on the card.
public struct PendingGate: Codable, Sendable, Equatable {
    public var action: GateAction
    /// The whole command the agent asked to run.
    public var command: String
    public var role: String?
    public var requestedAt: Date

    public init(action: GateAction, command: String, role: String?, requestedAt: Date = .now) {
        self.action = action
        self.command = command
        self.role = role
        self.requestedAt = requestedAt
    }
}
