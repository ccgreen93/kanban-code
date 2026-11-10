import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Session import")
struct SessionImportTests {
    let home = "/home/u"

    var layout: ClaudeConfigLayout {
        ClaudeConfigLayout(home: home, accounts: [
            ClaudeAccount(name: "Personal", configDirectory: "~/.claude-cg", projectPaths: ["~/dev/cg"]),
            ClaudeAccount(name: "Value3", configDirectory: "~/.claude-value3", projectPaths: ["~/dev/value3"]),
        ])
    }

    let projects = [
        Project(path: "/home/u/dev/cg", name: "cg"),
        Project(path: "/home/u/dev/cg/kanban-code", name: "Kanban"),
        Project(path: "/home/u/dev/value3/app", name: "V3 app"),
    ]

    func session(
        _ id: String, project: String, config: String = ".claude", minutesAgo: Double = 1,
        prompt: String? = nil, entrypoint: String? = "cli", path: Bool = true
    ) -> Session {
        Session(
            id: id,
            firstPrompt: prompt ?? "prompt of \(id)",
            projectPath: project,
            modifiedTime: Date.now.addingTimeInterval(-minutesAgo * 60),
            jsonlPath: path ? "\(home)/\(config)/projects/-x/\(id).jsonl" : nil,
            entrypoint: entrypoint
        )
    }

    // MARK: - Listing

    @Test("Lists sessions no card holds, newest first, with project and account")
    func listsUnheldSessionsNewestFirst() {
        let sessions = [
            session("old", project: "/home/u/dev/cg/kanban-code", config: ".claude-cg", minutesAgo: 90),
            session("new", project: "/home/u/dev/value3/app/src", config: ".claude-value3", minutesAgo: 2),
            session("held", project: "/home/u/dev/cg", config: ".claude-cg", minutesAgo: 1),
            session("plain", project: "/tmp/scratch", minutesAgo: 30),
        ]
        let links = [Link(source: .manual, sessionLink: SessionLink(sessionId: "held"))]
        let list = SessionImport.candidates(
            sessions: sessions, links: links, activityMap: ["new": .activelyWorking],
            projects: projects, layout: layout)

        #expect(list.map(\.id) == ["new", "plain", "old"])
        #expect(list[0].project?.name == "V3 app")
        #expect(list[0].accountName == "Value3")
        #expect(list[0].configDirectory == "/home/u/.claude-value3")
        #expect(list[0].isRunning)
        // The deepest configured project wins.
        #expect(list[2].project?.name == "Kanban")
        #expect(list[2].accountName == "Personal")
        // No configured project: the folder's own name, the default account.
        #expect(list[1].project == nil)
        #expect(list[1].projectName == "scratch")
        #expect(list[1].configDirectory == "/home/u/.claude")
        #expect(list[1].accountName == nil)
        #expect(!list[1].isRunning)
    }

    @Test("Headless runs, sessions without a transcript and archived cards' sessions are not offered")
    func skipsHeadlessPathlessAndHeld() {
        var archived = Link(source: .manual, sessionLink: SessionLink(sessionId: "archived"))
        archived.manuallyArchived = true
        var tombstone = Link(source: .manual, sessionLink: SessionLink(sessionId: "deleted"))
        tombstone.deletedAt = .now
        let list = SessionImport.candidates(
            sessions: [
                session("script", project: "/home/u/dev/cg", entrypoint: Session.headlessEntrypoint),
                session("nopath", project: "/home/u/dev/cg", path: false),
                session("archived", project: "/home/u/dev/cg"),
                session("deleted", project: "/home/u/dev/cg"),
            ],
            links: [archived, tombstone], activityMap: [:], projects: projects, layout: layout)
        // An archived card still holds its session; a tombstone does not.
        #expect(list.map(\.id) == ["deleted"])
    }

    @Test("A worktree session belongs to its repo's project")
    func worktreeBelongsToRepoProject() {
        let project = SessionImport.project(
            holding: "/home/u/dev/cg/kanban-code/.claude/worktrees/feat-x", in: projects)
        #expect(project?.name == "Kanban")
        #expect(SessionImport.project(holding: "/home/u/dev/cgx", in: projects) == nil)
    }

    // MARK: - Filtering

