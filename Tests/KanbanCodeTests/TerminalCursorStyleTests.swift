import Testing
import AppKit
import SwiftTerm
@testable import KanbanCode

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

    @Test("the settings' cursor: a blinking line unless changed")
    func settingsMapping() {
        #expect(TerminalCache.cursorStyle(shape: nil, blink: true) == .blinkBar)
        #expect(TerminalCache.cursorStyle(shape: "bar", blink: false) == .steadyBar)
        #expect(TerminalCache.cursorStyle(shape: "block", blink: true) == .blinkBlock)
        #expect(TerminalCache.cursorStyle(shape: "underline", blink: false) == .steadyUnderline)
        #expect(TerminalCache.cursorStyle(shape: "junk", blink: true) == .blinkBar)
    }

    @MainActor
    @Test("a font family that is not installed, or none, falls back to the system monospaced font")
    func fontFallback() {
        let system = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        #expect(TerminalCache.terminalFont(size: 13, family: "").fontName == system.fontName)
        #expect(TerminalCache.terminalFont(size: 13, family: "No Such Font Family 42").fontName == system.fontName)
        #expect(TerminalCache.terminalFont(size: 13, family: "Menlo").familyName == "Menlo")
        #expect(TerminalCache.terminalFont(size: 13, family: "Menlo").pointSize == 13)
    }
}
