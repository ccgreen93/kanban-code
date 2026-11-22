import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Role Library")
struct RoleLibraryTests {

    private let buildRole = """
    ---
    name: build
    description: Implement the change and draft the PR.
    model: opus
    effort: high
    assistant: claude
    skill: bmad-build
    column: In Progress
    singleton: false
    ---

    # Build

    Implement in small commits.
    """

    @Test("parses frontmatter fields and body")
    func parsesRole() throws {
        let role = try #require(RoleLibrary.parse(markdown: buildRole))
        #expect(role.name == "build")
        #expect(role.description == "Implement the change and draft the PR.")
        #expect(role.model == "opus")
        #expect(role.effort == "high")
        #expect(role.assistant == .claude)
        #expect(role.skill == "bmad-build")
        #expect(role.column == .inProgress)
        #expect(role.singleton == false)
        #expect(role.body == "# Build\n\nImplement in small commits.")
    }

    @Test("strips quotes, skips comments and blank values, accepts model_effort")
    func quotesAndComments() throws {
        let text = """
        ---
        # a comment
        name: "review"
        model: 'sonnet'
        model_effort: low
        skill:
        singleton: yes
        controls: true
        ---
        Review it.
        """
        let role = try #require(RoleLibrary.parse(markdown: text))
        #expect(role.name == "review")
        #expect(role.model == "sonnet")
        #expect(role.effort == "low")
        #expect(role.skill == nil)
        #expect(role.singleton)
        #expect(role.controls)
        #expect(role.body == "Review it.")
    }

    @Test("files without frontmatter or name are not roles")
    func rejectsNonRoles() {
        #expect(RoleLibrary.parse(markdown: "# Notes\n\nJust notes.") == nil)
        #expect(RoleLibrary.parse(markdown: "---\nmodel: opus\n---\nbody") == nil)
        #expect(RoleLibrary.parse(markdown: "---\nname: open\nno end marker") == nil)
    }

    @Test("column accepts raw and friendly names")
    func columns() {
        #expect(RoleLibrary.parseColumn("in_progress") == .inProgress)
        #expect(RoleLibrary.parseColumn("in-progress") == .inProgress)
        #expect(RoleLibrary.parseColumn("Backlog") == .backlog)
        #expect(RoleLibrary.parseColumn("review") == .inReview)
        #expect(RoleLibrary.parseColumn("In Review") == .inReview)
        #expect(RoleLibrary.parseColumn("waiting") == .waiting)
        #expect(RoleLibrary.parseColumn("done") == .done)
        #expect(RoleLibrary.parseColumn("nowhere") == nil)
    }

    @Test("transitions decode plain names as ask edges and objects with a mode")
    func transitions() throws {
        let json = #"{"triage": ["spec", "build"], "build": [{"role": "review", "mode": "auto"}, "triage"], "merge": []}"#
        let t = try JSONDecoder().decode(RoleTransitions.self, from: Data(json.utf8))
        #expect(t.next(after: "triage") == [RoleEdge(role: "spec"), RoleEdge(role: "build")])
        #expect(t.next(after: "build") == [RoleEdge(role: "review", mode: .auto), RoleEdge(role: "triage", mode: .ask)])
        #expect(t.isTerminal("merge"))
        #expect(t.isTerminal("unknown"))
        #expect(!t.isTerminal("build"))

        let roundTrip = try JSONDecoder().decode(RoleTransitions.self, from: JSONEncoder().encode(t))
        #expect(roundTrip == t)
    }

