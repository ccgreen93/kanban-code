import Testing

@testable import KanbanCode

/// Cmd+arrows in the terminal: line start/end (left/right), prompt start/end (up/down).
@Suite("Terminal Cmd+arrow bytes")
@MainActor
struct TerminalCommandArrowTests {

    @Test("Left/Right go to start/end of line (Ctrl+A / Ctrl+E)")
    func leftRight() {
        #expect(TerminalCache.commandArrowBytes(keyCode: 123) == [0x01])
        #expect(TerminalCache.commandArrowBytes(keyCode: 124) == [0x05])
    }

    @Test("Up/Down go to start/end of the prompt (ESC < / ESC >)")
    func upDown() {
        #expect(TerminalCache.commandArrowBytes(keyCode: 126) == [0x1b, 0x3c])
        #expect(TerminalCache.commandArrowBytes(keyCode: 125) == [0x1b, 0x3e])
    }

    @Test("Other keys are not handled")
    func otherKeys() {
        #expect(TerminalCache.commandArrowBytes(keyCode: 0) == nil)
        #expect(TerminalCache.commandArrowBytes(keyCode: 51) == nil)
    }
}
