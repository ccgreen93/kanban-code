import Foundation

/// The roles and the pipeline between them, loaded from a folder
/// (`~/.kanban-code/roles/` by default):
///
/// - `<name>.md`: frontmatter (`name`, `description`, `model`, `effort`,
///   `assistant`, `skill`, `column`, `singleton`) then the instructions.
///   Markdown files without frontmatter or without `name` are skipped, so
///   notes can live in the same folder.
/// - `transitions.json`: `{ "build": [{"role": "review", "mode": "auto"}, "triage"] }`.
public struct RoleLibrary: Sendable, Equatable {
    /// Roles sorted by the order they appear in the pipeline, then by name.
    public var roles: [Role]
    public var transitions: RoleTransitions

    public init(roles: [Role] = [], transitions: RoleTransitions = RoleTransitions()) {
        self.roles = roles
        self.transitions = transitions
    }

    public var isEmpty: Bool { roles.isEmpty }

    public func role(named name: String?) -> Role? {
        guard let name, !name.isEmpty else { return nil }
        return roles.first { $0.name == name }
    }

    public static var defaultDirectory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/roles")
    }

    /// Loads the library from `directory`. A missing folder or unreadable
    /// file yields an empty part rather than an error: roles are optional.
    public static func load(directory: String = defaultDirectory) -> RoleLibrary {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
        var roles: [Role] = []
        var seen: Set<String> = []
        for file in names.sorted() where file.hasSuffix(".md") {
            let path = (directory as NSString).appendingPathComponent(file)
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let role = parse(markdown: text),
                  seen.insert(role.name).inserted else { continue }
            roles.append(role)
        }

        var transitions = RoleTransitions()
        let transitionsPath = (directory as NSString).appendingPathComponent("transitions.json")
        if let data = fm.contents(atPath: transitionsPath) {
            if let decoded = try? JSONDecoder().decode(RoleTransitions.self, from: data) {
                transitions = decoded
            } else {
                KanbanCodeLog.warn("roles", "Ignoring unreadable \(transitionsPath)")
            }
        }

        return RoleLibrary(roles: pipelineOrder(roles, transitions: transitions), transitions: transitions)
    }

    // MARK: - Parsing

    /// Parses one role file. Nil when it has no frontmatter or no `name`.
    public static func parse(markdown: String) -> Role? {
        guard let (fields, body) = splitFrontmatter(markdown),
              let name = fields["name"], !name.isEmpty else { return nil }
        return Role(
            name: name,
            description: fields["description"],
            model: fields["model"],
            effort: fields["effort"] ?? fields["model_effort"],
            assistant: fields["assistant"].flatMap { CodingAssistant(rawValue: $0.lowercased()) },
            skill: fields["skill"],
            column: fields["column"].flatMap(parseColumn),
            singleton: ["true", "yes", "1"].contains(fields["singleton"]?.lowercased() ?? ""),
            body: body
        )
    }

    /// `---\nkey: value\n---\nbody`. Values may be quoted; blank values and
    /// `#` comment lines are dropped. Only flat `key: value` lines are read.
    static func splitFrontmatter(_ text: String) -> ([String: String], String)? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        lines.removeFirst()
        guard let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }

        var fields: [String: String] = [:]
        for line in lines[..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty, !value.isEmpty { fields[key] = value }
        }
        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (fields, body)
    }

    /// Accepts raw values (`in_progress`) and friendly ones (`In Progress`,
    /// `in-progress`, `review`).
    static func parseColumn(_ value: String) -> KanbanCodeColumn? {
        let key = value.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        if let column = KanbanCodeColumn(rawValue: key) { return column }
        switch key {
        case "waiting": return .waiting
        case "review": return .inReview
        default:
            return KanbanCodeColumn.allCases.first {
                $0.displayName.lowercased().replacingOccurrences(of: " ", with: "_") == key
            }
        }
    }

    /// Roles in pipeline order. One breadth-first walk per starting role:
    /// first the Backlog roles (where cards start, even when a later role
    /// can loop back to them), then roles nothing leads to (side roles).
    /// Roles the walks never reach follow, by name.
    static func pipelineOrder(_ roles: [Role], transitions: RoleTransitions) -> [Role] {
        let targets = Set(transitions.edges.values.flatMap { $0.map(\.role) })
        let backlogStarts = roles.filter { $0.column == .backlog }.map(\.name).sorted()
        let roots = transitions.edges.keys.filter { !targets.contains($0) }.sorted()
        var order: [String] = []
        var visited: Set<String> = []
        for start in backlogStarts + roots {
            var queue = [start]
            while !queue.isEmpty {
                let name = queue.removeFirst()
                guard visited.insert(name).inserted else { continue }
                order.append(name)
                queue.append(contentsOf: transitions.next(after: name).map(\.role))
            }
        }
        for name in transitions.edges.keys.sorted() where !visited.contains(name) {
            order.append(name)
        }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return roles.sorted { a, b in
            switch (rank[a.name], rank[b.name]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.name < b.name
            }
        }
    }
}
