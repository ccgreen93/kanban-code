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
        ---
        Review it.
        """
        let role = try #require(RoleLibrary.parse(markdown: text))
        #expect(role.name == "review")
        #expect(role.model == "sonnet")
        #expect(role.effort == "low")
        #expect(role.skill == nil)
        #expect(role.singleton)
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
        #expect(names == ["triage", "adhoc", "spec", "build-lite", "build", "review", "merge", "pr-review", "pr-watch"])
        #expect(library.roles.map(\.name) == ["triage", "spec", "build-lite", "build", "adhoc", "review", "merge", "pr-review", "pr-watch"])
        for (from, edges) in library.transitions.edges {
            #expect(names.contains(from), "unknown role \(from) in transitions.json")
            for edge in edges {
                #expect(names.contains(edge.role), "\(from) leads to unknown role \(edge.role)")
            }
        }
        for role in library.roles {
            #expect(role.column != nil, "\(role.name) has no column")
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

    @Test("role survives encode and decode on a card")
    func linkRoundTrip() throws {
        var link = Link(name: "Card", source: .manual)
        link.role = "build"
        let decoded = try JSONDecoder().decode(Link.self, from: JSONEncoder().encode(link))
        #expect(decoded.role == "build")

        let plain = try JSONDecoder().decode(Link.self, from: JSONEncoder().encode(Link(name: "Plain", source: .manual)))
        #expect(plain.role == nil)
    }

    @Test("a role puts its instructions ahead of the task")
    func wrapsPrompt() {
        let role = Role(name: "build", description: "Implement it.", body: "Commit each step.")
        let link = Link(name: "Card", source: .manual, promptBody: "Add dark mode")
        let prompt = PromptBuilder.buildPrompt(card: link, role: role)
        #expect(prompt == "# Role: build\n\nImplement it.\n\nCommit each step.\n\n# Task\n\nAdd dark mode")
    }

    @Test("the project template wraps the task inside the role")
    func templateInsideRole() {
        let role = Role(name: "spec", body: "Write a spec.")
        let link = Link(name: "Card", source: .manual, promptBody: "Login page")
        var settings = Settings()
        settings.promptTemplate = "Task: ${prompt}"
        let prompt = PromptBuilder.buildPrompt(card: link, settings: settings, role: role)
        #expect(prompt == "# Role: spec\n\nWrite a spec.\n\n# Task\n\nTask: Login page")
    }

    @Test("no role leaves the prompt unchanged, and wrapping twice is a no-op")
    func noRoleAndIdempotent() {
        let link = Link(name: "Card", source: .manual, promptBody: "Fix bug")
        #expect(PromptBuilder.buildPrompt(card: link) == "Fix bug")

        let role = Role(name: "build", body: "Go.")
        let once = PromptBuilder.wrap("Fix bug", in: role)
        #expect(PromptBuilder.wrap(once, in: role) == once)
    }

    @Test("peer sync shares the role field")
    func linkSyncSharesRole() {
        #expect(LinkSync.sharedFields.contains { $0.name == "role" })
    }
}
