import AppKit
import SwiftUI
import Testing
import KanbanCodeCore
import struct KanbanCodeCore.Link
import KanbanCodeRemoteKit
@testable import KanbanCode

/// Draws triage rows to PNG files, for looking at them without the app:
/// `KANBAN_TRIAGE_SNAPSHOT=<directory> swift test --filter TriageRowSnapshot`.
@Suite("Triage row snapshot")
@MainActor
struct TriageRowSnapshotTests {
    private nonisolated static let directory = ProcessInfo.processInfo.environment["KANBAN_TRIAGE_SNAPSHOT"]

    private func item(_ link: Link, snoozed: Bool = false) throws -> TriageItem {
        let card = KanbanCodeCard(link: link, activityState: .needsAttention)
        let snoozes = snoozed ? [link.id: TriageSnooze.timed(until: .now.addingTimeInterval(3600))] : [:]
        let queue = TriageQueue.build(
            cards: [card], openRequests: [], activitySince: [:], snoozes: snoozes,
            now: .now, includeSnoozed: true)
        return try #require(queue.items.first)
    }

    private func draw(_ items: [TriageItem], width: CGFloat, to name: String) async throws {
        let directory = try #require(Self.directory)
        let view = VStack(spacing: 6) {
            ForEach(items) { item in
                TriageItemRow(
                    item: item, now: .now, isFocused: false, preview: "Done. Ready for a look.", tail: [],
                    draft: .constant(""), composerFocusToken: 0,
                    onFocus: {}, onOpen: {}, onAnswer: { _, _ in }, onShowRequest: { _ in },
                    onSend: {}, onSnooze: { _ in }, onUnsnooze: {}, onComposerEscape: {})
            }
        }
        .padding(10)
        .frame(width: width, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        // As tall as the rows need, so a row that grows is not clipped.
        let height = host.fittingSize.height
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    @Test(.enabled(if: directory != nil))
    func rows() async throws {
        let full = Link(
            id: "full", name: "Show more on triage cards", projectPath: "/dev/kanban-code",
            column: .inReview,
            sessionLink: SessionLink(sessionId: "s-full"),
            tmuxLink: TmuxLink(sessionName: "full"),
            worktreeLink: WorktreeLink(path: "/dev/kanban-code-triage", branch: "cg/triage-card-info-with-a-long-name"),
            prLinks: [PRLink(number: 12, status: .approved, unresolvedThreads: 2), PRLink(number: 9, status: .merged)],
            issueLink: IssueLink(number: 2))
        var withRole = full
        withRole.role = "build-lite"
        var dense = Link(
            id: "dense", name: "Every badge at once, with a long title that has to give way",
            projectPath: "/dev/a-project-with-a-rather-long-folder-name",
            column: .inProgress,
            sessionLink: SessionLink(sessionId: "s-dense"),
            tmuxLink: TmuxLink(sessionName: "dense"),
            worktreeLink: WorktreeLink(path: "/dev/dense", branch: "cg/a-branch-name-long-enough-to-truncate"),
            prLinks: [PRLink(number: 31, status: .failing, unresolvedThreads: 4)],
            issueLink: IssueLink(number: 17))
        dense.priority = .urgent
        dense.role = "review"
        dense.pendingGate = PendingGate(action: .push, command: "git push", role: "review")
        dense.queuedPrompts = [QueuedPrompt(body: "next"), QueuedPrompt(body: "after")]
        var plain = Link(id: "plain", name: "A card with little to show", column: .waiting)
        plain.sessionLink = SessionLink(sessionId: "s-plain")
        let items = [try item(withRole), try item(dense), try item(plain, snoozed: true)]
        try await draw(items, width: 900, to: "triage-rows-wide.png")
        try await draw(items, width: 480, to: "triage-rows-narrow.png")
    }
}
