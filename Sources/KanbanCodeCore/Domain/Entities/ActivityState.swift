import Foundation

/// Represents the current activity state of a coding assistant session.
public enum ActivityState: String, Codable, Sendable {
    /// Session is actively executing tools or generating output.
    case activelyWorking = "actively_working"
    /// Session is stopped mid-turn on a permission prompt or a question it
    /// asked: it cannot go on until the user answers.
    case blocked
    /// Session stopped and is waiting for user input (plan approval, permission, done).
    case needsAttention = "needs_attention"
    /// Session has a running process but no recent activity.
    case idleWaiting = "idle_waiting"
    /// Session process has ended.
    case ended
    /// Session is old with no process, worktree, or tmux session.
    case stale

    /// Priority for composite activity detection: higher = more informative.
    /// Used by CompositeActivityDetector to pick the best state when multiple
    /// detectors report on the same session.
    var priority: Int {
        switch self {
        case .activelyWorking: 6
        case .blocked: 5
        case .needsAttention: 4
        case .idleWaiting: 3
        case .ended: 2
        case .stale: 1
        }
    }

    /// Whether the session sits on the user: a finished turn, or a prompt
    /// it is blocked on.
    public var awaitsUser: Bool {
        self == .needsAttention || self == .blocked
    }
}
