import Testing
import Foundation
@testable import EvenAI

/// PHASE 3 — Slice 4: the enriching decorator wired into the **real**
/// `AIConversationEngine`, proving it is transparent to the engine's existing
/// translation-first / stale-turn / continuous-listening guarantees.
///
/// No engine change is exercised here — the decorator is injected through the
/// same `replyGenerator:` parameter every other test uses.
@MainActor
@Suite("Phase 3: G2 reply enrichment — engine integration")
struct PersonalAIG2ReplyEnrichmentEngineIntegrationTests {

    private static let propagationDelay: Duration = .milliseconds(120)

    private func header(_ original: String, _ translation: String) -> String { "\(original)\n\nUA: \(translation)" }

    private func enrich(
        _ base: any SuggestedReplyGenerating,
        builder: any PersonalAIContextBuilding = ScriptedContextBuilder(result: ScriptedContextBuilder.personalised()),
        config: PersonalAIReplyEnrichmentConfig = .default
    ) -> PersonalAIContextEnrichingSuggestedReplyGenerator {
        PersonalAIContextEnrichingSuggestedReplyGenerator(
            base: base, contextBuilder: builder, ownerID: { "owner-A" },
            conversationProfile: { .conversation }, config: config
        )
    }

    // MARK: invariant 24 — translation never waits for Personal AI

    @Test("translation displays immediately even when reply enrichment + generation never complete")
    func translationNeverWaitsForEnrichment() async throws {
        // base never returns; context builder hangs 10 s.
        let gated = GatedSuggestedReplyGenerator()
        let stuckBuilder = ScriptedContextBuilder(result: ScriptedContextBuilder.personalised(), delay: .seconds(10))
        let spy = SpyGlassesTransport()
        let service = AIConversationEngine(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["Guten Tag"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["Guten Tag": "de"], translation: "Добрий день"),
            agentContextStore: AgentContextStore(),
            replyGenerator: enrich(gated, builder: stuckBuilder)
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(await spy.displayedPageSets == [[header("Guten Tag", "Добрий день")]])   // translation shown, no reply
    }

    @Test("a hung context builder times out; the base local replies still reach G2")
    func hungBuilderFallsBackToBaseReplies() async throws {
        let base = FakeSuggestedReplyGenerator(defaultReplies: [
            SuggestedReply(originalLanguageText: "Hello!", ukrainianText: "Привіт!", ordering: 0),
        ])
        let stuck = ScriptedContextBuilder(result: ScriptedContextBuilder.personalised(), delay: .seconds(30))
        let fastTimeout = PersonalAIReplyEnrichmentConfig(
            contextTokenBudget: 700, enrichmentTimeout: .milliseconds(40), surface: .g2Replies, maxRecentConversationLines: 4
        )
        let spy = SpyGlassesTransport()
        let service = AIConversationEngine(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["Guten Tag"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["Guten Tag": "de"], translation: "Добрий день"),
            agentContextStore: AgentContextStore(),
            replyGenerator: enrich(base, builder: stuck, config: fastTimeout)
        )

        await service.start()
        try? await Task.sleep(for: .milliseconds(400))

        let sets = await spy.displayedPageSets
        #expect(sets.count == 2)                                     // header, then header+reply
        #expect(sets.last?.contains { $0.contains("Hello!") } == true)
    }

    // MARK: invariant 25 — the engine's stale-turn gate is untouched

    @Test("a stale, late-arriving ENRICHED reply never overwrites a newer turn (engine sequence gate still governs)")
    func staleEnrichedReplyNeverOverwrites() async throws {
        let gated = GatedSuggestedReplyGenerator(repliesByOriginalText: [
            "first phrase": [SuggestedReply(originalLanguageText: "A-reply", ukrainianText: "А", ordering: 0)],
            "second phrase": [SuggestedReply(originalLanguageText: "B-reply", ukrainianText: "Б", ordering: 0)],
        ])
        let spy = SpyGlassesTransport()
        let service = AIConversationEngine(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["first phrase", "second phrase"]),
            translator: ScriptedLanguageTranslator(
                languageCodes: ["first phrase": "en", "second phrase": "en"], translation: "переклад"
            ),
            agentContextStore: AgentContextStore(),
            replyGenerator: enrich(gated)     // decorator wraps the gated base
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)
        #expect(await spy.displayedPageSets.count == 2)              // both translations, replies gated

        await gated.release("second phrase")
        try? await Task.sleep(for: Self.propagationDelay)
        #expect(await spy.displayedPageSets.count == 3)             // newer turn's reply shown

        await gated.release("first phrase")
        try? await Task.sleep(for: Self.propagationDelay)
        let final = await spy.displayedPageSets
        #expect(final.count == 3)                                   // stale enriched reply discarded — NO 4th call
        #expect(final.last?.contains { $0.contains("B-reply") } == true)
    }

    // MARK: invariant 26 — continuous listening unaffected

    @Test("continuous listening keeps finalizing turns while enrichment is in flight")
    func listeningContinuesDuringEnrichment() async throws {
        let base = FakeSuggestedReplyGenerator(defaultReplies: [])
        let slow = ScriptedContextBuilder(result: ScriptedContextBuilder.personalised(), delay: .milliseconds(200))
        let store = AgentContextStore()
        let service = AIConversationEngine(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: ["one", "two", "three"]),
            translator: ScriptedLanguageTranslator(
                languageCodes: ["one": "en", "two": "en", "three": "en"], translation: "переклад"
            ),
            agentContextStore: store,
            replyGenerator: enrich(base, builder: slow)
        )

        await service.start()
        try? await Task.sleep(for: .milliseconds(500))

        // all three utterances finalized as turns despite enrichment lagging
        #expect(store.session.turns.count == 3)
        #expect(Set(store.session.turns.map(\.originalText)) == ["one", "two", "three"])
    }
}
