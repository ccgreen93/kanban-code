import Foundation

/// A discovered session no card holds, as the Import Session sheet lists it.
public struct SessionImportCandidate: Identifiable, Sendable, Equatable {
    public let session: Session
    public var id: String { session.id }
    /// Summary, custom name or first prompt (`Session.displayTitle`).
    public let title: String
    /// The folder the session ran in.
    public let projectPath: String?
    /// The configured project holding `projectPath`, the deepest one winning.
    public let project: Project?
    /// The Claude config folder whose `projects/` holds the transcript.
    public let configDirectory: String?
    /// The account of `configDirectory`, nil for `~/.claude` or the default.
    public let accountName: String?
    public let activity: ActivityState?

    public var lastActivity: Date { session.modifiedTime }

    /// What the project column shows: the configured project's name, else
    /// the folder's own name.
    public var projectName: String? {
        project?.name ?? projectPath.map { ($0 as NSString).lastPathComponent }
    }

    /// Hooks confirm a turn running right now.
    public var isRunning: Bool { activity == .activelyWorking }

    /// Its process may still be open somewhere: resuming it would start a
    /// second Claude on the same conversation.
    public var mayBeOpen: Bool { ExternalSessionPresence.of(activity: activity) != nil }
}

/// Bringing a session started outside Kanban (a terminal, VS Code) onto the
/// board. The card is created like any manual task and then linked with
/// `Action.relinkSession`, the same path `kanban relink` takes.
public enum SessionImport {
    /// Sessions in `state` that no card holds, newest first. Headless runs
    /// (`claude -p`, SDK scripts) and sessions without a transcript path are
    /// left out: neither is a conversation one resumes.
    public static func candidates(
        in state: AppState,
        layout: ClaudeConfigLayout = ClaudeConfigDirectories.current
    ) -> [SessionImportCandidate] {
        candidates(
            sessions: Array(state.sessions.values),
            links: Array(state.links.values),
            activityMap: state.activityMap,
            projects: state.configuredProjects,
            layout: layout
        )
    }

