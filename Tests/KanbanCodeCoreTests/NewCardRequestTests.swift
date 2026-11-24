import Foundation
import Testing

@testable import KanbanCodeCore

/// `kanban new` writes a request the app decodes; the two sides only agree
/// through these field names.
@Suite("New card request")
struct NewCardRequestTests {

    @Test("a request written by the CLI decodes")
    func decodesCliRequest() throws {
        let json = """
        {
          "id": "abc", "operation": "createCard", "createdAt": "2026-11-25T00:00:00.000Z",
          "parentCardId": "card_1", "name": "fix-login", "prompt": "fix it",
          "role": "build", "projectPath": "/tmp/project", "worktreeName": "fix-login",
          "backlog": true
        }
        """
        let request = try JSONDecoder().decode(SubagentCommandRequest.self, from: Data(json.utf8))
        #expect(request.operation == .createCard)
        #expect(request.projectPath == "/tmp/project")
        #expect(request.backlog == true)
        #expect(request.role == "build")
        #expect(request.worktreeName == "fix-login")
    }

    @Test("optional fields may be absent")
    func minimalRequest() throws {
        let json = """
        {"id":"a","operation":"createCard","createdAt":"x","parentCardId":"c","prompt":"p"}
        """
        let request = try JSONDecoder().decode(SubagentCommandRequest.self, from: Data(json.utf8))
        #expect(request.projectPath == nil)
        #expect(request.backlog == nil)
    }
}

/// A card started by another card must not be able to fan out without limit.
@Suite("New card policy")
struct NewCardPolicyTests {

    private func card(_ id: String, startedBy: String? = nil, archived: Bool = false) -> Link {
        var link = Link(id: id, name: id)
        link.startedByCardId = startedBy
        link.manuallyArchived = archived
        return link
    }

    @Test("a human-started card may start cards")
    func humanStartedMay() {
        let root = card("root")
        #expect(NewCardPolicy.refusal(requester: root, requesterControls: false, links: [root]) == nil)
    }

    @Test("a card started by another card may not, unless its role controls the board")
    func startedCardMayNot() {
        let child = card("child", startedBy: "root")
        #expect(NewCardPolicy.refusal(requester: child, requesterControls: false, links: [child]) != nil)
        #expect(NewCardPolicy.refusal(requester: child, requesterControls: true, links: [child]) == nil)
    }

    @Test("the limit counts only active cards the requester started")
    func limitCountsActive() {
        let root = card("root")
        var links = [root]
        for index in 0..<NewCardPolicy.maximumActivePerRequester - 1 {
            links.append(card("c\(index)", startedBy: "root"))
        }
        links.append(card("done", startedBy: "root", archived: true))
        links.append(card("other", startedBy: "someone-else"))
        #expect(NewCardPolicy.refusal(requester: root, requesterControls: false, links: links) == nil)
        links.append(card("last", startedBy: "root"))
        #expect(NewCardPolicy.refusal(requester: root, requesterControls: true, links: links) != nil)
    }
}
