import Testing
import Foundation
@testable import EvenAI

/// `LiveTranslationService`'s integration with
/// `GlassesTransport.displayPages(_:)` and `GlassesPresentationLayer` —
/// no real STT/Azure/OpenAI, no real `SuggestedReplyGenerator`.
///
/// Every displayed page set is now the UNIFIED header+reply format (see
/// `GlassesPresentationLayer`'s doc comment): a turn's original phrase and
/// Ukrainian translation are baked into every page, so a reply update
/// never removes them — `header(_:_:)` below is the one place these
/// tests build the exact expected header text, matching
/// `GlassesPresentationLayer`'s own (private) `conversationHeader`.
@MainActor
@Suite("LiveTranslationService + G2 display (GlassesPresentationLayer)")
struct LiveTranslationServiceG2DisplayTests {
    private static let propagationDelay: Duration = .milliseconds(100)

    private static func reply(_ original: String, _ ukrainian: String, ordering: Int) -> SuggestedReply {
        SuggestedReply(originalLanguageText: original, ukrainianText: ukrainian, ordering: ordering)
    }

    private static func header(_ originalText: String, _ translation: String) -> String {
        "\(originalText)\n\nUA: \(translation)"
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

        #expect(await spy.displayedPageSets == [[Self.header("Guten Tag", "Добрий день")]])
    }

    @Test("suggested replies update G2's display with a reply section ADDED BELOW the still-visible header, never replacing it")
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
        #expect(calls[0] == [Self.header("Guten Tag", "Добрий день")])

        let expectedTurn = ConversationTurn.liveConversationTurn(
            originalText: "Guten Tag",
            detectedLanguage: "de",
            ukrainianTranslation: "Добрий день",
            suggestedReplies: replies
        )
        // Unified pages(for:) — the reply update carries the SAME header
        // as the first call, with the reply section added below it. See
        // LiveTranslationService.generateSuggestedReplies(for:)'s doc
        // comment for the physical bug this fixes (the translation used
        // to visibly disappear when replies arrived).
        #expect(calls[1] == GlassesPresentationLayer.pages(for: expectedTurn))
        #expect(calls[1].allSatisfy { $0.contains("Guten Tag") && $0.contains("Добрий день") })
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
        // Exactly two calls total: header-only, then header+reply pages —
        // never a third call. With two replies, the second call is TWO
        // pages (one per reply — see GlassesPresentationLayer's doc
        // comment), each still carrying the header.
        #expect(calls.count == 2)
        #expect(calls[1].count == 2)
        #expect(calls[1][0].contains("Sure"))
        #expect(calls[1][1].contains("Thursday"))
        #expect(calls[1].allSatisfy { $0.contains("Guten Tag") && $0.contains("Добрий день") })
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

    @Test("when the generator returns no replies, G2's display stays header-only — no redundant second call")
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

        #expect(await spy.displayedPageSets == [[Self.header("Guten Tag", "Добрий день")]])
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
        #expect(await spy.displayedPageSets == [[Self.header("Guten Tag", "Добрий день")]])

        await service.stop()
        try? await Task.sleep(for: Self.propagationDelay)

