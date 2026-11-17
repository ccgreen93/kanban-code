import Foundation
import Testing
@testable import KanbanCodeCore

@Suite("tmux card mouse")
struct TmuxCardMouseTests {
    static let copyModeKeys = """
    bind-key    -T copy-mode MouseDown1Pane    select-pane
    bind-key    -T copy-mode MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel
    bind-key -r -T copy-mode WheelUpPane       select-pane \\; send-keys -X -N 5 scroll-up
    """

    @Test("the command of a binding is read from list-keys, flags and spacing aside")
    func readsExistingCommand() {
        #expect(TmuxCardMouse.existingCommand(key: "MouseDragEnd1Pane", table: "copy-mode", listKeys: Self.copyModeKeys)
            == "send-keys -X copy-pipe-and-cancel")
        #expect(TmuxCardMouse.existingCommand(key: "WheelUpPane", table: "copy-mode", listKeys: Self.copyModeKeys)
            == "select-pane \\; send-keys -X -N 5 scroll-up")
        #expect(TmuxCardMouse.existingCommand(key: "WheelDownPane", table: "copy-mode", listKeys: Self.copyModeKeys) == nil)
        #expect(TmuxCardMouse.existingCommand(key: "MouseDown1Pane", table: "copy-mode-vi", listKeys: Self.copyModeKeys) == nil)
    }

    @Test("a binding is wrapped with the one that was there as the else branch, and only once")
    func wrapsOnce() throws {
        let binding = try #require(TmuxCardMouse.bindings.first { $0.table == "copy-mode" && $0.key == "MouseDragEnd1Pane" })
        let arguments = try #require(TmuxCardMouse.bindArguments(binding, existing: "send-keys -X copy-pipe-and-cancel"))
        #expect(arguments == ["bind-key", "-T", "copy-mode", "MouseDragEnd1Pane", "if-shell", "-F", "#{@kanban_card}",
                              "send-keys -X stop-selection", "send-keys -X copy-pipe-and-cancel"])
        let wrapped = "if-shell -F \"#{@kanban_card}\" \"send-keys -X stop-selection\" \"send-keys -X copy-pipe-and-cancel\""
        #expect(TmuxCardMouse.bindArguments(binding, existing: wrapped) == nil)
        // An unbound key gets the card's command only.
        #expect(TmuxCardMouse.bindArguments(binding, existing: nil)?.count == 8)
    }

    @Test("on a real tmux server the bindings install, and a second pass has nothing to do")
    func installsOnTmux() async throws {
        guard let tmux = ShellCommand.findExecutable("tmux") else { return }
        let transport = SocketTransport(tmux: tmux, socket: "kanban-mouse-\(UUID().uuidString.prefix(8))")
        let adapter = TmuxAdapter(transport: transport)
        defer {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: tmux)
            kill.arguments = ["-L", transport.socket, "kill-server"]
            try? kill.run()
            kill.waitUntilExit()
        }
        try await adapter.createSession(name: "card", path: NSTemporaryDirectory(), command: nil)
        await adapter.enableCardMouse(session: "card")

        func value(_ format: String) async throws -> String {
            try await adapter.run(["display-message", "-p", "-t", "card", format]).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #expect(try await value("#{mouse} #{@kanban_card} #{history_limit}") == "1 1 \(TmuxCardMouse.historyLimit)")

        var listKeys: [String: String] = [:]
        for table in TmuxCardMouse.tables {
            listKeys[table] = try await adapter.run(["list-keys", "-T", table]).stdout
        }
        #expect(TmuxCardMouse.installCommands(listKeys: listKeys).isEmpty)
        let drag = TmuxCardMouse.existingCommand(key: "MouseDragEnd1Pane", table: "copy-mode", listKeys: listKeys["copy-mode"]!)
        #expect(drag?.contains("copy-pipe-and-cancel") == true)
        #expect(drag?.contains("stop-selection") == true)
    }
}

/// tmux on a private socket with no config, so a test never touches the
/// person's server.
private struct SocketTransport: TmuxTransport {
    let tmux: String
    let socket: String

    func run(_ arguments: [String], timeout: TimeInterval) async throws -> ShellCommand.Result {
        try await ShellCommand.run(tmux, arguments: ["-L", socket, "-f", "/dev/null"] + arguments, timeout: timeout)
    }
    func writeTempFile(name: String, contents: String) async throws -> String {
        let path = NSTemporaryDirectory() + name
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }
    func removeTempFile(_ path: String) async { try? FileManager.default.removeItem(atPath: path) }
    func isAvailable() async -> Bool { true }
}
