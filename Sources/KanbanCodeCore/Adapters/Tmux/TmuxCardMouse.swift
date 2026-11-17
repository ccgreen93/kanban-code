import Foundation

/// tmux handles the mouse in card terminals. The scrollback of a card is
/// tmux's, not the terminal view's, so only tmux can select past the screen:
/// a drag runs tmux's copy-mode selection, which scrolls the history while
/// the pointer is held at the top or bottom edge, and the wheel reaches tmux
/// as mouse reports over the attached client instead of a tmux process per
/// scroll.
///
/// The server is usually the person's own tmux server, so the bindings are
/// not replaced: each one is wrapped in `if-shell -F '#{@kanban_card}'`,
/// with the binding that was there as the else branch. Panes of sessions
/// the app did not mark behave as they did.
///
/// What the wrapped bindings change in a card:
/// - letting go of a drag keeps the selection instead of copying it and
///   leaving copy-mode; cmd+c copies it (`copySelectionArguments`),
/// - a click in copy-mode clears the selection,
/// - a double or triple click selects a word or line, also without copying,
/// - a wheel report scrolls one line, so the app can turn a trackpad's
///   movement into lines; scrolling down to the bottom leaves copy-mode
///   unless something is selected.
public enum TmuxCardMouse {
    /// The session option that marks a session as a card's.
    public static let markerOption = "@kanban_card"

    /// Scrollback of a card's pane, in lines (tmux's default is 2000).
    public static let historyLimit = 50_000

    static let condition = "#{\(markerOption)}"

    struct Binding: Equatable {
        let table: String
        let key: String
        let command: String
    }

    static let bindings: [Binding] = {
        var list: [Binding] = []
        for table in ["copy-mode", "copy-mode-vi"] {
            list += [
                Binding(table: table, key: "MouseDown1Pane", command: "select-pane ; send-keys -X clear-selection"),
                Binding(table: table, key: "MouseDragEnd1Pane", command: "send-keys -X stop-selection"),
                Binding(table: table, key: "DoubleClick1Pane",
                        command: "select-pane ; send-keys -X select-word ; send-keys -X stop-selection"),
                Binding(table: table, key: "TripleClick1Pane",
                        command: "select-pane ; send-keys -X select-line ; send-keys -X stop-selection"),
                Binding(table: table, key: "WheelUpPane", command: "select-pane ; send-keys -X scroll-up"),
                Binding(table: table, key: "WheelDownPane",
                        command: "select-pane ; if-shell -F '#{selection_present}' { send-keys -X scroll-down } { send-keys -X scroll-down-and-cancel }"),
            ]
        }
        let passThrough = "#{||:#{pane_in_mode},#{mouse_any_flag}}"
        list += [
            Binding(table: "root", key: "DoubleClick1Pane",
                    command: "select-pane -t = ; if-shell -F '\(passThrough)' { send-keys -M } { copy-mode -H ; send-keys -X select-word ; send-keys -X stop-selection }"),
            Binding(table: "root", key: "TripleClick1Pane",
                    command: "select-pane -t = ; if-shell -F '\(passThrough)' { send-keys -M } { copy-mode -H ; send-keys -X select-line ; send-keys -X stop-selection }"),
        ]
        return list
    }()

    /// The tables whose bindings are wrapped.
    static var tables: [String] { Array(Set(bindings.map(\.table))).sorted() }

    /// The command bound to `key` in one table's `list-keys` output, as tmux
    /// prints it (`\;` between commands). Nil when the key is not bound.
    static func existingCommand(key: String, table: String, listKeys: String) -> String? {
        for line in listKeys.split(separator: "\n") {
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.first == "bind-key",
                  let tableFlag = tokens.firstIndex(of: "-T"),
                  tableFlag + 2 < tokens.count,
                  tokens[tableFlag + 1] == table,
                  tokens[tableFlag + 2] == key else { continue }
            // The command is what follows the key, spacing kept.
            guard let tableRange = line.range(of: "-T \(table)"),
                  let keyRange = line.range(of: " \(key) ", range: tableRange.upperBound..<line.endIndex)
            else { return "" }
            return line[keyRange.upperBound...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The `bind-key` arguments that wrap one binding, or nil when it is
    /// wrapped already.
    static func bindArguments(_ binding: Binding, existing: String?) -> [String]? {
        if let existing, existing.contains(condition) { return nil }
        var arguments = ["bind-key", "-T", binding.table, binding.key, "if-shell", "-F", condition, binding.command]
        if let existing, !existing.isEmpty { arguments.append(existing) }
        return arguments
    }

    /// The commands that wrap every binding not wrapped yet, from the
    /// `list-keys -T <table>` output of each table.
    static func installCommands(listKeys: [String: String]) -> [[String]] {
        bindings.compactMap { binding in
            let existing = existingCommand(key: binding.key, table: binding.table, listKeys: listKeys[binding.table] ?? "")
            return bindArguments(binding, existing: existing)
        }
    }

    /// The options that hand a session's mouse to tmux and mark it as a card's.
    public static func sessionOptionCommands(session: String) -> [[String]] {
        [
            ["set-option", "-t", session, "mouse", "on"],
            ["set-option", "-t", session, markerOption, "1"],
            ["set-option", "-t", session, "history-limit", "\(historyLimit)"],
        ]
    }
}

extension TmuxAdapter {
    /// Hands the mouse of a card's session to tmux: marks the session and
    /// wraps the mouse bindings of its server (once; a reload of the
    /// person's tmux.conf puts the originals back, so it is checked on every
    /// attach). New windows of the session get the larger scrollback; the
    /// pane that is there keeps the one it was made with.
    public func enableCardMouse(session: String) async {
        for command in TmuxCardMouse.sessionOptionCommands(session: session) {
            _ = try? await run(command, timeout: 5)
        }
        var listKeys: [String: String] = [:]
        for table in TmuxCardMouse.tables {
            guard let result = try? await run(["list-keys", "-T", table], timeout: 5), result.succeeded else { continue }
            listKeys[table] = result.stdout
        }
        for command in TmuxCardMouse.installCommands(listKeys: listKeys) {
            let result = try? await run(command, timeout: 5)
            if let result, !result.succeeded {
                KanbanCodeLog.warn("tmux", "mouse binding \(command[2]) \(command[3]) failed: \(result.stderr)")
            }
        }
    }

    /// Copies the tmux selection of a session's pane, if there is one, and
    /// returns it.
    public func copySelection(session: String) async -> String? {
        guard let present = try? await run(["display-message", "-p", "-t", session, "#{selection_present}"], timeout: 5),
              present.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1",
              let copied = try? await run(["send-keys", "-t", session, "-X", "copy-selection-no-clear"], timeout: 5),
              copied.succeeded,
              let buffer = try? await run(["save-buffer", "-"], timeout: 5),
              buffer.succeeded else { return nil }
        return buffer.stdout
    }
}