        // Release the now-cancelled reply generation — must not add a
        // second displayPages call after stop().
        await generator.release("Guten Tag")
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(await spy.displayedPageSets == [[Self.header("Guten Tag", "Добрий день")]])
    }

    // MARK: - "Live Translation stops listening after replies appear" regression guards

    /// The exact scenario reported physically: turn A translates and
    /// displays, its replies then display (adding a reply section below
    /// the still-visible header — see `GlassesPresentationLayer`), and
    /// ONLY THEN does the user (or in this test, the fake transcriber)
    /// produce turn B. `ManualContinuousTranscriber` — not
    /// `ScriptedContinuousTranscriber` — is what makes this possible:
    /// `emit(_:)` lets the test control the real ordering, actually
    /// waiting for A's replies to display before B is ever spoken, rather
    /// than both finals being queued up front. `service.state` and
    /// `currentTurnDisplayState` are asserted directly at each step —
    /// this is the literal state-machine claim the product bug report
    /// makes ("stops listening"), not merely "eventually recovers."
    @Test("turn A's replies displaying does not stop the session from listening — turn B, spoken next, translates and displays immediately, no gesture or restart needed")
    func repliesDisplayingNeverStopsListeningForTheNextTurn() async throws {
        let generator = FakeSuggestedReplyGenerator(repliesByOriginalText: [
            "Guten Tag": [Self.reply("Hi", "Привіт", ordering: 0)],
        ])
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let transcriber = ManualContinuousTranscriber()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(
                languageCodes: ["Guten Tag": "de", "Wie geht es dir": "de"],
                translation: "переклад"
            ),
            agentContextStore: store,
            replyGenerator: generator
        )

        await service.start()
        #expect(service.state == .listening)

        await transcriber.emit("Guten Tag")
        try? await Task.sleep(for: Self.propagationDelay)

        // Turn A: translated, then its replies displayed below the still-
        // visible header. This is the exact moment the physical report
        // describes as "Live Translation stops listening."
        #expect(await spy.displayedPageSets.count == 2)
        #expect(service.state == .listening)
        guard case .withReplies(_, let replyCount) = service.currentTurnDisplayState else {
            Issue.record("expected .withReplies after turn A's replies displayed, got \(service.currentTurnDisplayState)")
            return
        }
        #expect(replyCount == 1)

        // Turn B — spoken only now, strictly after A's replies are
        // already on screen. No stop()/start(), no swipe, nothing but a
        // new final transcript.
        await transcriber.emit("Wie geht es dir")
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(service.state == .listening)
        #expect(store.session.turns.map(\.originalText) == ["Guten Tag", "Wie geht es dir"])
        let calls = await spy.displayedPageSets
        #expect(calls.count == 3) // A translated, A+replies, B translated
        // B also carries one page of look-back context (A) — see
        // GlassesPresentationLayer.conversationPages(for:previousTurn:).
        #expect(calls.last == [Self.header("Wie geht es dir", "переклад"), "Previous:\nGuten Tag\n\nUA: переклад"])
        #expect(service.currentTurnDisplayState == .translated(turnID: store.session.turns.last!.id))
    }

    /// A new turn's header must never be contaminated by the previous
    /// turn's reply content — even in the ordinary, non-racing sequential
    /// case (turn A fully finishes, replies included, before turn B is
    /// even spoken). `pagination.start(withPages:)` fully replaces on
    /// every `displayPages(_:)` call, but this proves it at the
    /// `GlassesPresentationLayer` page-content level, not just the call
    /// count.
    @Test("a new turn's header-only display never carries over the previous turn's stale reply content")
    func newTurnClearsStaleRepliesFromPreviousTurn() async throws {
        let generator = FakeSuggestedReplyGenerator(repliesByOriginalText: [
            "first phrase": [Self.reply("Old reply", "Стара відповідь", ordering: 0)],
        ])
        let spy = SpyGlassesTransport()
        let transcriber = ManualContinuousTranscriber()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(
                languageCodes: ["first phrase": "en", "second phrase": "en"],
                translation: "переклад"
            ),
            replyGenerator: generator
        )

        await service.start()
        await transcriber.emit("first phrase")
        try? await Task.sleep(for: Self.propagationDelay)
        #expect(await spy.displayedPageSets.count == 2) // translated, then +replies

        await transcriber.emit("second phrase")
        try? await Task.sleep(for: Self.propagationDelay)

        let calls = await spy.displayedPageSets
        #expect(calls.count == 3)
        // Turn B's page set must be exactly the header + one page of
        // look-back context for turn A — no trace of turn A's "Old
        // reply" content, which belonged only to A's own (superseded)
        // reply-stage display.
        #expect(calls.last == [Self.header("second phrase", "переклад"), "Previous:\nfirst phrase\n\nUA: переклад"])
        #expect(!calls.last!.contains { $0.contains("Old reply") })
    }

    @Test("swiping through reply pages never removes the header — every page in a with-replies update contains the original phrase and its translation")
    func swipingRetainsHeaderAcrossReplyPages() async throws {
        let replies = [
            Self.reply("I'm good, thank you.", "У мене все добре, дякую.", ordering: 0),
            Self.reply("Pretty well. How about you?", "Досить добре. А ти?", ordering: 1),
        ]
        let generator = FakeSuggestedReplyGenerator(defaultReplies: replies)
        let spy = SpyGlassesTransport()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["How are you?"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["How are you?": "en"], translation: "Як ти?"),
            agentContextStore: AgentContextStore(),
            replyGenerator: generator
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        let calls = await spy.displayedPageSets
        #expect(calls.count == 2)
        let replyPages = calls[1]
        #expect(replyPages.count == 2) // one page per reply — never packed together
        for page in replyPages {
            #expect(page.contains("How are you?"))
            #expect(page.contains("Як ти?"))
        }
    }
}