    @Test("loads a folder: skips notes, orders roles by the pipeline")
    func loadsDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roles-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        func write(_ name: String, _ text: String) throws {
            try text.write(toFile: (dir as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try write("a-review.md", "---\nname: review\n---\nReview.")
        try write("build.md", buildRole)
        try write("triage.md", "---\nname: triage\nmodel: sonnet\n---\nTriage.")
        try write("zz-adhoc.md", "---\nname: adhoc\n---\nAnything.")
        try write("notes.md", "# Private notes, no frontmatter")
        try write("dupe.md", "---\nname: build\n---\nSecond build is ignored.")
        try write("transitions.json", #"{"triage": ["build"], "build": [{"role": "review", "mode": "auto"}], "review": ["build"]}"#)

        let library = RoleLibrary.load(directory: dir)
        #expect(library.roles.map(\.name) == ["triage", "build", "review", "adhoc"])
        #expect(library.role(named: "build")?.model == "opus")
        #expect(library.role(named: "missing") == nil)
        #expect(library.role(named: nil) == nil)
        #expect(library.transitions.next(after: "build").first?.mode == .auto)
    }

    @Test("the example roles in docs/roles/examples all load and their arrows point at real roles")
    func shippedExamples() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = repo.appendingPathComponent("docs/roles/examples").path
        let library = RoleLibrary.load(directory: dir)
        let names = Set(library.roles.map(\.name))
        #expect(names == ["triage", "adhoc", "spec", "build-lite", "build", "review", "merge", "pr-review", "pr-watch", "control"])
        #expect(library.roles.map(\.name) == ["triage", "spec", "build-lite", "build", "adhoc", "review", "merge", "pr-review", "pr-watch", "control"])
        #expect(library.roles.filter(\.controls).map(\.name) == ["control"])
        for (from, edges) in library.transitions.edges {
            #expect(names.contains(from), "unknown role \(from) in transitions.json")
            for edge in edges {
                #expect(names.contains(edge.role), "\(from) leads to unknown role \(edge.role)")
            }
        }
        for role in library.roles {
            #expect(role.controls || role.column != nil, "\(role.name) has no column")
            #expect(!role.body.isEmpty, "\(role.name) has no instructions")
        }
    }

    @Test("a missing folder or bad transitions file gives an empty part")
    func missingFolder() throws {
        #expect(RoleLibrary.load(directory: "/nonexistent/\(UUID().uuidString)").isEmpty)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roles-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "---\nname: solo\n---\nSolo.".write(toFile: dir + "/solo.md", atomically: true, encoding: .utf8)
        try "not json".write(toFile: dir + "/transitions.json", atomically: true, encoding: .utf8)
        let library = RoleLibrary.load(directory: dir)
        #expect(library.roles.map(\.name) == ["solo"])
        #expect(library.transitions == RoleTransitions())
    }
}

@Suite("Role on cards and prompts")
struct RolePromptTests {

    private func library(_ roles: [Role], _ edges: [String: [RoleEdge]] = [:]) -> RoleLibrary {
        RoleLibrary(roles: roles, transitions: RoleTransitions(edges))
    }

    @Test("role and role history survive encode and decode on a card")
    func linkRoundTrip() throws {
        var link = Link(name: "Card", source: .manual)
        link.role = "build"
        link.roleHistory = [RoleStage(role: "spec", sessionId: "s1", sessionPath: "/s1.jsonl",
                                      summary: "Spec at docs/x.md", handedOffTo: "build",
                                      endedAt: Date(timeIntervalSince1970: 1_000))]
        let decoded = try JSONDecoder().decode(Link.self, from: JSONEncoder().encode(link))
        #expect(decoded.role == "build")
        #expect(decoded.roleHistory == link.roleHistory)
        #expect(decoded.pastRoleSessionIds == ["s1"])

        let plain = try JSONDecoder().decode(Link.self, from: JSONEncoder().encode(Link(name: "Plain", source: .manual)))
        #expect(plain.role == nil)
        #expect(plain.roleHistory == nil)
    }

    @Test("a role puts its instructions ahead of the task and the hand-off steps after it")
    func wrapsPrompt() {
        let role = Role(name: "build", description: "Implement it.", body: "Commit each step.")
        var link = Link(name: "Card", source: .manual, promptBody: "Add dark mode")
        link.role = "build"
        let roles = library([role], ["build": [RoleEdge(role: "review", mode: .auto), RoleEdge(role: "triage")]])
        let prompt = PromptBuilder.buildPrompt(card: link, roles: roles)
        #expect(prompt.hasPrefix("# Role: build\n\nImplement it.\n\nCommit each step.\n\n# Task\n\nAdd dark mode\n\n# When you are done"))
        #expect(prompt.contains("kanban role handoff <role> - <<'EOF'"))
        #expect(prompt.contains("- `review`: hand off when your stage is done"))
        #expect(prompt.contains("- `triage`: needs the human's yes"))
    }

    @Test("the last role is told to report and stop")
    func terminalRole() {
        let prompt = PromptBuilder.wrap("Check the PR", in: Role(name: "merge", body: "Check."))
        #expect(prompt.hasSuffix("# When you are done\n\nThis is the last role. Report what you did and stop."))
        #expect(!prompt.contains("kanban role handoff"))
    }

    @Test("a control role gets no hand-off footer")
    func controlRoleNoFooter() {
        let prompt = PromptBuilder.wrap("Run the board", in: Role(name: "control", controls: true, body: "Watch."))
        #expect(prompt == "# Role: control\n\nWatch.\n\n# Task\n\nRun the board")
    }

    @Test("earlier stages' summaries come after the task, oldest first")
    func earlierStages() {
        let history = [
            RoleStage(role: "spec", summary: "Spec written.", handedOffTo: "build", endedAt: Date(timeIntervalSince1970: 0)),
            RoleStage(role: "build", summary: nil, handedOffTo: "review", endedAt: Date(timeIntervalSince1970: 60)),
        ]
        let prompt = PromptBuilder.wrap("Task", in: Role(name: "review"), history: history)
        let task = prompt.range(of: "# Task")!.lowerBound
        let stages = prompt.range(of: "# Earlier stages on this card")!.lowerBound
        let spec = prompt.range(of: "## spec → build")!.lowerBound
        let build = prompt.range(of: "## build → review")!.lowerBound
        #expect(task < stages && stages < spec && spec < build)
        #expect(prompt.contains("Spec written."))
        #expect(prompt.contains("(no summary)"))
    }

    @Test("the project template wraps the task inside the role")
    func templateInsideRole() {
        var link = Link(name: "Card", source: .manual, promptBody: "Login page")
        link.role = "spec"
        var settings = Settings()
        settings.promptTemplate = "Task: ${prompt}"
        let prompt = PromptBuilder.buildPrompt(card: link, settings: settings, roles: library([Role(name: "spec", body: "Write a spec.")]))
        #expect(prompt.hasPrefix("# Role: spec\n\nWrite a spec.\n\n# Task\n\nTask: Login page\n\n"))
    }

    @Test("no role, or a role missing from the library, leaves the prompt unchanged")
    func noRole() {
        var link = Link(name: "Card", source: .manual, promptBody: "Fix bug")
        #expect(PromptBuilder.buildPrompt(card: link) == "Fix bug")
        link.role = "deleted"
        #expect(PromptBuilder.buildPrompt(card: link, roles: library([Role(name: "build")])) == "Fix bug")
    }

    @Test("wrapping a wrapped prompt, even another role's, never nests roles")
    func unwrapsBeforeWrapping() {
        let build = Role(name: "build", body: "Go.")
        let review = Role(name: "review", body: "Look.")
        let once = PromptBuilder.wrap("Fix bug", in: build, next: [RoleEdge(role: "review", mode: .auto)])
        #expect(PromptBuilder.wrap(once, in: build, next: [RoleEdge(role: "review", mode: .auto)]) == once)
        #expect(PromptBuilder.unwrapRoleTask(once) == "Fix bug")
        let rewrapped = PromptBuilder.wrap(once, in: review)
        #expect(rewrapped.components(separatedBy: "# Role: ").count == 2)
        #expect(rewrapped.hasPrefix("# Role: review"))
        #expect(PromptBuilder.unwrapRoleTask("Plain text") == "Plain text")
    }

    @Test("peer sync shares the role and its history")
    func linkSyncSharesRole() {
        #expect(LinkSync.sharedFields.contains { $0.name == "role" })
        #expect(LinkSync.sharedFields.contains { $0.name == "roleHistory" })
    }
}
