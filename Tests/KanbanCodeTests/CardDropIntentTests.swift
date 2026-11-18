import Testing
@testable import KanbanCode
import KanbanCodeCore

@Suite("Card Drop Intent")
struct CardDropIntentTests {
    @Test("Fresh backlog cards start when dropped into In Progress")
    func backlogCardStarts() {
        let card = KanbanCodeCard(
            link: Link(
                id: "card_backlog",
                name: "Fix login bug",
                projectPath: "/test/project",
                column: .backlog,
                source: .manual
            )
        )

        #expect(CardDropIntent.resolve(card, to: .inProgress) == .start)
    }

    @Test("Cards without pull requests cannot be dropped into In Review")
    func cardWithoutPRCannotMoveToReview() {
        let card = KanbanCodeCard(
            link: Link(
                id: "card_waiting",
                name: "Needs review",
                projectPath: "/test/project",
                column: .waiting,
                source: .manual
            )
        )

        #expect(
            CardDropIntent.resolve(card, to: .inReview)
                == .invalid("Cannot move to In Review - card has no pull request")
        )
    }

    @Test("Cards without merged pull requests cannot be dropped into Done")
    func cardWithoutMergedPRCannotMoveToDone() {
        let card = KanbanCodeCard(
            link: Link(
                id: "card_review",
                name: "Open PR",
                projectPath: "/test/project",
                column: .inReview,
                source: .manual,
                prLinks: [PRLink(number: 42, title: "Open PR")]
            )
        )

        #expect(
            CardDropIntent.resolve(card, to: .done)
                == .invalid("Cannot move to Done - no merged pull request")
        )
    }

    @Test("Archived cards can be restored to Backlog")
    func archivedCardMovesBackToBacklog() {
        let card = KanbanCodeCard(
            link: Link(
                id: "card_archived",
                name: "Archived",
                projectPath: "/test/project",
                column: .allSessions,
                manuallyArchived: true,
                source: .manual
            )
        )

        #expect(CardDropIntent.resolve(card, to: .backlog) == .move)
    }
}

@Suite("Card Drop Intent: free placement")
struct CardDropIntentFreeTests {
    private func card(column: KanbanCodeColumn, running: Bool = false) -> KanbanCodeCard {
        KanbanCodeCard(link: Link(
            id: "card_1", name: "Some task", projectPath: "/test/project",
            column: column, source: .manual,
            tmuxLink: running ? TmuxLink(sessionName: "project-card_1") : nil
        ))
    }

    @Test("Any card moves into any lane, with no pull request or session required")
    func anyCardAnyLane() {
        let lanes: [KanbanCodeColumn] = [.backlog, .inProgress, .waiting, .inReview, .done]
        for from in lanes {
            for to in lanes {
                #expect(CardDropIntent.resolve(card(column: from), to: to, placement: .free) == .move)
                #expect(CardDropIntent.resolve(card(column: from, running: true), to: to, placement: .free) == .move)
            }
        }
    }

    @Test("Dropping into In Progress only moves the card; All Sessions still archives")
    func inProgressMovesAllSessionsArchives() {
        #expect(CardDropIntent.resolve(card(column: .backlog), to: .inProgress, placement: .free) == .move)
        #expect(CardDropIntent.resolve(card(column: .waiting), to: .allSessions, placement: .free) == .archive)
    }
}
