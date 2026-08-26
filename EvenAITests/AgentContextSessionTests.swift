import Foundation
import Testing
@testable import EvenAI

/// Pure domain-model tests for the shared conversation/session/context
/// object — no Speech/Azure/OpenAI/G2/SwiftUI, no `AIConversationEngine`,
/// no networking. `AIConversationEngine` and Chat are untouched by this
/// milestone; these tests only cover the new shared model in isolation.
@Suite("AgentContextSession")
struct AgentContextSessionTests {
    @Test("a new session starts empty, inactive, and with no latest turn")
    func startsEmpty() {
        let session = AgentContextSession()
        #expect(session.turns.isEmpty)
        #expect(session.contextItems.isEmpty)
        #expect(session.liveConversationState == .inactive)
        #expect(session.latestTurn == nil)
    }

    @Test("appending a turn adds it to the timeline and it becomes the latest turn")
    func appendsTurn() {
        var session = AgentContextSession()
        let turn = ConversationTurn(originalText: "hello", source: .liveConversation)
        session.append(turn)
        #expect(session.turns == [turn])
        #expect(session.latestTurn == turn)
    }

    @Test("turns preserve insertion order, oldest to newest")
    func ordering() {
        var session = AgentContextSession()
        let first = ConversationTurn(originalText: "first", source: .liveConversation)
        let second = ConversationTurn(originalText: "second", source: .phoneChat)
        let third = ConversationTurn(originalText: "third", source: .liveConversation)

        session.append(first)
        session.append(second)
        session.append(third)

        #expect(session.turns.map(\.originalText) == ["first", "second", "third"])
    }

    @Test("latestTurn always reflects the most recently appended turn")
    func latestTurnLookup() {
        var session = AgentContextSession()
        let first = ConversationTurn(originalText: "first", source: .liveConversation)
        let second = ConversationTurn(originalText: "second", source: .liveConversation)

        session.append(first)
        #expect(session.latestTurn == first)

        session.append(second)
        #expect(session.latestTurn == second)
    }

    @Test("adding user notes and pasted/imported context keeps them separate from the conversation timeline")
    func userNotesAndContext() {
        var session = AgentContextSession()
        let note = ContextItem(kind: .note, text: "Business meeting tomorrow with this company.")
        let pasted = ContextItem(kind: .pastedText, text: "Agenda: pricing, timeline, next steps.")
        let file = ContextItem(kind: .importedFile, text: "proposal.pdf", metadata: ["fileID": "abc-123"])

        session.addContext(note)
        session.addContext(pasted)
        session.addContext(file)

        #expect(session.contextItems == [note, pasted, file])
        #expect(session.turns.isEmpty) // context items never implicitly become turns
    }

    @Test("live conversation state can be set independently of the turns/context it holds")
    func liveConversationState() {
        var session = AgentContextSession()
        session.liveConversationState = .listening
        #expect(session.liveConversationState == .listening)
        #expect(session.turns.isEmpty)

        session.liveConversationState = .paused
        #expect(session.liveConversationState == .paused)
    }

    @Test("suggested replies attached to a turn survive being added to a session")
    func suggestedRepliesSurviveInSession() {
        var session = AgentContextSession()
        let replies = [
            SuggestedReply(originalLanguageText: "Sure, no problem.", ukrainianText: "Так, без проблем.", ordering: 0),
            SuggestedReply(originalLanguageText: "Thursday works for me.", ukrainianText: "Четвер мені підходить.", ordering: 1),
            SuggestedReply(originalLanguageText: "Let me check.", ukrainianText: "Дай перевірю.", ordering: 2),
        ]
        let turn = ConversationTurn(
            originalText: "Können wir das Meeting auf Donnerstag verschieben?",
            detectedLanguage: "de-DE",
            ukrainianTranslation: "Можемо перенести зустріч на четвер?",
            suggestedReplies: replies,
            source: .liveConversation
        )

        session.append(turn)

        #expect(session.latestTurn?.suggestedReplies == replies)
    }

    @Test("ignoring Ukrainian translation output: a Ukrainian-sourced turn carries no translation once in the session")
    func ignoresUkrainianTranslationInSession() {
        var session = AgentContextSession()
        let ukrainianTurn = ConversationTurn.liveConversationTurn(
            originalText: "Привіт!",
            detectedLanguage: "uk-UA",
            ukrainianTranslation: "Привіт!"
        )

        session.append(ukrainianTurn)

        #expect(session.latestTurn?.ukrainianTranslation == nil)
        #expect(session.latestTurn?.detectedLanguage == "uk-UA")
    }

    @Test("a session round-trips through Codable unchanged")
    func codableRoundTrip() throws {
        var session = AgentContextSession()
        session.append(ConversationTurn.liveConversationTurn(
            originalText: "Guten Tag",
            detectedLanguage: "de-DE",
            ukrainianTranslation: "Добрий день",
            suggestedReplies: [SuggestedReply(originalLanguageText: "Hi", ukrainianText: "Привіт", ordering: 0)]
        ))
        session.addContext(ContextItem(kind: .note, text: "Meeting tomorrow."))
        session.liveConversationState = .listening

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentContextSession.self, from: data)

        #expect(decoded == session)
    }
}
