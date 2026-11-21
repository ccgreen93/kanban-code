import SwiftTerm
import Testing

@testable import KanbanCode

/// Cmd+arrows in the terminal: line start/end (left/right), scroll top/bottom (up/down).
@Suite("Terminal Cmd+arrow bytes")
@MainActor
struct TerminalCommandArrowTests {

    @Test("Left/Right go to start/end of the visual line (Home / End)")
    func leftRight() {
        #expect(TerminalCache.commandArrowBytes(keyCode: 123) == [0x1b, 0x5b, 0x48])
        #expect(TerminalCache.commandArrowBytes(keyCode: 124) == [0x1b, 0x5b, 0x46])
        #expect(TerminalCache.commandArrowBytes(keyCode: 123, applicationCursor: true) == [0x1b, 0x4f, 0x48])
        #expect(TerminalCache.commandArrowBytes(keyCode: 124, applicationCursor: true) == [0x1b, 0x4f, 0x46])
    }

    @Test("Up/Down scroll to the top/bottom (Ctrl+Home / Ctrl+End)")
    func upDown() {
        #expect(TerminalCache.commandArrowBytes(keyCode: 126) == [0x1b, 0x5b, 0x31, 0x3b, 0x35, 0x48])
        #expect(TerminalCache.commandArrowBytes(keyCode: 125) == [0x1b, 0x5b, 0x31, 0x3b, 0x35, 0x46])
    }

    @Test("Other keys are not handled")
    func otherKeys() {
        #expect(TerminalCache.commandArrowBytes(keyCode: 0) == nil)
        #expect(TerminalCache.commandArrowBytes(keyCode: 51) == nil)
    }
}
