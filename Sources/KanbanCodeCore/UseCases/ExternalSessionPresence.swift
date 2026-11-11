import Foundation

/// A card's Claude session that runs outside Kanban: in a terminal or an
/// editor that opened it, not in a terminal of the card. Read from the same
/// activity detection that moves cards between columns.
///
/// Resuming such a card starts a second Claude on the same conversation,
/// and both then append to one transcript.
public enum ExternalSessionPresence: Sendable, Equatable {
    /// Hooks confirm a turn running right now.
    case working
    /// The session reads as open (at its prompt, or waiting on the user)
    /// but not working. Activity alone cannot tell an open session from
    /// one that was closed without its end hook, hence "may".
    case mayBeOpen

    /// What `activity` says about a session no Kanban terminal runs.
    public static func of(activity: ActivityState?) -> ExternalSessionPresence? {
        switch activity {
        case .activelyWorking: .working
        case .idleWaiting, .needsAttention, .blocked: .mayBeOpen
        case .ended, .stale, nil: nil
        }
    }

    /// The presence of `link`'s session outside Kanban, nil when a terminal
    /// of the card runs its assistant, a start is in flight, another
    /// machine runs it, or the session reads as ended.
    public static func of(link: Link, activity: ActivityState?, isForeign: Bool = false) -> ExternalSessionPresence? {
        guard link.sessionLink != nil,
              link.isLaunching != true,
              !link.isRemote,
              !isForeign else { return nil }
        if let tmux = link.tmuxLink, tmux.isShellOnly != true, tmux.isPrimaryDead != true {
            return nil
        }
        return of(activity: activity)
    }

    /// One line for the card badge.
    public var badgeLabel: String {
        switch self {
        case .working: "Running elsewhere"
        case .mayBeOpen: "Open elsewhere?"
        }
    }

    /// The warning the Resume dialog shows.
    public var resumeWarning: String {
        switch self {
        case .working:
            "This session is running outside Kanban right now (a terminal or VS Code). "
                + "Resuming starts a second Claude on the same conversation, and both write to one transcript. "
                + "Close the other one first."
        case .mayBeOpen:
            "This session may still be open outside Kanban (a terminal or VS Code). "
                + "If it is, resuming starts a second Claude on the same conversation. "
                + "Close the other one first."
        }
    }
}

extension KanbanCodeCard {
    /// Whether the card's session runs outside Kanban.
    public var externalSessionPresence: ExternalSessionPresence? {
        ExternalSessionPresence.of(link: link, activity: activityState, isForeign: owner != nil)
    }
}
