import Testing
import Foundation
@testable import EvenAI

/// Milestone 2: `LiveTranslationService`'s minimal integration with the
/// shared `AgentContextSession` — entirely additive to the existing
/// decision pipeline covered by `LiveTranslationServiceTests`, which is
/// untouched. These tests prove: a foreign phrase is recorded as exactly
/// one turn, Ukrainian speech never becomes a turn, the existing
/// `GlassesTransport.sendText(_:)` call is unaffected by this recording,
/// redundant/no-op lifecycle calls never duplicate a turn, and the
/// `AgentContextStore` instance passed in really is shared by identity —
/// what "visible through the app environment" means outside of a SwiftUI
/// hosting context.
@MainActor
@Suite("LiveTranslationService + AgentContextStore")
struct LiveTranslationServiceAgentContextTests {
    private static let propagationDelay: Duration = .milliseconds(30)

    @Test("a finalized foreign-language phrase is appended to the shared session exactly once")
    func foreignPhraseIsAppendedOnce() async throws {
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: ["hello there"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["hello there": "en"], translation: "привіт"),
            agentContextStore: store
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(store.session.turns.count == 1)
        let turn = try #require(store.session.latestTurn)
        #expect(turn.originalText == "hello there")
        #expect(turn.detectedLanguage == "en")
        #expect(turn.ukrainianTranslation == "привіт")
        #expect(turn.source == .liveConversation)
        #expect(turn.suggestedReplies.isEmpty)
    }

    @Test("Ukrainian speech never creates a live-conversation turn")
    func ukrainianSpeechDoesNotCreateATurn() async throws {
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: ["привіт, як справи"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["привіт, як справи": "uk"]),
            agentContextStore: store
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(store.session.turns.isEmpty)
    }

    @Test("recording a turn does not change what's sent to G2 — the existing sendText call is unaffected")
    func existingSendTextBehaviorIsUnchanged() async throws {
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["hello there"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["hello there": "en"], translation: "привіт"),
            agentContextStore: store
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        // Same assertion as `LiveTranslationServiceTests.foreignPhraseIsTranslatedAndSent`,
        // which uses no `AgentContextStore` at all — proves the new
        // recording is purely additive to the existing display path.
        // Milestone 6: the translation reaches G2 via `displayPages(_:)`,
        // not a direct `sendText(_:)` call.
        #expect(await spy.displayedPageSets == [["привіт"]])
        #expect(store.session.turns.count == 1)
    }

    @Test("a redundant start() call while already listening does not duplicate the current turn")
    func redundantStartDoesNotDuplicateTurns() async throws {
        let store = AgentContextStore()
        let transcriber = ScriptedContinuousTranscriber(finals: ["hello there"], autoFinish: false)
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(languageCodes: ["hello there": "en"], translation: "привіт"),
            agentContextStore: store
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)
        #expect(store.session.turns.count == 1)

        // Already `.listening` — start()'s own early-return guard means
        // this must be a complete no-op.
        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(store.session.turns.count == 1)
    }

    @Test("repeated start/stop lifecycle transitions alone never append a turn")
    func lifecycleTransitionsAloneNeverAppendATurn() async throws {
        // A transcriber that never yields any final phrase — isolates
        // "does starting/stopping itself add a turn" from "does a real
        // phrase get recorded," which the other tests in this file
        // already cover individually.
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: []),
            translator: ScriptedLanguageTranslator(languageCodes: [:]),
            agentContextStore: store
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)
        #expect(store.session.turns.isEmpty)

        await service.stop()
        try? await Task.sleep(for: Self.propagationDelay)
        #expect(store.session.turns.isEmpty)

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)
        #expect(store.session.turns.isEmpty)

        await service.stop()
        try? await Task.sleep(for: Self.propagationDelay)
        #expect(store.session.turns.isEmpty)
    }

    @Test("the AgentContextStore instance passed to LiveTranslationService is shared by identity, not copied")
    func sameInstanceIsSharedByIdentity() async throws {
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: ["hello there"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["hello there": "en"], translation: "привіт"),
            agentContextStore: store
        )

        // `store` here stands in for the same instance `EvenAIApp` both
        // constructs `LiveTranslationService` with AND injects via
        // `.environment(agentContextStore)` — a mutation the service
        // makes must be visible through this exact external reference,
        // not a copy, for that to actually mean anything.
        #expect(store.session.turns.isEmpty)

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(store.session.turns.count == 1)
        #expect(store.session.latestTurn?.originalText == "hello there")
    }
}
