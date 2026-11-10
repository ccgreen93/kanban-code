import SwiftUI
import KanbanCodeCore

/// Import Session: the toolbar button beside New Task and its sheet.
extension ContentView {
    var importSessionToolbarButton: some View {
        Button { showImportSession = true } label: {
            Image(systemName: "tray.and.arrow.down")
        }
        .help("Import a session started outside Kanban (⇧⌘I)")
    }

    /// The sheet, and the File menu item (⇧⌘I) that opens it.
    var importSessionPresenter: ImportSessionPresenter {
        ImportSessionPresenter(isPresented: $showImportSession, sheet: importSessionSheet)
    }

    private var importSessionSheet: ImportSessionSheet {
        ImportSessionSheet(store: store, isPresented: $showImportSession) { cardId in
            // The board may be filtered to another project: show where the
            // card landed rather than leaving it off screen.
            if let selected = store.state.selectedProjectPath,
               let link = store.state.links[cardId],
               let path = link.projectPath,
               !(path == selected || path.hasPrefix(selected + "/")) {
                setSelectedProject(nil)
            }
            store.dispatch(.selectCard(cardId: cardId))
        }
    }
}

struct ImportSessionPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let sheet: ImportSessionSheet

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) { sheet }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeImportSession).receive(on: RunLoop.main)) { _ in
                isPresented = true
            }
    }
}
