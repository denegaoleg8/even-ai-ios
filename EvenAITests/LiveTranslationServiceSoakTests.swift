import Testing
import Foundation
@testable import EvenAI

/// Group-meeting reliability scenarios (Section 20) not already covered
/// by `LiveTranslationServiceTests`'s own focused tests, plus the
/// 100-turn deterministic soak/simulation test (Section 21, extended per
/// the follow-up reply-browsing/history-browsing/audio-instrumentation
/// pass). Scenarios D, E, G (stale provisional revisions, slow replies
/// not blocking a later turn, return-to-live) are already covered by
/// `stalePartialTranslationNeverOverwritesNewer`,
/// `repliesForOlderTurnNeverBlockNewerPartial`, and
/// `returningToLiveRedisplaysFreshContent` respectively; F/H (manual
/// scroll leaving the viewport in place while browsing history vs. new
/// speech immediately reclaiming the display while browsing replies) are
/// covered by `newTurnsStillProcessWhileBrowsingHistory` and
/// `newSpeechDuringReplyBrowsingReturnsToLive` — not duplicated here.
/// Scenario K (history survives app restart) is a Chat/backend-
/// persistence claim, covered by `ChatViewModelTests
/// .loadPreservesOrderAndStableIDs`, not a `LiveTranslationService`
/// concern. Scenario L (Chat scrolling never alters G2's viewport) has
/// no shared state to exercise — `ChatAutoScrollState`/`ChatView` never
/// reference `LiveTranslationService.followLive` or
/// `MentraGlassesTransport` pagination at all; the absence of that
/// coupling is the proof, verifiable by inspection, not a runtime test.
@MainActor
@Suite("LiveTranslationService — meeting reliability scenarios and soak test")
struct LiveTranslationServiceSoakTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "LiveTranslationServiceSoakTests.\(UUID().uuidString)")!
    }

    // MARK: - Scenario A: 20 sequential turns, none wedges the session

    @Test("Scenario A: 20 sequential turns all process; none wedges the session")
    func twentySequentialTurnsNeverWedge() async throws {
        let store = AgentContextStore()
        let words = (1...20).map { "phrase\($0)" }
        var languageCodes: [String: String?] = [:]
        for word in words { languageCodes[word] = "en" }
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: words, autoFinish: false),
            translator: ScriptedLanguageTranslator(languageCodes: languageCodes, translation: "переклад"),
            agentContextStore: store,
            defaults: freshDefaults()
        )

        await service.start()
        try? await Task.sleep(for: .milliseconds(400))

        #expect(store.session.turns.count == 20)
        #expect(store.session.turns.map(\.originalText) == words)
        #expect(service.state == .listening)
    }

    // MARK: - Scenario B: rapid A/B/C finals all become ordered history

    @Test("Scenario B: rapid back-to-back A/B/C finals all become ordered, un-mixed history")
    func rapidBackToBackFinalsBecomeOrderedHistory() async throws {
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: ["A phrase", "B phrase", "C phrase"], autoFinish: false),
            translator: ScriptedLanguageTranslator(
                languageCodes: ["A phrase": "en", "B phrase": "en", "C phrase": "en"],
                translation: "переклад"
            ),
            agentContextStore: store,
            defaults: freshDefaults()
        )

        await service.start()
        try? await Task.sleep(for: .milliseconds(120))

        #expect(store.session.turns.map(\.originalText) == ["A phrase", "B phrase", "C phrase"])
    }

    // MARK: - Scenario C: slow translation A never blocks B or C

    @Test("Scenario C: a slow translation A never blocks B or C from processing")
    func slowTranslationANeverBlocksBOrC() async throws {
        let store = AgentContextStore()
        let translator = DelayedLanguageTranslator(
            languageCodes: ["A phrase": "en", "B phrase": "en", "C phrase": "en"],
            delays: ["A phrase": .seconds(3600)], // effectively unbounded for this test's lifetime
            translations: ["A phrase": "А", "B phrase": "Б", "C phrase": "В"]
        )
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: ["A phrase", "B phrase", "C phrase"], autoFinish: false),
            translator: translator,
            agentContextStore: store,
            defaults: freshDefaults()
        )

        await service.start()
        try? await Task.sleep(for: .milliseconds(150))

        // B and C fully processed; A is present as an early-appended
        // draft (still untranslated — its translate call never
        // resolves within this test's lifetime).
        #expect(store.session.turns.map(\.originalText) == ["A phrase", "B phrase", "C phrase"])
        #expect(store.session.turns.first(where: { $0.originalText == "B phrase" })?.ukrainianTranslation == "Б")
        #expect(store.session.turns.first(where: { $0.originalText == "C phrase" })?.ukrainianTranslation == "В")
        #expect(store.session.turns.first(where: { $0.originalText == "A phrase" })?.ukrainianTranslation == nil)
        #expect(service.state == .listening)
    }

    // MARK: - Scenario I: explicit EN through 20 turns, zero detector calls

    @Test("Scenario I: explicit EN mode through 20 turns invokes language detection zero times")
    func explicitModeThroughTwentyTurnsNeverDetects() async throws {
        let words = (1...20).map { "phrase\($0)" }
        let recorder = RecordingLanguageTranslator(translation: "переклад")
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: words, autoFinish: false),
            translator: recorder,
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(.en)

        await service.start()
        try? await Task.sleep(for: .milliseconds(400))

        #expect(await recorder.detectionCallCount == 0)
        let translateCalls = await recorder.translateCalls
        #expect(translateCalls.count == 20)
        #expect(translateCalls.allSatisfy { $0.languageCode == "en" })
    }

    // MARK: - Scenario J: STT temporary disconnect recovers, later turn persists

    @Test("Scenario J: a temporary STT disconnect (one reconnect) recovers, and the next turn still persists")
    func sttTemporaryDisconnectRecoversAndNextTurnPersists() async throws {
        let factory = FakeRealtimeTranscriptionSocketFactory()
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: OpenAIRealtimeTranscriber(makeSocket: { await factory.makeSocket() }),
            translator: ScriptedLanguageTranslator(languageCodes: ["recovered phrase": "en"], translation: "переклад"),
            agentContextStore: store,
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(.en)

        await service.start()
        try? await Task.sleep(for: .milliseconds(100))

        let firstSocket = await factory.createdSockets[0]
        await firstSocket.emit(.closed(reason: "transient network blip"))
        try? await Task.sleep(for: .milliseconds(100))

        // The transcriber reconnected on its own (one retry, per its own
        // established policy) — Live Translation never required a
        // restart from the caller's side.
        #expect(await factory.createdSockets.count == 2)
        #expect(service.state == .listening)

        let secondSocket = await factory.createdSockets[1]
        await secondSocket.emit(.finalTranscript("recovered phrase"))
        try? await Task.sleep(for: .milliseconds(100))

        #expect(store.session.turns.map(\.originalText) == ["recovered phrase"])
        #expect(store.session.turns.first?.ukrainianTranslation == "переклад")
    }

    // MARK: - Regression: the exact rapid-speech DisplayMode race

    /// Deterministically reproduces the exact race a prior revision of
    /// `DisplayMode` classification got wrong: a turn's own reply
    /// generation is still pending (so the ONLY non-live page that
    /// exists yet is the trailing history page, not a reply page) at the
    /// precise moment the user swipes into history, immediately followed
    /// by new speech, with the pending replies finally landing only
    /// afterward. Deterministic via `GatedSuggestedReplyGenerator`
    /// (reply generation genuinely blocks until explicitly released) —
    /// no timing race to get unlucky on, unlike relying on `Task.sleep`
    /// margins to model "still pending."
    @Test("regression: history swipe while reply generation is still pending is never temporarily misclassified as browsingReplies")
    func historySwipeBeforeRepliesSettleNeverMisclassifiesAsReplyBrowsing() async throws {
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let transcriber = ManualContinuousTranscriber()
        let generator = GatedSuggestedReplyGenerator(repliesByOriginalText: [
            "turn A": [SuggestedReply(originalLanguageText: "Sure", ukrainianText: "Так", ordering: 0)],
        ])
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(
                languageCodes: ["turn zero": "en", "turn A": "en", "turn B": "en"],
                translation: "переклад"
            ),
            agentContextStore: store,
            replyGenerator: generator,
            defaults: freshDefaults()
        )
        await service.start()

        // A turn before A, so there's a genuine history target to swipe
        // to.
        await transcriber.emit("turn zero")
        try? await Task.sleep(for: .milliseconds(30))

        // Turn A finalizes and its translation displays; its OWN reply
        // generation is gated — genuinely still pending, not just
        // "probably not done yet."
        await transcriber.emit("turn A")
        try? await Task.sleep(for: .milliseconds(30))
        #expect(store.session.turns.last?.originalText == "turn A")
        #expect(store.session.turns.last?.suggestedReplies.isEmpty == true)

        // The user swipes into history AT EXACTLY THIS MOMENT — turn A
        // has zero replies right now, so index 1 is unambiguously the
        // trailing history page, never a reply page.
        await spy.simulateNavigation(.pageChanged(index: 1))
        try? await Task.sleep(for: .milliseconds(20))
        guard case .browsingHistory(let anchorTurnID) = service.displayMode else {
            Issue.record("expected .browsingHistory — got \(service.displayMode); this IS the exact race being regression-tested")
            return
        }
        #expect(anchorTurnID == store.session.turns.first(where: { $0.originalText == "turn zero" })?.id)
        let displayCountAtSwipe = await spy.displayedPageSets.count

        // New speech B arrives immediately afterward — must NOT force
        // the viewport back to live.
        await transcriber.emit("turn B")
        try? await Task.sleep(for: .milliseconds(30))
        guard case .browsingHistory(let anchorAfterB) = service.displayMode else {
            Issue.record("expected .browsingHistory to persist through new speech, got \(service.displayMode)")
            return
        }
        #expect(anchorAfterB == anchorTurnID)
        #expect(await spy.displayedPageSets.count == displayCountAtSwipe) // viewport untouched
        #expect(store.session.turns.map(\.originalText) == ["turn zero", "turn A", "turn B"]) // B captured/translated/persisted regardless

        // Turn A's replies finally land, late — must not change
        // DisplayMode at all.
        await generator.release("turn A")
        try? await Task.sleep(for: .milliseconds(30))
        #expect(store.session.turns.first(where: { $0.originalText == "turn A" })?.suggestedReplies.count == 1)
        guard case .browsingHistory(let anchorAfterReplies) = service.displayMode else {
            Issue.record("expected .browsingHistory to persist through late replies, got \(service.displayMode)")
            return
        }
        #expect(anchorAfterReplies == anchorTurnID)
        #expect(await spy.displayedPageSets.count == displayCountAtSwipe) // still untouched

        // Explicit return-to-live restores followLive and shows the
        // NEWEST turn (B), not A.
        await spy.simulateNavigation(.returnToLiveRequested)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(service.displayMode == .followLive)
        let lastPageSet = await spy.displayedPageSets.last
        #expect(lastPageSet?.first?.contains("turn B") == true)
    }

    /// The same race as above, repeated many times in a row — proves the
    /// fix isn't a one-shot coincidence and that no state leaks between
    /// cycles (each cycle ends back at `.followLive` before the next
    /// one's own history-swipe starts).
    @Test("regression: the history-swipe-before-replies-settle race never misclassifies, repeated many times")
    func historySwipeBeforeRepliesSettleRaceNeverMisclassifiesAcrossManyRepetitions() async throws {
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let transcriber = ManualContinuousTranscriber()
        let generator = GatedSuggestedReplyGenerator()
        let repetitions = 12
        var languageCodes: [String: String] = [:]
        for i in 1...repetitions {
            languageCodes["zero-\(i)"] = "en"
            languageCodes["A-\(i)"] = "en"
            languageCodes["B-\(i)"] = "en"
        }
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(languageCodes: languageCodes, translation: "переклад"),
            agentContextStore: store,
            replyGenerator: generator,
            defaults: freshDefaults()
        )
        await service.start()

        for i in 1...repetitions {
            await transcriber.emit("zero-\(i)")
            try? await Task.sleep(for: .milliseconds(15))

            await transcriber.emit("A-\(i)")
            try? await Task.sleep(for: .milliseconds(15))
            #expect(store.session.turns.last?.suggestedReplies.isEmpty == true)

            await spy.simulateNavigation(.pageChanged(index: 1))
            try? await Task.sleep(for: .milliseconds(15))
            guard case .browsingHistory = service.displayMode else {
                Issue.record("repetition \(i): expected .browsingHistory, got \(service.displayMode)")
                return
            }

            await transcriber.emit("B-\(i)")
            try? await Task.sleep(for: .milliseconds(15))
            guard case .browsingHistory = service.displayMode else {
                Issue.record("repetition \(i): expected .browsingHistory to persist through new speech, got \(service.displayMode)")
                return
            }

            await generator.release("A-\(i)")
            try? await Task.sleep(for: .milliseconds(15))
            guard case .browsingHistory = service.displayMode else {
                Issue.record("repetition \(i): expected .browsingHistory to persist through late replies, got \(service.displayMode)")
                return
            }

            await spy.simulateNavigation(.returnToLiveRequested)
            try? await Task.sleep(for: .milliseconds(15))
            guard service.displayMode == .followLive else {
                Issue.record("repetition \(i): expected .followLive after explicit return, got \(service.displayMode)")
                return
            }
        }

        #expect(store.session.turns.count == repetitions * 3)
        #expect(service.state == .listening)
    }

    // MARK: - Section 21: 100-turn deterministic soak / simulation test

    /// A single, deterministic simulated conversation covering short and
    /// long utterances, rapid speech, delayed translation responses,
    /// reply delays, stale provisional responses, a REAL simulated STT
    /// disconnect/reconnect (via `OpenAIRealtimeTranscriber` +
    /// `FakeRealtimeTranscriptionSocketFactory` — the same mechanism
    /// Scenario J uses above, exercised here mid-soak instead of in
    /// isolation), simulated audio-arrival timing gaps, browsing reply
    /// pages (must auto-return to live the instant new speech starts —
    /// no double-tap), browsing history (must NOT auto-return), and an
    /// explicit return-to-live from history — all in one continuous
    /// 100-turn session, asserting every invariant Section 21/5 requires:
    /// no deadlock, no lost finalized turn regardless of UI mode, no
    /// duplicate persisted turn, ordered history, the listener stays
    /// active throughout, stale translations never overwrite newer ones,
    /// reply browsing never blocks live display, history browsing never
    /// blocks capture/persistence, and no unbounded task/request queue
    /// (bounded finish time is itself evidence of this — an unbounded
    /// queue would make this test hang past any reasonable timeout).
    @Test("100-turn deterministic soak test: no deadlock, no lost/duplicate turns, ordered history, reply/history browsing behave correctly, listener stays active throughout")
    func hundredTurnSoakTest() async throws {
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        // Two replies (not one) so a reply page genuinely exists at
        // index 1, distinct from page 0 — see
        // `GlassesPresentationLayer.pages(for:)`'s doc comment: a single
        // reply stays on page 0 alongside the header.
        let generator = FakeSuggestedReplyGenerator(defaultReplies: [
            SuggestedReply(originalLanguageText: "Sure", ukrainianText: "Так", ordering: 0),
            SuggestedReply(originalLanguageText: "No thanks", ukrainianText: "Ні, дякую", ordering: 1),
        ])
        let socketFactory = FakeRealtimeTranscriptionSocketFactory()
        let transcriber = OpenAIRealtimeTranscriber(makeSocket: { await socketFactory.makeSocket() })

        // 100 distinct phrases: a mix of short ("hi7"), medium, and long
        // (every 10th) utterances — all distinct text so "no duplicate
        // persisted turn" and "ordered history" are both meaningfully
        // checkable afterward.
        let phrases: [String] = (1...100).map { index in
            if index % 10 == 0 {
                return "this is a much longer utterance number \(index) with several words in it"
            } else if index % 7 == 0 {
                return "hi\(index)"
            } else {
                return "phrase number \(index)"
            }
        }
        var translations: [String: String] = [:]
        for phrase in phrases {
            translations[phrase] = "переклад \(phrase)"
        }
        let translator = DelayedLanguageTranslator(
            languageCodes: Dictionary(uniqueKeysWithValues: phrases.map { ($0, "en") }),
            // Every 5th phrase gets an artificial delay — models "delayed
            // translation responses" without making the whole test slow.
            delays: Dictionary(uniqueKeysWithValues: phrases.enumerated().compactMap { index, phrase in
                index % 5 == 0 ? (phrase, Duration.milliseconds(40)) : nil
            }),
            translations: translations
        )

        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: translator,
            agentContextStore: store,
            replyGenerator: generator,
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(.en)

        await service.start()
        #expect(service.state == .listening)

        // Simulated audio-arrival timing gaps: a handful of tightly-
        // spaced chunks, then a deliberate large gap — exercises
        // `LiveTranslationService`'s audio-reliability instrumentation
        // (chunk/gap counting) under a genuinely irregular arrival
        // pattern, proving it doesn't crash or stall the pipeline. (The
        // exact gap-detection math has its own honest-limitations note
        // in the final report — no test-capture hook exists for
        // `DiagnosticTrace`'s output in this codebase, so this proves
        // the code path is safe under real irregular timing, not the
        // exact numbers it logs.)
        for _ in 0..<5 {
            await spy.simulatePCMChunk()
            try? await Task.sleep(for: .milliseconds(5))
        }
        try? await Task.sleep(for: .milliseconds(250)) // the gap
        await spy.simulatePCMChunk()

        for (index, phrase) in phrases.enumerated() {
            let currentSocket = await socketFactory.createdSockets.last!
            await currentSocket.emit(.finalTranscript(phrase))

            // Simulated REAL STT disconnect/reconnect midway through —
            // `OpenAIRealtimeTranscriber` reconnects on its own; the
            // session must keep going, and subsequent phrases must
            // continue arriving through the NEW socket with no restart
            // from `LiveTranslationService`'s side.
            if index == 40 {
                try? await Task.sleep(for: .milliseconds(30))
                await currentSocket.emit(.closed(reason: "simulated blip"))
                try? await Task.sleep(for: .milliseconds(60))
                #expect(await socketFactory.createdSockets.count == 2)
                #expect(service.state == .listening)
            }

            // Browsing REPLY pages: swipe onto the (still current-turn)
            // reply page... (indices deliberately NOT divisible by 5 —
            // those phrases carry an artificial translation delay, which
            // would make the freshly-settled page structure this check
            // depends on racy).
            if index == 22 {
                try? await Task.sleep(for: .milliseconds(150))
                await spy.simulateNavigation(.pageChanged(index: 1))
                try? await Task.sleep(for: .milliseconds(30))
                guard case .browsingReplies = service.displayMode else {
                    Issue.record("expected .browsingReplies, got \(service.displayMode)")
                    return
                }
            }
            // ...then the VERY NEXT turn's own new speech (emitted at
            // the top of this loop body, before this check) must have
            // reclaimed the live display automatically — no double-tap.
            if index == 23 {
                try? await Task.sleep(for: .milliseconds(30))
                #expect(service.displayMode == .followLive)
            }

            // Browsing HISTORY (the trailing look-back page): must NOT
            // be overridden by new speech — persistence continues, but
            // the display stays put until an explicit return-to-live.
            // Index 63 (and its own previous turn, 62) are both clear of
            // the artificial translation delay (`index % 5 == 0`) — this
            // checkpoint needs the PREVIOUS turn's translation to have
            // already landed too, so its context page is actually
            // present in the page set this navigates onto.
            if index == 63 {
                try? await Task.sleep(for: .milliseconds(150))
                await spy.simulateNavigation(.pageChanged(index: 2))
                try? await Task.sleep(for: .milliseconds(30))
                guard case .browsingHistory = service.displayMode else {
                    Issue.record("expected .browsingHistory, got \(service.displayMode)")
                    return
                }
            }
            if index == 68 {
                // Still browsing history 5 turns later — new speech
                // never forced it back.
                guard case .browsingHistory = service.displayMode else {
                    Issue.record("expected .browsingHistory to persist, got \(service.displayMode)")
                    return
                }
                await spy.simulateNavigation(.returnToLiveRequested)
                try? await Task.sleep(for: .milliseconds(30))
                #expect(service.displayMode == .followLive)
            }

            try? await Task.sleep(for: .milliseconds(8))
        }

        // Let every in-flight translate/reply/display task settle —
        // generous but still bounded (a real deadlock would hang well
        // past this and fail the test's own timeout).
        try? await Task.sleep(for: .seconds(3))

        // No deadlock: the loop above completed, and the session is
        // still healthy.
        #expect(service.state == .listening)

        // No lost finalized turn (regardless of what UI mode was active
        // when it arrived), no duplicate persisted turn, ordered
        // history: exactly 100 turns, in exactly the order spoken.
        #expect(store.session.turns.count == 100)
        #expect(store.session.turns.map(\.originalText) == phrases)
        #expect(Set(store.session.turns.map(\.id)).count == 100) // no duplicate turn identity

        // Every turn eventually got its translation (the delayed ones
        // included).
        #expect(store.session.turns.allSatisfy { $0.ukrainianTranslation != nil })

        // No stale reply/translation ever replaced a different turn's:
        // each turn's translation matches exactly what was scripted for
        // ITS OWN text, never another turn's.
        for turn in store.session.turns {
            #expect(turn.ukrainianTranslation == translations[turn.originalText])
        }
    }
}
