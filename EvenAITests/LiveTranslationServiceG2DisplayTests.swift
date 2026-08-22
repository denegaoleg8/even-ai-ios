import Testing
import Foundation
@testable import EvenAI

/// Milestone 6: `LiveTranslationService`'s integration with
/// `GlassesTransport.displayPages(_:)` and `GlassesPresentationLayer` —
/// no real STT/Azure/OpenAI, no real `SuggestedReplyGenerator`. Covers
/// exactly the sequencing/safety behavior this milestone adds on top of
/// Milestones 2-5, which stay covered by their own test files.
@MainActor
@Suite("LiveTranslationService + G2 display (GlassesPresentationLayer)")
struct LiveTranslationServiceG2DisplayTests {
    private static let propagationDelay: Duration = .milliseconds(30)

    private static func reply(_ original: String, _ ukrainian: String, ordering: Int) -> SuggestedReply {
        SuggestedReply(originalLanguageText: original, ukrainianText: ukrainian, ordering: ordering)
    }

    @Test("the translation is displayed immediately, without waiting for reply generation")
    func translationAppearsImmediately() async throws {
        // Never released — if the translation depended on this
        // completing, `displayedPageSets` would stay empty forever.
        let generator = GatedSuggestedReplyGenerator()
        let spy = SpyGlassesTransport()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["Guten Tag"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["Guten Tag": "de"], translation: "Добрий день"),
            agentContextStore: AgentContextStore(),
            replyGenerator: generator
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(await spy.displayedPageSets == [["Добрий день"]])
    }

    @Test("suggested replies update G2's display once generation completes")
    func repliesUpdateDisplayAfterArrival() async throws {
        let replies = [Self.reply("Sure", "Так", ordering: 0)]
        let generator = FakeSuggestedReplyGenerator(defaultReplies: replies)
        let spy = SpyGlassesTransport()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["Guten Tag"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["Guten Tag": "de"], translation: "Добрий день"),
            agentContextStore: AgentContextStore(),
            replyGenerator: generator
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        let calls = await spy.displayedPageSets
        #expect(calls.count == 2)
        #expect(calls[0] == ["Добрий день"])

        let expectedTurn = ConversationTurn.liveConversationTurn(
            originalText: "Guten Tag",
            detectedLanguage: "de",
            ukrainianTranslation: "Добрий день",
            suggestedReplies: replies
        )
        #expect(calls[1] == GlassesPresentationLayer.pages(for: expectedTurn))
    }

    @Test("the reply update replaces G2's page set — it never duplicates or appends a redundant third call")
    func replyUpdateDoesNotDuplicatePages() async throws {
        let replies = [Self.reply("Sure", "Так", ordering: 0), Self.reply("Thursday", "Четвер", ordering: 1)]
        let generator = FakeSuggestedReplyGenerator(defaultReplies: replies)
        let spy = SpyGlassesTransport()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["Guten Tag"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["Guten Tag": "de"], translation: "Добрий день"),
            agentContextStore: AgentContextStore(),
            replyGenerator: generator
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        let calls = await spy.displayedPageSets
        // Exactly two calls total: translation-only, then translation+replies —
        // never a third call, and the second call is one coherent page
        // set, not the reply pages appended as a separate display.
        #expect(calls.count == 2)
        #expect(calls[1].first == "Добрий день")
        #expect(calls[1].dropFirst().contains { $0.contains("Sure") })
    }