    @Test("Filters by project and by every word of the search, ignoring case")
    func filtersByProjectAndSearch() {
        let list = SessionImport.candidates(
            sessions: [
                session("a1", project: "/home/u/dev/cg/kanban-code", config: ".claude-cg", prompt: "Fix the Toolbar layout"),
                session("a2", project: "/home/u/dev/cg/kanban-code", config: ".claude-cg", prompt: "Add import sheet"),
                session("b1", project: "/home/u/dev/value3/app", config: ".claude-value3", prompt: "Toolbar for invoices"),
                session("c1", project: "/tmp/elsewhere", prompt: "toolbar idea"),
            ],
            links: [], activityMap: [:], projects: projects, layout: layout)

        let kanban = SessionImport.filter(list, project: .project(path: "/home/u/dev/cg/kanban-code"))
        #expect(Set(kanban.map(\.id)) == ["a1", "a2"])
        #expect(SessionImport.filter(list, project: .unconfigured).map(\.id) == ["c1"])
        #expect(Set(SessionImport.filter(list, query: "TOOLBAR").map(\.id)) == ["a1", "b1", "c1"])
        #expect(SessionImport.filter(list, query: "toolbar value3").map(\.id) == ["b1"])
        #expect(SessionImport.filter(list, project: .project(path: "/home/u/dev/cg/kanban-code"), query: "toolbar")
            .map(\.id) == ["a1"])
        #expect(SessionImport.filter(list, query: "a2").map(\.id) == ["a2"])
        #expect(SessionImport.filter(list, query: "   ").count == 4)

        let offered = SessionImport.projectsWithCandidates(list, projects: projects)
        #expect(offered.map(\.name) == ["Kanban", "V3 app"])
    }

    // MARK: - Importing

    @Test("The card lands in the column its activity implies")
    func columnFollowsActivity() {
        let s = session("s1", project: "/home/u/dev/cg")
        #expect(SessionImport.card(for: s, activity: .activelyWorking).column == .inProgress)
        #expect(SessionImport.card(for: s, activity: .needsAttention).column == .waiting)
        #expect(SessionImport.card(for: s, activity: .idleWaiting).column == .waiting)
        // Ended today: recent enough to wait for the user.
        #expect(SessionImport.card(for: s, activity: .ended).column == .waiting)
        let auto = SessionImport.card(for: s, activity: .activelyWorking)
        #expect(!auto.manualOverrides.column)
    }

    @Test("An old session is parked in the backlog, not dropped into All Sessions")
    func oldSessionParksInBacklog() {
        let s = session("s1", project: "/home/u/dev/cg", minutesAgo: 60 * 24 * 5)
        let link = SessionImport.card(for: s, activity: nil)
        #expect(link.column == .backlog)
        #expect(link.manualOverrides.column)
        // A turn running in a Kanban terminal later still moves it.
        var linked = link
        linked.sessionLink = SessionImport.sessionLink(for: s)
        #expect(AssignColumn.assign(link: linked, activityState: .activelyWorking, hasLiveSession: true) == .inProgress)
    }

    @Test("Importing creates a claimed card and links it through relinkSession")
    func importDispatchesCreateThenRelink() {
        var codex = session("s1", project: "/home/u/dev/cg", config: ".claude-cg", minutesAgo: 3)
        codex.assistant = .codex
        let (cardId, actions) = SessionImport.actions(for: codex, activity: .needsAttention)
        guard actions.count == 3,
              case .createManualTask(let created) = actions[0],
              case .relinkSession(let relinkId, let sessionLink) = actions[1],
              case .selectCard(let selected) = actions[2] else {
            Issue.record("unexpected actions \(actions)")
            return
        }
        #expect(created.id == cardId && relinkId == cardId && selected == cardId)
        #expect(created.sessionLink == nil)
        #expect(sessionLink.sessionId == "s1")
        #expect(sessionLink.sessionPath == codex.jsonlPath)

        var state = AppState()
        state.sessions = ["s1": codex]
        state.activityMap = ["s1": .needsAttention]
        for action in actions { _ = Reducer.reduce(state: &state, action: action) }

        let link = try! #require(state.links[cardId])
        #expect(link.sessionLink?.sessionId == "s1")
        #expect(link.projectPath == "/home/u/dev/cg")
        #expect(link.column == .waiting)
        #expect(link.effectiveAssistant == .codex)
        #expect(link.headless == false)
        #expect(link.isClaimed && !link.isDiscoveryOnly)
        #expect(state.selectedCardId == cardId)

        // The sweep of discovery-only cards leaves it alone.
        _ = Reducer.reduce(state: &state, action: .archiveDiscoveryOnlyCards)
        #expect(state.links[cardId]?.manuallyArchived == false)

        // Now held: no longer offered.
        #expect(SessionImport.candidates(in: state, layout: layout).isEmpty)
    }

    @Test("The reconciler keeps the imported card on its session")
    func reconcilerKeepsImportedSession() {
        let s = session("s1", project: "/home/u/dev/cg", minutesAgo: 3)
        let (cardId, actions) = SessionImport.actions(for: s, activity: .needsAttention)
        var state = AppState()
        for action in actions { _ = Reducer.reduce(state: &state, action: action) }
        let other = session("s2", project: "/home/u/dev/cg", minutesAgo: 1)

        let reconciled = CardReconciler.reconcile(
            existing: Array(state.links.values),
            snapshot: .init(sessions: [s, other]))
        let card = reconciled.first { $0.id == cardId }
        #expect(card?.sessionLink?.sessionId == "s1")
        let holdersOfOther = reconciled.filter { $0.sessionLink?.sessionId == "s2" }
        #expect(holdersOfOther.isEmpty)
    }
}

