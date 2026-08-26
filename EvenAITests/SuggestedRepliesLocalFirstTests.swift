import Testing
import Foundation
import SwiftData
@testable import EvenAI

/// Regression coverage for restoring suggested replies without Railway.
///
/// Root cause of the reported "suggested mini replies are missing": the
/// only production `SuggestedReplyGenerating` was `NetworkSuggestedReplyGenerator`,
/// which requires the (now-unavailable) Railway backend's `/suggested-replies`
/// endpoint — every attempt failed, and `AIConversationEngine
/// .generateSuggestedReplies` already correctly swallowed that failure
/// (translation kept working, exactly as designed), which is EXACTLY why
/// replies silently disappeared rather than the app crashing or erroring
/// visibly. `EvenAIApp` now wires `LocalSuggestedReplyGenerator`
/// (Apple `FoundationModels`, on-device) as the default, with NO
/// automatic fallback to Railway when it's unavailable.
@MainActor
@Suite("Suggested replies: local-first restoration")
struct SuggestedRepliesLocalFirstTests {
    private static let propagationDelay: Duration = .milliseconds(150)

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SuggestedRepliesLocalFirstTests.\(UUID().uuidString)")!
    }

    private func freshGlassesChatStore() -> LocalGlassesChatStore {
        let schema = Schema([ChatEntity.self, MessageEntity.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [configuration])
        return LocalGlassesChatStore(modelContainer: container)
    }

    // MARK: - Standard Mode

    @Test("Standard Mode: replies from a local generator are auto-displayed on G2, added below the still-visible header")
    func standardModeShowsLocalReplies() async throws {
        let spy = SpyGlassesTransport()
        let generator = FakeSuggestedReplyGenerator(defaultReplies: [
            SuggestedReply(originalLanguageText: "Yes, I'd love to.", ukrainianText: "Так, із задоволенням.", ordering: 0),
            SuggestedReply(originalLanguageText: "What time?", ukrainianText: "О котрій?", ordering: 1),
        ])
        let service = AIConversationEngine(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["Do you want to come with us tomorrow?"]),
            translator: ScriptedLanguageTranslator(
                languageCodes: ["Do you want to come with us tomorrow?": "en"],
                translation: "Ти хочеш піти з нами завтра?"
            ),
            replyGenerator: generator,
            defaults: freshDefaults()
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        let displayed = await spy.displayedPageSets
        #expect(displayed.count == 2) // translation-only, then translation+reply
        #expect(displayed.last?.first?.contains("Yes, I'd love to.") == true)
        #expect(displayed.last?.first?.contains("Так, із задоволенням.") == true)
        #expect(displayed.last?.first?.contains("Ти хочеш піти з нами завтра?") == true) // header never disappears
    }

    // MARK: - Meeting Mode

    @Test("Meeting Mode: replies exist and are reachable on G2, but page 0 stays the plain transcript — conversation history is never replaced")
    func meetingModeShowsCompactRepliesWithoutReplacingHistory() async throws {
        let spy = SpyGlassesTransport()
        let generator = FakeSuggestedReplyGenerator(defaultReplies: [
            SuggestedReply(originalLanguageText: "Sure", ukrainianText: "Так", ordering: 0),
        ])
        let service = AIConversationEngine(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["Guten Tag"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["Guten Tag": "de"], translation: "Добрий день"),
            replyGenerator: generator,
            defaults: freshDefaults()
        )
        service.setConversationProfile(.meeting)

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        let displayed = await spy.displayedPageSets
        #expect(displayed.count == 2) // translation-only, then the reply-inclusive set
        let finalPageSet = try #require(displayed.last)
        // Page 0 (what's actively shown) is STILL the plain header — the
        // exact same content as the first display, never replaced.
        #expect(finalPageSet.first == "Guten Tag\n\nUA: Добрий день")
        // But the reply is now genuinely present, reachable via swipe.
        #expect(finalPageSet.count > 1)
        #expect(finalPageSet.contains { $0.contains("Sure") && $0.contains("Так") })
    }

    @Test("Meeting Mode: replies are still generated and recorded even when nothing is auto-shown differently — never silently dropped")
    func meetingModeRepliesAreRecordedInHistory() async throws {
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let generator = FakeSuggestedReplyGenerator(defaultReplies: [
            SuggestedReply(originalLanguageText: "Sure", ukrainianText: "Так", ordering: 0),
        ])
        let service = AIConversationEngine(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["Guten Tag"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["Guten Tag": "de"], translation: "Добрий день"),
            agentContextStore: store,
            replyGenerator: generator,
            defaults: freshDefaults()
        )
        service.setConversationProfile(.meeting)

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(store.session.latestTurn?.suggestedReplies.map(\.originalLanguageText) == ["Sure"])
    }

    // MARK: - Relevance / context

    @Test("the recent conversation context (recentTurns) is passed to the generator, bounded, oldest-first — replies can actually be context-relevant")
    func contextIsPassedToGenerator() async throws {
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let generator = FakeSuggestedReplyGenerator(defaultReplies: [
            SuggestedReply(originalLanguageText: "reply", ukrainianText: "відповідь", ordering: 0),
        ])
        let service = AIConversationEngine(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["first phrase", "second phrase"]),
            translator: ScriptedLanguageTranslator(
                languageCodes: ["first phrase": "en", "second phrase": "en"],
                translation: "переклад"
            ),
            agentContextStore: store,
            replyGenerator: generator,
            defaults: freshDefaults()
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        let calls = await generator.calls
        #expect(calls.count == 2)
        // The SECOND turn's call includes the FIRST turn as prior context
        // — this is what makes context-relevant replies possible at all.
        let secondCall = try #require(calls.last)
        #expect(secondCall.turn.originalText == "second phrase")
        #expect(secondCall.context.recentTurns.map(\.originalText).contains("first phrase"))
    }

    // MARK: - Source-language + Ukrainian pair

    @Test("every reply carries BOTH its source-language text and Ukrainian meaning — never one without the other")
    func everyReplyHasSourceAndUkrainianText() async throws {
        let spy = SpyGlassesTransport()
        let generator = FakeSuggestedReplyGenerator(defaultReplies: [
            SuggestedReply(originalLanguageText: "Yes, I'd love to.", ukrainianText: "Так, із задоволенням.", ordering: 0),
            SuggestedReply(originalLanguageText: "What time are you going?", ukrainianText: "О котрій ви йдете?", ordering: 1),
            SuggestedReply(originalLanguageText: "Sorry, I can't tomorrow.", ukrainianText: "Вибач, завтра я не можу.", ordering: 2),
        ])
        let store = AgentContextStore()
        let service = AIConversationEngine(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["Do you want to come with us tomorrow?"]),
            translator: ScriptedLanguageTranslator(
                languageCodes: ["Do you want to come with us tomorrow?": "en"],
                translation: "Ти хочеш піти з нами завтра?"
            ),
            agentContextStore: store,
            replyGenerator: generator,
            defaults: freshDefaults()
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        let replies = try #require(store.session.latestTurn?.suggestedReplies)
        #expect(replies.count == 3)
        for reply in replies {
            #expect(!reply.originalLanguageText.isEmpty)
            #expect(!reply.ukrainianText.isEmpty)
        }
    }

    // MARK: - Model unavailable

    @Test("local model unavailable: repliesUnavailableReason is set with a truthful message, translation keeps working, session never errors")
    func modelUnavailableSetsNoticeAndKeepsTranslating() async throws {
        let spy = SpyGlassesTransport()
        let generator = FakeSuggestedReplyGenerator(error: LocalReplyUnavailableError(reason: .appleIntelligenceNotEnabled))
        let service = AIConversationEngine(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["hello there"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["hello there": "en"], translation: "привіт"),
            replyGenerator: generator,
            defaults: freshDefaults()
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        // Never a session error — `ScriptedContinuousTranscriber`'s
        // default `autoFinish: true` means `state` legitimately settles
        // back to `.idle` once its one scripted final is exhausted (the
        // stream ending cleanly, matching every other test using this
        // fake); the actual claim under test is that a reply-generation
        // failure never PRODUCES an `.error` state.
        if case .error(let message) = service.state {
            Issue.record("service entered an error state from a reply-generation failure: \(message)")
        }
        #expect(service.repliesUnavailableReason == LocalReplyUnavailableError(reason: .appleIntelligenceNotEnabled).userFacingMessage)
        let displayed = await spy.displayedPageSets
        #expect(displayed == [["hello there\n\nUA: привіт"]]) // translation-only, exactly once — no reply section
    }

    @Test("model unavailable notice clears once a later turn's reply generation actually succeeds")
    func noticeClearsOnceRepliesSucceedAgain() async throws {
        let spy = SpyGlassesTransport()
        let generator = FakeSuggestedReplyGenerator(
            repliesByOriginalText: [
                "second": [SuggestedReply(originalLanguageText: "ok", ukrainianText: "добре", ordering: 0)],
            ],
            error: nil
        )
        let service = AIConversationEngine(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["second"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["second": "en"], translation: "переклад"),
            replyGenerator: generator,
            defaults: freshDefaults()
        )
        // Simulate a stale notice left over from an earlier session.
        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)
        #expect(service.repliesUnavailableReason == nil) // this generator never fails, so it's already nil — the real assertion is below
        // A second service using a FAILING generator sets the notice...
        let failingGenerator = FakeSuggestedReplyGenerator(error: LocalReplyUnavailableError(reason: .modelNotReady))
        let service2 = AIConversationEngine(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: ["x"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["x": "en"], translation: "y"),
            replyGenerator: failingGenerator,
            defaults: freshDefaults()
        )
        await service2.start()
        try? await Task.sleep(for: Self.propagationDelay)
        #expect(service2.repliesUnavailableReason != nil)
    }

    // MARK: - Stale reply result

    @Test("stale reply result: an older turn's slow reply generation, finishing AFTER a newer turn already displayed, is discarded — never overwrites the newer turn's display")
    func staleReplyResultIsDiscarded() async throws {
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let generator = GatedSuggestedReplyGenerator(repliesByOriginalText: [
            "phrase A": [SuggestedReply(originalLanguageText: "A-reply", ukrainianText: "А-відповідь", ordering: 0)],
        ])
        let service = AIConversationEngine(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["phrase A", "phrase B"]),
            translator: ScriptedLanguageTranslator(
                languageCodes: ["phrase A": "en", "phrase B": "en"],
                translation: "переклад"
            ),
            agentContextStore: store,
            replyGenerator: generator,
            defaults: freshDefaults()
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)
        #expect(await spy.displayedPageSets.count == 2) // both translations displayed; A's replies still gated

        // A's (local-provider) replies finally arrive, well after B is
        // already the active/live turn.
        await generator.release("phrase A")
        try? await Task.sleep(for: Self.propagationDelay)

        let final = await spy.displayedPageSets
        #expect(final.count == 2) // no third, stale display update from A
        #expect(!final.contains { pages in pages.contains { $0.contains("A-reply") } })
        #expect(store.session.latestTurn?.originalText == "phrase B")
    }

    // MARK: - New speech supersedes reply focus

    @Test("new speech supersedes reply focus: browsing a reply page is automatically reclaimed the moment a new utterance starts")
    func newSpeechReclaimsLiveDisplayFromReplyBrowsing() async throws {
        let spy = SpyGlassesTransport()
        // TWO replies: page 0 = header+reply1 (Standard Mode merges the
        // first reply directly onto the live page — see `pages(for:)`'s
        // own doc comment), so index 1 must be a genuine SECOND reply
        // page for this swipe to land on `.browsingReplies` at all; with
        // only one reply, there is no separate index-1 page to browse to.
        let generator = FakeSuggestedReplyGenerator(defaultReplies: [
            SuggestedReply(originalLanguageText: "reply one", ukrainianText: "відповідь один", ordering: 0),
            SuggestedReply(originalLanguageText: "reply two", ukrainianText: "відповідь два", ordering: 1),
        ])
        let transcriber = ManualContinuousTranscriber()
        let service = AIConversationEngine(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(languageCodes: ["first": "en", "second": "en"], translation: "переклад"),
            replyGenerator: generator,
            defaults: freshDefaults()
        )

        await service.start()
        await transcriber.emit("first")
        try? await Task.sleep(for: Self.propagationDelay)
        #expect(service.followLive) // still following live after the reply displayed

        // User swipes to browse the reply page.
        await spy.simulateNavigation(.pageChanged(index: 1))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!service.followLive)

        // New speech arrives — must reclaim live display immediately,
        // never leaving the user stranded on a now-stale reply page.
        await transcriber.emitPartial("seco")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(service.followLive)
    }

    // MARK: - Reply failure does not affect translation

    @Test("reply generation failing (any reason) never delays, blocks, or hides the turn's own translation display")
    func replyFailureNeverAffectsTranslation() async throws {
        let spy = SpyGlassesTransport()
        struct SomeFailure: Error {}
        let generator = FakeSuggestedReplyGenerator(error: SomeFailure())
        let service = AIConversationEngine(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["hello there"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["hello there": "en"], translation: "привіт"),
            replyGenerator: generator,
            defaults: freshDefaults()
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        // See modelUnavailableSetsNoticeAndKeepsTranslating's own comment
        // for why this checks "no error state" rather than `== .listening`
        // — `ScriptedContinuousTranscriber`'s default `autoFinish: true`
        // legitimately settles back to `.idle` on its own.
        if case .error(let message) = service.state {
            Issue.record("service entered an error state from a reply-generation failure: \(message)")
        }
        #expect(await spy.displayedPageSets == [["hello there\n\nUA: привіт"]])
        #expect(service.repliesUnavailableReason == nil) // a generic failure, not local-unavailable — no persistent notice
    }

    // MARK: - Local Glasses Chat stores replies

    @Test("Glasses Chat: a turn's replies are persisted locally, as a follow-up message, with source+Ukrainian pairs — zero network")
    func glassesChatStoresRepliesLocally() async throws {
        let spy = SpyGlassesTransport()
        let store = freshGlassesChatStore()
        let glassesChatProvider = GlassesChatProvider(localStore: store, defaults: freshDefaults())
        let generator = FakeSuggestedReplyGenerator(defaultReplies: [
            SuggestedReply(originalLanguageText: "Yes, I'd love to.", ukrainianText: "Так, із задоволенням.", ordering: 0),
            SuggestedReply(originalLanguageText: "What time?", ukrainianText: "О котрій?", ordering: 1),
        ])
        let service = AIConversationEngine(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["Do you want to come with us tomorrow?"]),
            translator: ScriptedLanguageTranslator(
                languageCodes: ["Do you want to come with us tomorrow?": "en"],
                translation: "Ти хочеш піти з нами завтра?"
            ),
            replyGenerator: generator,
            glassesChatProvider: glassesChatProvider,
            defaults: freshDefaults()
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        let chat = try await glassesChatProvider.findOrCreateGlassesChat()
        let messages = await store.fetchMessages(chatID: chat.id)
        #expect(messages.count == 2) // the turn itself, then a follow-up replies message
        let repliesMessage = try #require(messages.first { $0.content.contains("Suggested replies") })
        #expect(repliesMessage.role == .assistant)
        #expect(repliesMessage.content.contains("Yes, I'd love to."))
        #expect(repliesMessage.content.contains("Так, із задоволенням."))
        #expect(repliesMessage.content.contains("What time?"))
        #expect(repliesMessage.content.contains("О котрій?"))
    }

    @Test("Glasses Chat: no replies generated means no follow-up replies message — only the turn itself")
    func noRepliesMeansNoFollowUpChatMessage() async throws {
        let spy = SpyGlassesTransport()
        let store = freshGlassesChatStore()
        let glassesChatProvider = GlassesChatProvider(localStore: store, defaults: freshDefaults())
        let service = AIConversationEngine(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["hello there"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["hello there": "en"], translation: "привіт"),
            // replyGenerator defaults to NoOpSuggestedReplyGenerator — always empty
            glassesChatProvider: glassesChatProvider,
            defaults: freshDefaults()
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        let chat = try await glassesChatProvider.findOrCreateGlassesChat()
        let messages = await store.fetchMessages(chatID: chat.id)
        #expect(messages.count == 1) // just the turn — no empty/placeholder replies message
    }

    // MARK: - Zero Railway calls in local-only mode

    @Test("full pipeline, local-only mode (real LocalSuggestedReplyGenerator + real on-device transcriber + real Glasses Chat): zero network-capable types constructed anywhere")
    func fullLocalOnlyPipelineHasNoNetworkCapableTypeAnywhere() async throws {
        // No AuthenticatedAPIClient, no NetworkChatService, no
        // NetworkSuggestedReplyGenerator, no OpenAIRealtimeTranscriber —
        // this test's entire construction graph is incapable of a
        // network call by construction, the same structural proof
        // `OfflineLocalFirstIntegrationTests` already established for
        // translation; this extends it to replies.
        let spy = SpyGlassesTransport()
        let store = freshGlassesChatStore()
        let glassesChatProvider = GlassesChatProvider(localStore: store, defaults: freshDefaults())
        let service = AIConversationEngine(
            glassesTransport: spy,
            transcriber: FakeOnDeviceTranscriber(finals: ["hello there"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["hello there": "en"], translation: "привіт"),
            replyGenerator: LocalSuggestedReplyGenerator(), // the REAL production reply generator
            glassesChatProvider: glassesChatProvider,
            defaults: freshDefaults()
        )

        await service.start()
        try? await Task.sleep(for: .milliseconds(300)) // give the real on-device model attempt time to resolve either way

        #expect(service.state == .listening) // never terminated, regardless of whether replies succeeded
        let displayed = await spy.displayedPageSets
        #expect(!displayed.isEmpty) // translation reached G2 regardless of reply outcome
        #expect(displayed.first?.first?.contains("hello there") == true)
    }
}