    @Test("newest finalized turn always becomes the active G2 content — a stale, late-arriving reply never overwrites it")
    func newestTurnReplacesOlderActiveContent() async throws {
        let generator = GatedSuggestedReplyGenerator(repliesByOriginalText: [
            "first phrase": [Self.reply("A-reply", "А-відповідь", ordering: 0)],
            "second phrase": [Self.reply("B-reply", "Б-відповідь", ordering: 0)],
        ])
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["first phrase", "second phrase"]),
            translator: ScriptedLanguageTranslator(
                languageCodes: ["first phrase": "en", "second phrase": "en"],
                translation: "переклад"
            ),
            agentContextStore: store,
            replyGenerator: generator
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)
        #expect(await spy.displayedPageSets.count == 2) // both translations, both replies still gated

        // Release the newer turn's replies first.
        await generator.release("second phrase")
        try? await Task.sleep(for: Self.propagationDelay)
        #expect(await spy.displayedPageSets.count == 3)

        // Now release the OLDER, now-stale turn's replies.
        await generator.release("first phrase")
        try? await Task.sleep(for: Self.propagationDelay)

        let final = await spy.displayedPageSets
        #expect(final.count == 3) // no fourth call — the stale update was skipped
        #expect(final.last?.contains { $0.contains("B-reply") } == true)
        #expect(!final.contains { pages in pages.contains { $0.contains("A-reply") } })
    }

    @Test("rapid successive turns leave only the newest turn's content active, regardless of reply-generation completion order")
    func rapidSuccessiveTurnsLeaveOnlyNewestActive() async throws {
        let generator = GatedSuggestedReplyGenerator(repliesByOriginalText: [
            "one": [Self.reply("R1", "В1", ordering: 0)],
            "two": [Self.reply("R2", "В2", ordering: 0)],
            "three": [Self.reply("R3", "В3", ordering: 0)],
        ])
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["one", "two", "three"]),
            translator: ScriptedLanguageTranslator(
                languageCodes: ["one": "en", "two": "en", "three": "en"],
                translation: "переклад"
            ),
            agentContextStore: store,
            replyGenerator: generator
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)
        #expect(await spy.displayedPageSets.count == 3) // three translations, all replies still gated

        // Release out of order — oldest first — to prove completion
        // order doesn't matter, only recency of the turn itself.
        await generator.release("one")
        try? await Task.sleep(for: Self.propagationDelay)
        await generator.release("two")
        try? await Task.sleep(for: Self.propagationDelay)
        await generator.release("three")
        try? await Task.sleep(for: Self.propagationDelay)

        let calls = await spy.displayedPageSets
        #expect(calls.count == 4) // 3 translations + exactly one reply update, for "three"
        #expect(calls.last?.contains { $0.contains("R3") } == true)
        #expect(!calls.contains { pages in pages.contains { $0.contains("R1") } })
        #expect(!calls.contains { pages in pages.contains { $0.contains("R2") } })
        #expect(store.session.latestTurn?.originalText == "three")
    }

    @Test("existing plain sendText behavior is untouched by displayPages")
    func existingSendTextBehaviorRemainsUnchanged() async throws {
        let spy = SpyGlassesTransport()
        try await spy.sendText("hello")

        #expect(await spy.sentTexts == ["hello"])
        #expect(await spy.displayedPageSets.isEmpty)
    }

    @Test("when the generator returns no replies, G2's display stays translation-only — no redundant second call")
    func emptySuggestedRepliesLeavesTranslationOnlyDisplay() async throws {
        let generator = FakeSuggestedReplyGenerator() // defaultReplies: []
        let spy = SpyGlassesTransport()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["Guten Tag"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["Guten Tag": "de"], translation: "Добрий день"),
            agentContextStore: AgentContextStore(),
            replyGenerator: generator
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(await spy.displayedPageSets == [["Добрий день"]])
    }

    @Test("Ukrainian speech produces no G2 display update at all")
    func ukrainianTurnProducesNoDisplayUpdate() async throws {
        let generator = FakeSuggestedReplyGenerator()
        let spy = SpyGlassesTransport()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["привіт, як справи"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["привіт, як справи": "uk"]),
            agentContextStore: AgentContextStore(),
            replyGenerator: generator
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(await spy.displayedPageSets.isEmpty)
    }

    @Test("stopping cancels in-flight reply generation — a late completion never updates G2's display after stop")
    func stopPreventsStaleDisplayUpdate() async throws {
        let generator = GatedSuggestedReplyGenerator(repliesByOriginalText: [
            "Guten Tag": [Self.reply("Sure", "Так", ordering: 0)],
        ])
        let spy = SpyGlassesTransport()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["Guten Tag"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["Guten Tag": "de"], translation: "Добрий день"),
            agentContextStore: AgentContextStore(),
            replyGenerator: generator
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)
        #expect(await spy.displayedPageSets == [["Добрий день"]])

        await service.stop()
        try? await Task.sleep(for: Self.propagationDelay)

        // Release the now-cancelled reply generation — must not add a
        // second displayPages call after stop().
        await generator.release("Guten Tag")
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(await spy.displayedPageSets == [["Добрий день"]])
    }
}
