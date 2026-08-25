import Testing
import Foundation
@testable import EvenAI

/// Milestone 4: `LiveTranslationService`'s integration with
/// `SuggestedReplyGenerating` — entirely additive to the existing
/// decision pipeline and to Milestone 2/3's turn-recording behavior,
/// which stay covered by their own test files. No real AI provider is
/// involved anywhere here — only `FakeSuggestedReplyGenerator`.
@MainActor
@Suite("LiveTranslationService + SuggestedReplyGenerating")
struct LiveTranslationServiceSuggestedRepliesTests {
    private static let propagationDelay: Duration = .milliseconds(120)

    private static func reply(_ original: String, _ ukrainian: String, ordering: Int) -> SuggestedReply {
        SuggestedReply(originalLanguageText: original, ukrainianText: ukrainian, ordering: ordering)
    }

    @Test("a finalized foreign-language turn is sent to the reply generator")
    func foreignTurnGetsGenerationRequest() async throws {
        let generator = FakeSuggestedReplyGenerator()
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: ["Guten Tag"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["Guten Tag": "de"], translation: "Добрий день"),
            agentContextStore: store,
            replyGenerator: generator
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        let calls = await generator.calls
        #expect(calls.count == 1)
        #expect(calls.first?.turn.originalText == "Guten Tag")
        #expect(calls.first?.turn.detectedLanguage == "de")
        #expect(calls.first?.turn.ukrainianTranslation == "Добрий день")
    }

    @Test("Ukrainian speech is skipped — the generator is never called")
    func ukrainianTurnIsSkipped() async throws {
        let generator = FakeSuggestedReplyGenerator()
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: ["привіт, як справи"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["привіт, як справи": "uk"]),
            agentContextStore: store,
            replyGenerator: generator
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(await generator.calls.isEmpty)
        #expect(store.session.turns.isEmpty)
    }

    @Test("recent turns and shared context are passed to the generator")
    func contextIsPassedToGenerator() async throws {
        let generator = FakeSuggestedReplyGenerator()
        let store = AgentContextStore()
        store.addContext(ContextItem(kind: .note, text: "Business meeting tomorrow."))
        let priorTurn = ConversationTurn.liveConversationTurn(
            originalText: "earlier phrase",
            detectedLanguage: "de-DE",
            ukrainianTranslation: "раніша фраза"
        )
        store.appendTurn(priorTurn)

        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: ["Guten Tag"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["Guten Tag": "de"], translation: "Добрий день"),
            agentContextStore: store,
            replyGenerator: generator
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        let calls = await generator.calls
        let context = try #require(calls.first?.context)
        #expect(context.recentTurns == [priorTurn])
        #expect(context.contextItems.map(\.text) == ["Business meeting tomorrow."])
    }

    @Test("a successful generation attaches at most 3 replies to the turn, preserving order and Ukrainian text")
    func repliesAreCappedAtThreeAndOrderPreserved() async throws {
        let replies = [
            Self.reply("Sure, that works for me.", "Так, мені підходить.", ordering: 0),
            Self.reply("Could we do Thursday instead?", "Можемо натомість у четвер?", ordering: 1),
            Self.reply("Let me check and get back to you.", "Дай перевірю і скажу.", ordering: 2),
            Self.reply("A fourth option that should be dropped.", "Четвертий варіант, який має бути відкинутий.", ordering: 3),
        ]
        let generator = FakeSuggestedReplyGenerator(defaultReplies: replies)
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: ["Guten Tag"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["Guten Tag": "de"], translation: "Добрий день"),
            agentContextStore: store,
            replyGenerator: generator
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        let resultReplies = try #require(store.session.latestTurn).suggestedReplies
        #expect(resultReplies.count == 3)
        #expect(resultReplies.map(\.ordering) == [0, 1, 2])
        #expect(resultReplies == Array(replies.prefix(3)))
        for reply in resultReplies {
            #expect(!reply.ukrainianText.isEmpty)
            #expect(!reply.originalLanguageText.isEmpty)
        }
    }

    @Test("a generator failure leaves the turn's translation valid, with empty suggested replies")
    func generatorFailureLeavesTurnValidWithEmptyReplies() async throws {
        let generator = FakeSuggestedReplyGenerator(error: FakeSuggestedReplyGenerationError(message: "boom"))
        let store = AgentContextStore()
        let spy = SpyGlassesTransport()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["Guten Tag"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["Guten Tag": "de"], translation: "Добрий день"),
            agentContextStore: store,
            replyGenerator: generator
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        // The translation itself must still be there and still sent to
        // G2 — a reply-generation failure never hides it. Milestone 6:
        // it reaches G2 via `displayPages(_:)`, not `sendText(_:)`.
        #expect(await spy.displayedPageSets == [["Guten Tag\n\nUA: Добрий день"]])
        let turn = try #require(store.session.latestTurn)
        #expect(turn.ukrainianTranslation == "Добрий день")
        #expect(turn.suggestedReplies.isEmpty)
    }

    @Test("multiple turns each get their own replies — nothing mixes between them")
    func multipleTurnsDoNotMixReplies() async throws {
        let firstReplies = [Self.reply("First reply", "Перша відповідь", ordering: 0)]
        let secondReplies = [Self.reply("Second reply", "Друга відповідь", ordering: 0)]
        let generator = FakeSuggestedReplyGenerator(repliesByOriginalText: [
            "first phrase": firstReplies,
            "second phrase": secondReplies,
        ])
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
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

        #expect(store.session.turns.count == 2)
        let first = store.session.turns[0]
        let second = store.session.turns[1]
        #expect(first.suggestedReplies == firstReplies)
        #expect(second.suggestedReplies == secondReplies)
    }

    @Test("regular Chat behavior is unaffected by suggested-reply generation")
    func existingChatBehaviorRemainsUnchanged() async throws {
        let generator = FakeSuggestedReplyGenerator(defaultReplies: [Self.reply("Sure", "Так", ordering: 0)])
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: ["Guten Tag"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["Guten Tag": "de"], translation: "Добрий день"),
            agentContextStore: store,
            replyGenerator: generator
        )

        let viewModel = ChatViewModel(chatID: UUID(), chatService: MockChatService(), glassesTransport: MockGlassesTransport())

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        // A live turn with suggested replies now exists in the shared
        // store — Chat's own message list/draft must be entirely
        // unaffected, exactly as in Milestone 3.
        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.draftText.isEmpty)
        #expect(!store.session.turns.isEmpty)
    }
}