    public static func candidates(
        sessions: [Session],
        links: [Link],
        activityMap: [String: ActivityState],
        projects: [Project],
        layout: ClaudeConfigLayout
    ) -> [SessionImportCandidate] {
        let held = Set(links.lazy.filter { !$0.isTombstone }.compactMap { $0.sessionLink?.sessionId })
        let accountsByDirectory = Dictionary(
            layout.accounts.map { ($0.configDirectory, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        return sessions
            .filter { !held.contains($0.id) && !$0.isHeadless && $0.jsonlPath != nil }
            .sorted { lhs, rhs in
                lhs.modifiedTime != rhs.modifiedTime ? lhs.modifiedTime > rhs.modifiedTime : lhs.id < rhs.id
            }
            .map { session in
                let directory = session.jsonlPath.flatMap { layout.directory(containingSession: $0) }
                return SessionImportCandidate(
                    session: session,
                    title: session.displayTitle,
                    projectPath: session.projectPath,
                    project: session.projectPath.flatMap { project(holding: $0, in: projects) },
                    configDirectory: directory,
                    accountName: directory.flatMap { accountsByDirectory[$0] },
                    activity: activityMap[session.id]
                )
            }
    }

    /// The configured project at or above `path`, the deepest one winning.
    /// A worktree under `<repo>/.claude/worktrees/` belongs to the repo's.
    public static func project(holding path: String, in projects: [Project]) -> Project? {
        var normalized = ProjectDiscovery.normalizePath(path)
        if let range = normalized.range(of: "/.claude/worktrees/") {
            normalized = String(normalized[..<range.lowerBound])
        }
        return projects
            .map { ($0, ProjectDiscovery.normalizePath($0.path)) }
            .filter { normalized == $0.1 || normalized.hasPrefix($0.1 + "/") }
            .max { $0.1.count < $1.1.count }?
            .0
    }

    /// What the project filter of the sheet offers.
    public enum ProjectFilter: Hashable, Sendable {
        case all
        /// Sessions of one configured project.
        case project(path: String)
        /// Sessions in no configured project.
        case unconfigured
    }

    /// The configured projects that have candidates, in the order of
    /// `projects`.
    public static func projectsWithCandidates(_ candidates: [SessionImportCandidate], projects: [Project]) -> [Project] {
        let paths = Set(candidates.compactMap { $0.project?.path })
        return projects.filter { paths.contains($0.path) }
    }

    /// `candidates` narrowed to `filter` and `query`. Every word of the query
    /// must appear (case and accents ignored) in the title, first prompt,
    /// folder, project, account or session id.
    public static func filter(
        _ candidates: [SessionImportCandidate],
        project filter: ProjectFilter = .all,
        query: String = ""
    ) -> [SessionImportCandidate] {
        let words = query
            .split(whereSeparator: \.isWhitespace)
            .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        return candidates.filter { candidate in
            switch filter {
            case .all: break
            case .project(let path): guard candidate.project?.path == path else { return false }
            case .unconfigured: guard candidate.project == nil else { return false }
            }
            guard !words.isEmpty else { return true }
            let haystack = [
                candidate.title,
                candidate.session.firstPrompt ?? "",
                candidate.session.name ?? "",
                candidate.projectPath ?? "",
                candidate.projectName ?? "",
                candidate.accountName ?? "",
                candidate.configDirectory ?? "",
                candidate.session.id,
            ]
            .joined(separator: "\n")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// The card a session gets, without its session (`relinkSession` adds
    /// that), in the column the session's activity implies. A session too old
    /// for any active column goes to the backlog and stays there until it is
    /// resumed, the way a card brought back from the archive does: in All
    /// Sessions it would leave the board the moment it arrived.
    public static func card(for session: Session, activity: ActivityState?) -> Link {
        var link = Link(
            projectPath: session.projectPath,
            column: .backlog,
            lastActivity: session.modifiedTime,
            source: .manual
        )
        link.assistant = session.assistant == .claude ? nil : session.assistant
        // Taken onto the board on purpose: never hidden as a headless run.
        link.headless = false

        var linked = link
        linked.sessionLink = sessionLink(for: session)
        let column = AssignColumn.assign(link: linked, activityState: activity)
        if column == .allSessions {
            link.column = .backlog
            link.manualOverrides.column = true
        } else {
            link.column = column
        }
        return link
    }

    public static func sessionLink(for session: Session) -> SessionLink {
        SessionLink(sessionId: session.id, sessionPath: session.jsonlPath)
    }

    /// What importing `session` dispatches: create the card, then link it.
    public static func actions(for session: Session, activity: ActivityState?) -> (cardId: String, actions: [Action]) {
        let link = card(for: session, activity: activity)
        return (link.id, [
            .createManualTask(link),
            .relinkSession(cardId: link.id, sessionLink: sessionLink(for: session)),
            .selectCard(cardId: link.id),
        ])
    }
}

@MainActor
extension BoardStore {
    /// Puts the discovered session `sessionId` on the board. Returns the new
    /// card, or the card that already holds it; nil when no session by that
    /// id was discovered.
    @discardableResult
    public func importSession(_ sessionId: String) -> String? {
        if let holder = state.links.values.first(where: { !$0.isTombstone && $0.sessionLink?.sessionId == sessionId }) {
            dispatch(.selectCard(cardId: holder.id))
            return holder.id
        }
        guard let session = state.sessions[sessionId] else { return nil }
        let (cardId, actions) = SessionImport.actions(for: session, activity: state.activityMap[sessionId])
        for action in actions { dispatch(action) }
        KanbanCodeLog.info(
            "session-import",
            "Imported session \(sessionId.prefix(8)) as card \(cardId.prefix(12)) in \(state.links[cardId]?.column.rawValue ?? "?")"
        )
        return cardId
    }
}
