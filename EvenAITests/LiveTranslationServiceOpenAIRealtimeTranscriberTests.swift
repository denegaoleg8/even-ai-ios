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
    private static let propagationDelay: Duration = .milliseconds(100)

    private func makeService(
        factory: FakeRealtimeTranscriptionSocketFactory,
        spy: SpyGlassesTransport,
        store: AgentContextStore,
        languageCodes: [String: String?],
        translation: String = "переклад",
        maxConsecutiveReconnectAttempts: Int = 5,
        reconnectBackoffSchedule: [Duration] = [.zero, .milliseconds(20), .milliseconds(20), .milliseconds(20), .milliseconds(20)]
    ) -> LiveTranslationService {
        LiveTranslationService(
            glassesTransport: spy,
            transcriber: OpenAIRealtimeTranscriber(
                makeSocket: { await factory.makeSocket() },
                maxConsecutiveReconnectAttempts: maxConsecutiveReconnectAttempts,
                reconnectBackoffSchedule: reconnectBackoffSchedule
            ),
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
        // Each turn after the first now also carries one bounded page of
        // look-back context (the immediately preceding turn) — see
        // GlassesPresentationLayer.conversationPages(for:previousTurn:).
        #expect(await spy.displayedPageSets == [
            ["Good morning\n\nUA: переклад"],
            ["Guten Tag\n\nUA: переклад", "Previous:\nGood morning\n\nUA: переклад"],
            ["Dzień dobry\n\nUA: переклад", "Previous:\nGuten Tag\n\nUA: переклад"],
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

    /// The bounded reconnect budget (Conversation Mode hardening
    /// follow-up — physical-device "Live Translation stopped
    /// unexpectedly" investigation) means a session survives MORE than
    /// one consecutive drop now — this test uses a small, explicit
    /// budget (2 attempts) so exhausting it stays fast and precise: a
    /// budget of N attempts needs N+1 total drops to exhaust (each
    /// attempt reconnects successfully before being dropped again).
    @Test("once the bounded reconnect budget is fully exhausted, the live session ends cleanly — no retry storm")
    func exhaustedReconnectBudgetEndsSessionCleanly() async throws {
        let factory = FakeRealtimeTranscriptionSocketFactory()
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let service = makeService(
            factory: factory, spy: spy, store: store,
            languageCodes: [:],
            maxConsecutiveReconnectAttempts: 2,
            reconnectBackoffSchedule: [.zero, .zero]
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        await (await factory.createdSockets[0]).emit(.closed(reason: "drop 1"))
        try? await Task.sleep(for: Self.propagationDelay)
        await (await factory.createdSockets[1]).emit(.closed(reason: "drop 2"))
        try? await Task.sleep(for: Self.propagationDelay)
        await (await factory.createdSockets[2]).emit(.closed(reason: "drop 3"))
        try? await Task.sleep(for: Self.propagationDelay)

        // Ends cleanly (LiveTranslationService's existing "stream errored"
        // path: state -> .error, terminateSession disables the mic) —
        // no fourth connection ever attempted once the budget of 2
        // reconnect attempts is exhausted, i.e. no retry storm.
        #expect(await factory.createdSockets.count == 3)
        guard case .error = service.state else {
            Issue.record("expected .error, got \(service.state)")
            return
        }
        #expect(await spy.microphoneEnabledCalls == [true, false])
    }

    /// The core regression guard for the physical-device symptom: two
    /// consecutive drops — very plausible on a real G2-BLE↔phone↔
    /// backend↔OpenAI chain — must NOT end the session under the new
    /// bounded-with-backoff policy (the OLD single-retry policy would
    /// already have failed this).
    @Test("two consecutive drops survive within the reconnect budget — the session never sees 'stopped unexpectedly' for just two blips")
    func twoConsecutiveDropsSurviveWithinBudget() async throws {
        let factory = FakeRealtimeTranscriptionSocketFactory()
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let service = makeService(
            factory: factory, spy: spy, store: store,
            languageCodes: ["recovered phrase": "en"],
            maxConsecutiveReconnectAttempts: 5,
            reconnectBackoffSchedule: [.zero, .zero, .zero, .zero, .zero]
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        await (await factory.createdSockets[0]).emit(.closed(reason: "drop 1"))
        try? await Task.sleep(for: Self.propagationDelay)
        await (await factory.createdSockets[1]).emit(.closed(reason: "drop 2"))
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(service.state == .listening) // still alive after 2 drops
        #expect(await factory.createdSockets.count == 3)

        await (await factory.createdSockets[2]).emit(.finalTranscript("recovered phrase"))
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(store.session.turns.map(\.originalText) == ["recovered phrase"])
        #expect(service.state == .listening)
    }
}
