import Foundation
import Testing
@testable import EvenAI

/// Pure tests for what `ChatView`'s live-conversation section shows —
/// no SwiftUI hosting, no `AIConversationEngine`. Complements
/// `AIConversationEngineAgentContextTests` (which proves turns are
/// recorded correctly) by proving Chat's own presentation of those turns
/// is correct: latest-first prominence, older turns newest-first, and
/// zero turns when the session is empty.
@Suite("ChatLiveConversationPresenter")
struct ChatLiveConversationPresenterTests {
    @Test("an empty session presents no latest turn and no older turns")
    func emptySession() {
        let result = ChatLiveConversationPresenter.present(AgentContextSession())
        #expect(result.latest == nil)
        #expect(result.older.isEmpty)
    }

    @Test("a single turn is presented as the latest, with no older turns")
    func singleTurn() {
        var session = AgentContextSession()
        let turn = ConversationTurn.liveConversationTurn(
            originalText: "Guten Tag",
            detectedLanguage: "de-DE",
            ukrainianTranslation: "Добрий день"
        )
        session.append(turn)

        let result = ChatLiveConversationPresenter.present(session)

        #expect(result.latest == turn)
        #expect(result.older.isEmpty)
    }

    @Test("multiple turns: the newest is latest, and older turns are newest-first")
    func multipleTurns() {
        var session = AgentContextSession()
        let first = ConversationTurn.liveConversationTurn(originalText: "one", detectedLanguage: "en-US", ukrainianTranslation: "один")
        let second = ConversationTurn.liveConversationTurn(originalText: "two", detectedLanguage: "en-US", ukrainianTranslation: "два")
        let third = ConversationTurn.liveConversationTurn(originalText: "three", detectedLanguage: "en-US", ukrainianTranslation: "три")

        session.append(first)
        session.append(second)
        session.append(third)

        let result = ChatLiveConversationPresenter.present(session)

        #expect(result.latest == third)
        #expect(result.older == [second, first]) // newest-first among the older ones
    }
}
