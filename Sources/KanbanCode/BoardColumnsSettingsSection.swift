import SwiftUI
import KanbanCodeCore

/// Settings > General > Board: the order of the board's lanes and which of
/// them show. Saved as `Settings.columnOrder`; a column left out is hidden.
struct BoardColumnsSettingsSection: View {
    private struct Row: Equatable {
        var column: KanbanCodeColumn
        var shown: Bool
    }

    @State private var rows: [Row] = []
    @State private var placement: CardPlacementMode = .strict
    private let settingsStore = SettingsStore()

    var body: some View {
        Section("Card Placement") {
            Picker("Moving cards", selection: $placement) {
                Text("Strict").tag(CardPlacementMode.strict)
                Text("Free").tag(CardPlacementMode.free)
            }
            .pickerStyle(.segmented)
            .onChange(of: placement) { _, newValue in savePlacement(newValue) }
            Text(placement == .strict
                 ? "Columns follow the session and its pull requests. In Review needs a PR, Done a merged PR, dropping into In Progress starts or resumes the card, and a working card moves back to In Progress."
                 : "Drop any card into any column and it stays there while its session works, until you launch, resume or drag it again. All Sessions still archives.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        Section("Board Columns") {
            ForEach(Array(rows.enumerated()), id: \.element.column) { index, row in
                HStack {
                    Toggle(isOn: binding(for: index)) {
                        Text(row.column.displayName)
                            .foregroundStyle(row.shown ? .primary : .secondary)
                    }
                    .toggleStyle(.checkbox)
                    // The board cannot be left without a lane.
                    .disabled(row.shown && rows.filter(\.shown).count == 1)
                    Spacer()
                    Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0)
                    Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(index == rows.count - 1)
                }
                .buttonStyle(.borderless)
            }
            HStack {
                Text("Unticked columns are hidden; their cards stay where they are. All Sessions only shows while it has cards.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Reset to Default") {
                    rows = Self.rows(for: KanbanCodeColumn.allCases)
                    save()
                }
                .controlSize(.small)
                .disabled(rows == Self.rows(for: KanbanCodeColumn.allCases))
            }
        }
        .task {
            let settings = try? await settingsStore.read()
            rows = Self.rows(for: settings?.columnOrder ?? KanbanCodeColumn.allCases)
            placement = settings?.cardPlacement ?? .strict
        }
        // The toolbar toggle changes the mode too.
        .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeSettingsChanged).receive(on: RunLoop.main)) { _ in
            Task {
                if let saved = (try? await settingsStore.read())?.cardPlacement, saved != placement {
                    placement = saved
                }
            }
        }
    }

    private func savePlacement(_ newValue: CardPlacementMode) {
        Task {
            do {
                var settings = try await settingsStore.read()
                guard settings.cardPlacement != newValue else { return }
                settings.cardPlacement = newValue
                try await settingsStore.write(settings)
                NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
            } catch {}
        }
    }

    /// Shown columns in their saved order, then the hidden ones.
    private static func rows(for order: [KanbanCodeColumn]) -> [Row] {
        var seen: Set<KanbanCodeColumn> = []
        let shown = order.filter { seen.insert($0).inserted }
        let hidden = KanbanCodeColumn.allCases.filter { !seen.contains($0) }
        return shown.map { Row(column: $0, shown: true) } + hidden.map { Row(column: $0, shown: false) }
    }

    private func binding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { rows.indices.contains(index) && rows[index].shown },
            set: { newValue in
                guard rows.indices.contains(index) else { return }
                rows[index].shown = newValue
                save()
            }
        )
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard rows.indices.contains(index), rows.indices.contains(target) else { return }
        rows.swapAt(index, target)
        save()
    }

    private func save() {
        let order = rows.filter(\.shown).map(\.column)
        Task {
            do {
                var settings = try await settingsStore.read()
                guard settings.columnOrder != order else { return }
                settings.columnOrder = order
                try await settingsStore.write(settings)
                NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
            } catch {}
        }
    }
}
