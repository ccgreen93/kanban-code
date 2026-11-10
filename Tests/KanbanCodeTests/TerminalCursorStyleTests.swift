import Testing
import SwiftTerm

@Suite("Terminal cursor style")
struct TerminalCursorStyleTests {
    final class Delegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    @Test("a program asking for the default cursor gets the configured one, an explicit style stays explicit")
    func defaultStyle() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.options.defaultCursorStyle = .blinkBar
        terminal.feed(text: "\u{1b}[2 q")
        #expect(terminal.options.cursorStyle == .steadyBlock)
        terminal.feed(text: "\u{1b}[0 q")
        #expect(terminal.options.cursorStyle == .blinkBar)
        terminal.feed(text: "\u{1b}[ q")
        #expect(terminal.options.cursorStyle == .blinkBar)
    }
}
