import Testing
import Foundation
@testable import EvenAI

/// Milestone 8b: proves `LiveTranslationService` behaves correctly when
/// wired to the *real* production transcriber (`OpenAIRealtimeTranscriber`),
/// not just `ScriptedContinuousTranscriber` — the one thing
/// `LiveTranslationServiceTests`/`OpenAIRealtimeTranscriberTests` (Milestone
/// 8a) couldn't prove on their own, since neither exercises both types
/// together. Still entirely fake-driven: `FakeRealtimeTranscriptionSocket`
/// stands in for the WebSocket connection — no real network call anywhere
/// in this file.
///
/// Multilingual configuration (English/German/Polish/Ukrainian) lives
/// entirely on the backend (see `openaiClient.js`'s `SUPPORTED_LANGUAGES`)
/// — nothing here configures a language; these tests only prove that
/// whatever text the transcription layer reports, in whatever language,
/// flows correctly through `LiveTranslationService`'s existing (unchanged)
/// detect → filter-Ukrainian → translate → display pipeline.
@MainActor
@Suite("LiveTranslationService + OpenAIRealtimeTranscriber (production wiring)")
struct LiveTranslationServiceOpenAIRealtimeTranscriberTests {
    private static let propagationDelay: Duration = .milliseconds(30)

    private func makeService(
        factory: FakeRealtimeTranscriptionSocketFactory,
        spy: SpyGlassesTransport,
        store: AgentContextStore,
        languageCodes: [String: String?],
        translation: String = "переклад"
    ) -> LiveTranslationService {
        LiveTranslationService(
            glassesTransport: spy,
            transcriber: OpenAIRealtimeTranscriber(makeSocket: { await factory.makeSocket() }),
            translator: ScriptedLanguageTranslator(languageCodes: languageCodes, translation: translation),
            agentContextStore: store
        )
    }

    @Test("English, German, and Polish finals each become a translated, displayed turn")
    func multilingualFinalsBecomeTurns() async throws {
        let factory = FakeRealtimeTranscriptionSocketFactory()
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let service = makeService(
            factory: factory, spy: spy, store: store,
            languageCodes: ["Good morning": "en", "Guten Tag": "de", "Dzień dobry": "pl"]
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)
        let socket = await factory.createdSockets[0]

        await socket.emit(.finalTranscript("Good morning"))
        try? await Task.sleep(for: Self.propagationDelay)
        await socket.emit(.finalTranscript("Guten Tag"))
        try? await Task.sleep(for: Self.propagationDelay)
        await socket.emit(.finalTranscript("Dzień dobry"))
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(store.session.turns.map(\.originalText) == ["Good morning", "Guten Tag", "Dzień dobry"])
        #expect(store.session.turns.map(\.detectedLanguage) == ["en", "de", "pl"])
        #expect(await spy.displayedPageSets == [
            ["Good morning\n\nUA: переклад"],
            ["Guten Tag\n\nUA: переклад"],
            ["Dzień dobry\n\nUA: переклад"],
        ])
    }

    @Test("Ukrainian speech is recognized but never becomes a live-conversation turn")
    func ukrainianIsFilteredOut() async throws {
        let factory = FakeRealtimeTranscriptionSocketFactory()
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let service = makeService(
            factory: factory, spy: spy, store: store,
            languageCodes: ["привіт, як справи": "uk"]
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)
        let socket = await factory.createdSockets[0]

        await socket.emit(.finalTranscript("привіт, як справи"))
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(store.session.turns.isEmpty)
        #expect(await spy.displayedPageSets.isEmpty)
    }

    @Test("language can switch mid-session (English → German → Polish → Ukrainian) without restarting Live Translation")
    func languageSwitchesMidSessionWithoutRestart() async throws {
        let factory = FakeRealtimeTranscriptionSocketFactory()
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let service = makeService(
            factory: factory, spy: spy, store: store,
            languageCodes: [
                "Good morning": "en",
                "Guten Tag": "de",
                "Dzień dobry": "pl",
                "Доброго ранку": "uk",
            ]
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)
        let socket = await factory.createdSockets[0]

        for phrase in ["Good morning", "Guten Tag", "Dzień dobry", "Доброго ранку"] {
            await socket.emit(.finalTranscript(phrase))
            try? await Task.sleep(for: Self.propagationDelay)
        }

        // Exactly one connection for the whole session — a language
        // switch is not a restart.
        #expect(await factory.createdSockets.count == 1)
        // The three foreign phrases became turns, in order; the
        // Ukrainian one didn't.
        #expect(store.session.turns.map(\.originalText) == ["Good morning", "Guten Tag", "Dzień dobry"])
    }

    @Test("exactly one ConversationTurn is created per distinct final utterance — no duplicates")
    func exactlyOneTurnPerFinal() async throws {
        let factory = FakeRealtimeTranscriptionSocketFactory()
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let service = makeService(
            factory: factory, spy: spy, store: store,
            languageCodes: ["Guten Tag": "de", "Dzień dobry": "pl"]
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)
        let socket = await factory.createdSockets[0]

        await socket.emit(.finalTranscript("Guten Tag"))
        try? await Task.sleep(for: Self.propagationDelay)
        await socket.emit(.finalTranscript("Dzień dobry"))
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(store.session.turns.count == 2)
    }

    @Test("a WebSocket disconnect reconnects once, transparently — the session keeps working")
    func disconnectReconnectsAndSessionKeepsWorking() async throws {
        let factory = FakeRealtimeTranscriptionSocketFactory()
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let service = makeService(
            factory: factory, spy: spy, store: store,
            languageCodes: ["Guten Tag": "de"]
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)
        let firstSocket = await factory.createdSockets[0]

        await firstSocket.emit(.closed(reason: "network blip"))
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(await factory.createdSockets.count == 2)
        #expect(service.state == .listening) // never dropped to .error/.idle

        let secondSocket = await factory.createdSockets[1]
        await secondSocket.emit(.finalTranscript("Guten Tag"))
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(store.session.turns.map(\.originalText) == ["Guten Tag"])
    }

    @Test("a second consecutive disconnect ends the live session cleanly — no retry storm")
    func secondConsecutiveDisconnectEndsSessionCleanly() async throws {
        let factory = FakeRealtimeTranscriptionSocketFactory()
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let service = makeService(
            factory: factory, spy: spy, store: store,
            languageCodes: [:]
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)
        let firstSocket = await factory.createdSockets[0]

        await firstSocket.emit(.closed(reason: "first drop"))
        try? await Task.sleep(for: Self.propagationDelay)
        let secondSocket = await factory.createdSockets[1]

        await secondSocket.emit(.closed(reason: "second drop"))
        try? await Task.sleep(for: Self.propagationDelay)

        // Ends cleanly (LiveTranslationService's existing "stream errored"
        // path: state -> .error, stop() disables the mic) — no third
        // connection ever attempted, i.e. no retry storm.
        #expect(await factory.createdSockets.count == 2)
        guard case .error = service.state else {
            Issue.record("expected .error, got \(service.state)")
            return
        }
        #expect(await spy.microphoneEnabledCalls == [true, false])
    }
}
