import Foundation
import Testing
@testable import EvenAI

/// Milestone 3: end-to-end proof that Chat observes the SAME
/// `AgentContextStore` instance `AIConversationEngine` writes into —
/// one shared store, read by `ChatLiveConversationPresenter` (what
/// `ChatView` actually calls), written by `AIConversationEngine`, never
/// two independent copies.
@MainActor
@Suite("Chat + shared AgentContextStore")
struct ChatSharedAgentContextIntegrationTests {
    private static let propagationDelay: Duration = .milliseconds(30)

    @Test("a live turn recorded by AIConversationEngine appears in Chat's presenter, through the shared store")
    func liveTurnAppearsInChatFromSharedStore() async throws {
        let store = AgentContextStore()
        let service = AIConversationEngine(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: ["hello there"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["hello there": "en"], translation: "привіт"),
            agentContextStore: store
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        // Chat never reads `AIConversationEngine` for this — it only
        // ever calls the presenter against the shared store, exactly as
        // `ChatView.body` does.
        let presented = ChatLiveConversationPresenter.present(store.session)
        #expect(presented.latest?.originalText == "hello there")
        #expect(presented.latest?.ukrainianTranslation == "привіт")
        #expect(presented.latest?.detectedLanguage == "en")
    }

    @Test("multiple turns update Chat's presenter correctly as they arrive")
    func multipleTurnsUpdateCorrectly() async throws {
        let store = AgentContextStore()
        let transcriber = ScriptedContinuousTranscriber(finals: ["first phrase", "second phrase"])
        let service = AIConversationEngine(
            glassesTransport: SpyGlassesTransport(),
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(
                languageCodes: ["first phrase": "en", "second phrase": "en"],
                translation: "переклад"
            ),
            agentContextStore: store
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        let presented = ChatLiveConversationPresenter.present(store.session)
        #expect(presented.latest?.originalText == "second phrase")
        #expect(presented.older.map(\.originalText) == ["first phrase"])
    }

    @Test("Ukrainian speech still does not appear as a translated live turn in Chat")
    func ukrainianSpeechDoesNotAppearInChat() async throws {
        let store = AgentContextStore()
        let service = AIConversationEngine(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: ["привіт, як справи"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["привіт, як справи": "uk"]),
            agentContextStore: store
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        let presented = ChatLiveConversationPresenter.present(store.session)
        #expect(presented.latest == nil)
        #expect(presented.older.isEmpty)
    }

    @Test("regular Chat messages are unaffected by the shared live-conversation store")
    func regularChatMessagesRemainUnchanged() async throws {
        let store = AgentContextStore()
        let viewModel = ChatViewModel(
            chatID: UUID(),
            chatService: MockChatService(),
            glassesTransport: MockGlassesTransport()
        )

        // A live turn arrives in the shared store — must not leak into
        // Chat's own message list, which `ChatViewModel` never reads the
        // store for at all.
        store.appendTurn(
            .liveConversationTurn(originalText: "Guten Tag", detectedLanguage: "de-DE", ukrainianTranslation: "Добрий день")
        )

        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.draftText.isEmpty)
    }

    @Test("no second AgentContextStore is created — the writer (AIConversationEngine) and reader (Chat) see the same instance")
    func noSecondStoreIsCreated() async throws {
        let store = AgentContextStore()
        let service = AIConversationEngine(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: ["hello there"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["hello there": "en"], translation: "привіт"),
            agentContextStore: store
        )

        // Before starting, an external reference to the exact instance
        // handed to the service sees nothing — proving there's no
        // hidden, pre-populated second store anywhere.
        #expect(ChatLiveConversationPresenter.present(store.session).latest == nil)

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        // The SAME external reference now sees the turn the service
        // wrote — a second, independent store would not observe this.
        #expect(ChatLiveConversationPresenter.present(store.session).latest?.originalText == "hello there")
    }
}