@Suite("External session presence")
struct ExternalSessionPresenceTests {
    let linked = Link(source: .manual, sessionLink: SessionLink(sessionId: "s1"))

    @Test("A card without a Kanban terminal reports its session's activity")
    func noTerminalReportsActivity() {
        #expect(ExternalSessionPresence.of(link: linked, activity: .activelyWorking) == .working)
        #expect(ExternalSessionPresence.of(link: linked, activity: .idleWaiting) == .mayBeOpen)
        #expect(ExternalSessionPresence.of(link: linked, activity: .needsAttention) == .mayBeOpen)
        #expect(ExternalSessionPresence.of(link: linked, activity: .ended) == nil)
        #expect(ExternalSessionPresence.of(link: linked, activity: .stale) == nil)
        #expect(ExternalSessionPresence.of(link: linked, activity: nil) == nil)
    }

    @Test("A card whose own terminal runs the assistant is not running elsewhere")
    func ownTerminalIsNotElsewhere() {
        var running = linked
        running.tmuxLink = TmuxLink(sessionName: "claude-s1")
        #expect(ExternalSessionPresence.of(link: running, activity: .activelyWorking) == nil)

        // A shell tab or a dead primary does not run Claude.
        var shell = linked
        shell.tmuxLink = TmuxLink(sessionName: "card-sh", isShellOnly: true)
        #expect(ExternalSessionPresence.of(link: shell, activity: .activelyWorking) == .working)
        var dead = running
        dead.tmuxLink?.isPrimaryDead = true
        #expect(ExternalSessionPresence.of(link: dead, activity: .idleWaiting) == .mayBeOpen)
    }

    @Test("Launching, remote, foreign or session-less cards report nothing")
    func excludedCards() {
        var launching = linked
        launching.isLaunching = true
        #expect(ExternalSessionPresence.of(link: launching, activity: .activelyWorking) == nil)
        var remote = linked
        remote.isRemote = true
        #expect(ExternalSessionPresence.of(link: remote, activity: .activelyWorking) == nil)
        #expect(ExternalSessionPresence.of(link: linked, activity: .activelyWorking, isForeign: true) == nil)
        #expect(ExternalSessionPresence.of(link: Link(source: .manual), activity: .activelyWorking) == nil)
    }

    @Test("The card exposes it")
    func cardExposesPresence() {
        #expect(KanbanCodeCard(link: linked, activityState: .activelyWorking).externalSessionPresence == .working)
        let foreign = KanbanCodeCard(
            link: linked, activityState: .activelyWorking,
            owner: CardOwner(id: "m2", name: "Other", online: true))
        #expect(foreign.externalSessionPresence == nil)
    }
}
