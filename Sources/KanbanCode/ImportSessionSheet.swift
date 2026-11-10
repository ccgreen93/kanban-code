import SwiftUI
import KanbanCodeCore

extension Notification.Name {
    static let kanbanCodeImportSession = Notification.Name("kanbanCodeImportSession")
}

/// Lists Claude sessions started outside Kanban (a terminal, VS Code) that
/// no card holds, and puts the picked one on the board. The listing and the
/// import are `SessionImport`'s; this only draws them.
struct ImportSessionSheet: View {
    let store: BoardStore
    @Binding var isPresented: Bool
    /// Called with the new card once the session is on the board.
    var onImported: (String) -> Void = { _ in }

    @State private var query = ""
    @State private var filter: SessionImport.ProjectFilter = .all
    @State private var selection: String?
    @FocusState private var searchFocused: Bool

    /// Rows drawn at most; the search reaches the rest.
    private static let rowLimit = 300

    var body: some View {
        let all = SessionImport.candidates(in: store.state)
        let shown = SessionImport.filter(all, project: filter, query: query)
        let projects = SessionImport.projectsWithCandidates(all, projects: store.state.configuredProjects)
        let hasUnconfigured = all.contains { $0.project == nil }
        let selected = shown.first { $0.id == selection }

        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import Session")
                    .font(.app(.title3))
                    .fontWeight(.semibold)
                Text("Claude sessions started outside Kanban that no card holds yet.")
                    .font(.app(.callout))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                TextField("Search prompts, folders, accounts", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                Picker("Project", selection: $filter) {
                    Text("All projects").tag(SessionImport.ProjectFilter.all)
                    if !projects.isEmpty || hasUnconfigured { Divider() }
                    ForEach(projects) { project in
                        Text(project.name).tag(SessionImport.ProjectFilter.project(path: project.path))
                    }
                    if hasUnconfigured {
                        Text("Other folders").tag(SessionImport.ProjectFilter.unconfigured)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            if shown.isEmpty {
                ContentUnavailableView(
                    all.isEmpty ? "No sessions to import" : "No matching sessions",
                    systemImage: "tray",
                    description: Text(all.isEmpty
                        ? "Every discovered session already has a card."
                        : "Try another search or project.")
                )
                .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                List(selection: $selection) {
                    ForEach(shown.prefix(Self.rowLimit)) { candidate in
                        ImportSessionRow(candidate: candidate)
                            .tag(candidate.id)
                            .contextMenu {
                                Button("Import") { importSession(candidate.id) }
                            }
                    }
                    if shown.count > Self.rowLimit {
                        Text("\(shown.count - Self.rowLimit) older sessions not shown. Search to find them.")
                            .font(.app(.caption))
                            .foregroundStyle(.tertiary)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 320)
                .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                    if let id = ids.first { importSession(id) }
                }
            }

            if let selected, let presence = ExternalSessionPresence.of(activity: selected.activity) {
                Label(
                    presence == .working
                        ? "Running outside Kanban now. The card will say so, and Resume will warn first."
                        : "May still be open outside Kanban. Resume will warn first.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.app(.caption))
                .foregroundStyle(.orange)
            }

            HStack {
                Text("\(shown.count) of \(all.count) sessions")
                    .font(.app(.caption))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    if let selected { importSession(selected.id) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
        .onAppear {
            searchFocused = true
            // Start on the project the board shows, when it has candidates.
            if let path = store.state.selectedProjectPath,
               projects.contains(where: { $0.path == path }) {
                filter = .project(path: path)
            }
        }
        .onChange(of: query) { selection = nil }
        .onChange(of: filter) { selection = nil }
    }

    private func importSession(_ sessionId: String) {
        guard let cardId = store.importSession(sessionId) else { return }
        isPresented = false
        onImported(cardId)
    }
}

private struct ImportSessionRow: View {
    let candidate: SessionImportCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(candidate.title)
                    .font(.app(.body, weight: .medium))
                    .lineLimit(2)
                Spacer(minLength: 8)
                if candidate.isRunning {
                    ExternalSessionBadge(presence: .working, label: "Running")
                } else if candidate.mayBeOpen {
                    ExternalSessionBadge(presence: .mayBeOpen, label: "Open?")
                }
            }
            HStack(spacing: 10) {
                if let project = candidate.projectName {
                    Label(project, systemImage: "folder")
                        .help(candidate.projectPath ?? project)
                }
                Label(accountLabel, systemImage: "person.crop.circle")
                    .help(candidate.configDirectory ?? "")
                if candidate.session.assistant != .claude {
                    Text(candidate.session.assistant.displayName)
                }
                Spacer()
                Text(candidate.lastActivity, format: .relative(presentation: .named))
            }
            .font(.app(.caption))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 3)
    }

    /// The account's name, else its folder with `~`.
    private var accountLabel: String {
        if let name = candidate.accountName { return name }
        guard let dir = candidate.configDirectory else { return "unknown account" }
        let home = NSHomeDirectory()
        return dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
    }
}

/// "Running elsewhere" / "Open elsewhere?" marker, on cards and in the
/// import list.
struct ExternalSessionBadge: View {
    let presence: ExternalSessionPresence
    var label: String?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: presence == .working ? "bolt.horizontal.circle.fill" : "rectangle.portrait.and.arrow.right")
                .font(.app(size: 8))
            Text(label ?? presence.badgeLabel)
                .font(.app(size: 9, weight: .medium))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.orange.opacity(0.15)))
        .foregroundStyle(.orange)
        .help(presence.resumeWarning)
    }
}
