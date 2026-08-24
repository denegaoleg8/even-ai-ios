import Testing
import Foundation
@testable import EvenAI

/// Ambient G2-mic translation — the only Voice feature ("Dictate to Chat"
/// was removed) — app-level, not owned by any screen (see
/// `LiveTranslationService`'s doc comment). These tests exercise its
/// decision pipeline (dedupe, empty/uncertain/Ukrainian filtering,
/// translation dispatch, cleanup) and its app-level lifecycle (surviving
/// construction independent of any view, stopping only on an explicit
/// `stop()` or connection loss — never on navigation or `scenePhase`)
/// entirely through fakes — no real `Speech`/`Translation`/PCM involved.
@MainActor
@Suite("LiveTranslationService")
struct LiveTranslationServiceTests {
    // Widened from 30ms: this suite now has ~30 tests, several running
    // real (fake-backed) async work concurrently under Swift Testing's
    // parallel scheduler — a 30ms budget was intermittently too tight
    // under that contention (confirmed non-deterministic across reruns:
    // a different, unrelated test/word failed each time, never the same
    // one twice — the signature of a scheduling margin issue, not a
    // logic bug). Test-only constant; does not reflect or affect any
    // production timing.
    private static let propagationDelay: Duration = .milliseconds(150)

    @Test("a foreign-language final phrase is translated and sent to the glasses")
    func foreignPhraseIsTranslatedAndSent() async throws {
        let spy = SpyGlassesTransport()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["hello there"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["hello there": "en"], translation: "привіт")
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        // Milestone 6: the translation now reaches G2 via
        // `displayPages(_:)` (through `GlassesPresentationLayer`), not a
        // direct `sendText(_:)` call — `sentTexts` legitimately stays
        // empty; this is what actually carries the translation now.
        #expect(await spy.displayedPageSets == [["hello there\n\nUA: привіт"]])
    }

    @Test("Ukrainian speech is never translated or displayed")
    func ukrainianSpeechIsIgnored() async throws {
        let spy = SpyGlassesTransport()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["привіт, як справи"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["привіт, як справи": "uk"])
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(await spy.sentTexts.isEmpty)
    }

    @Test("uncertain language detection displays nothing rather than a guess")
    func uncertainDetectionDisplaysNothing() async throws {
        let spy = SpyGlassesTransport()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["mmm uh"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["mmm uh": nil])
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(await spy.sentTexts.isEmpty)
    }

    @Test("a duplicate final transcript is not translated or sent twice")
    func duplicateFinalTranscriptIsIgnored() async throws {
        let spy = SpyGlassesTransport()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["hello", "hello"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["hello": "en"], translation: "привіт")
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        // Milestone 6: see `foreignPhraseIsTranslatedAndSent`'s comment —
        // `displayPages(_:)` is what actually carries this now.
        #expect(await spy.displayedPageSets == [["hello\n\nUA: привіт"]])
    }

    @Test("a translation failure leaves the session alive — no turn/display for that phrase, and a later phrase still works")
    func translationFailureLeavesSessionAlive() async throws {
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["Guten Tag", "hello there"], autoFinish: false),
            translator: ThrowingLanguageTranslator(failingTexts: ["Guten Tag"], translation: "привіт"),
            agentContextStore: store
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        // The failed phrase produced no turn and nothing was displayed —
        // `handle(final:)` returns as soon as `translated == nil` — but
        // the session stayed healthy enough to process the next, distinct
        // phrase normally: exactly one turn, for "hello there" alone.
        #expect(store.session.turns.map(\.originalText) == ["hello there"])
        #expect(await spy.displayedPageSets == [["hello there\n\nUA: привіт"]])
        // `state` never became `.error`, unlike a microphone-enable failure.
        #expect(service.state == .listening)
    }

    /// Regression guard for a real physical-device hang (not merely
    /// theorized): `AppleLanguageTranslator.translateToUkrainian` can
    /// block forever if the on-device `Translation` framework needs to
    /// present its own system UI at a moment another `.sheet` is already
    /// covering the view that hosts its `TranslationSession` — see
    /// `LiveTranslationService.translateWithTimeout`'s doc comment. Before
    /// the timeout existed, a stuck translation call would silently wedge
    /// `consume(_:)`'s sequential loop forever — every phrase after the
    /// stuck one would simply never be processed, with no error, no
    /// display update, and no visible sign anything had gone wrong.
    @Test("a translation call that never returns times out — the session stays alive and a later phrase still works")
    func translationTimeoutLeavesSessionAlive() async throws {
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["Guten Tag", "hello there"], autoFinish: false),
            translator: HangingLanguageTranslator(
                languageCodes: ["Guten Tag": "de", "hello there": "en"],
                hangingTexts: ["Guten Tag"],
                translation: "привіт"
            ),
            agentContextStore: store,
            translationTimeout: .milliseconds(30)
        )

        await service.start()
        try? await Task.sleep(for: .milliseconds(200)) // comfortably past the 30ms timeout

        // The hung phrase produced no turn and nothing was displayed for
        // it, but the session recovered and processed the next, distinct
        // phrase completely normally.
        #expect(store.session.turns.map(\.originalText) == ["hello there"])
        #expect(await spy.displayedPageSets == [["hello there\n\nUA: привіт"]])
        #expect(service.state == .listening)
    }

    @Test("an empty (or whitespace-only) final transcript is ignored")
    func emptyFinalTranscriptIsIgnored() async throws {
        let spy = SpyGlassesTransport()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["   ", ""]),
            translator: ScriptedLanguageTranslator(languageCodes: [:])
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(await spy.sentTexts.isEmpty)
    }

    @Test("a recognized final phrase and its translation are exposed as observable state, for Chat to read")
    func recognizedPhraseAndTranslationAreObservable() async throws {
        let spy = SpyGlassesTransport()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["hello there"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["hello there": "en"], translation: "привіт")
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(service.lastRecognizedPhrase == "hello there")
        #expect(service.lastTranslation == "привіт")
    }

    @Test("stopping cleans up the microphone and recognition state")
    func stopCleansUpMicrophoneAndRecognitionState() async throws {
        let spy = SpyGlassesTransport()
        let transcriber = ScriptedContinuousTranscriber(finals: [])
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(languageCodes: [:])
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)
        await service.stop()

        #expect(await transcriber.stopCallCount == 1)
        #expect(await spy.microphoneEnabledCalls == [true, false])
        #expect(service.state == .idle)
    }

    @Test("a failure enabling the microphone surfaces a visible error, never a silent no-op")
    func microphoneFailureSurfacesError() async {
        let service = LiveTranslationService(
            glassesTransport: PairFailureGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: []),
            translator: ScriptedLanguageTranslator(languageCodes: [:])
        )

        await service.start()

        guard case .error = service.state else {
            Issue.record("Expected .error, got \(service.state)")
            return
        }
    }

    @Test("losing the G2 connection while listening stops the microphone and recognition, safely")
    func connectionLossStopsListening() async throws {
        let transport = ControllableGlassesTransport(initialState: .connected)
        let transcriber = ScriptedContinuousTranscriber(finals: [], autoFinish: false)
        let service = LiveTranslationService(
            glassesTransport: transport,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(languageCodes: [:])
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)
        #expect(service.state == .listening)

        await transport.simulateConnectionChange(.disconnected)
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(service.state == .idle)
        #expect(await transcriber.stopCallCount == 1)
        #expect(await transport.microphoneEnabledCalls == [true, false])
    }

    @Test("a connection change before Live Translation was ever started is a no-op")
    func connectionChangeBeforeStartIsIgnored() async throws {
        let transport = ControllableGlassesTransport(initialState: .connected)
        let service = LiveTranslationService(
            glassesTransport: transport,
            transcriber: ScriptedContinuousTranscriber(finals: []),
            translator: ScriptedLanguageTranslator(languageCodes: [:])
        )

        try? await Task.sleep(for: Self.propagationDelay)
        await transport.simulateConnectionChange(.disconnected)
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(service.state == .idle)
        #expect(await transport.microphoneEnabledCalls.isEmpty)
    }

    /// Regression guard for the earlier foreground-only design:
    /// `LiveTranslationService` has no `scenePhase`-reactive method at all
    /// (`handleScenePhaseChange` was removed along with `RootView`'s
    /// `.onChange(of: scenePhase)` wiring) — there is no external signal
    /// for navigation or backgrounding to send it, so listening simply
    /// continues through the passage of time with nothing else happening,
    /// exactly as it would across a Voice → Chat navigation or the screen
    /// locking. Only an explicit `stop()` or a lost G2 connection (both
    /// covered by other tests in this suite) end a session.
    @Test("Live Translation keeps listening with nothing else happening — no navigation/scenePhase signal exists to stop it")
    func keepsListeningWithNoExternalStopSignal() async throws {
        let spy = SpyGlassesTransport()
        let transcriber = ScriptedContinuousTranscriber(finals: [], autoFinish: false)
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(languageCodes: [:])
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)
        #expect(service.state == .listening)

        // Stands in for "time passes while the user navigates Voice → Chat
        // → Settings, or the screen locks" — nothing in this window should
        // touch the service.
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(service.state == .listening)
        #expect(await transcriber.stopCallCount == 0)
        #expect(await spy.microphoneEnabledCalls == [true])
    }

    // MARK: - Short-utterance handling

    /// Regression guard for the physically-confirmed "hello often dropped"
    /// bug's *pipeline* half (the other half — real language-detection
    /// confidence — is `AppleLanguageTranslatorTests`). Before the fix,
    /// `lastRecognizedPhrase` was set unconditionally the moment any
    /// non-empty final arrived, with no time bound — so a short phrase
    /// that failed anywhere downstream still permanently "used up" that
    /// exact text for deduping purposes, and every later retry of the
    /// same word was silently treated as a duplicate forever. This proves
    /// each of the exact words from the physical report is accepted and
    /// reaches G2 given a translator that *can* identify its language —
    /// isolating the pipeline's own dedupe logic from NLLanguageRecognizer
    /// specifically.
    @Test(
        "each short valid utterance from the physical report is accepted and reaches G2",
        arguments: ["hello", "hi", "yes", "no", "thanks", "okay", "goodbye"]
    )
    func shortValidUtterancesAreAccepted(word: String) async throws {
        let spy = SpyGlassesTransport()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: [word]),
            translator: ScriptedLanguageTranslator(languageCodes: [word: "en"], translation: "переклад")
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(await spy.displayedPageSets == [["\(word)\n\nUA: переклад"]])
    }

    @Test("a short phrase repeated after the dedupe window elapses is accepted again as a new, distinct turn")
    func shortPhraseRepeatedAfterWindowIsAcceptedAgain() async throws {
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let transcriber = ManualContinuousTranscriber()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(languageCodes: ["hello": "en"], translation: "привіт"),
            agentContextStore: store,
            duplicateSuppressionWindow: 0.05
        )

        await service.start()
        await transcriber.emit("hello")
        try? await Task.sleep(for: .milliseconds(30))
        #expect(store.session.turns.count == 1)

        // Past the 50ms window — a second, genuinely new "hello" utterance.
        try? await Task.sleep(for: .milliseconds(60))
        await transcriber.emit("hello")
        try? await Task.sleep(for: .milliseconds(30))

        #expect(store.session.turns.count == 2)
        #expect(await spy.displayedPageSets == [["hello\n\nUA: привіт"], ["hello\n\nUA: привіт"]])
    }

    @Test("the same phrase repeated within the dedupe window is still rejected as a duplicate")
    func shortPhraseRepeatedWithinWindowIsRejected() async throws {
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let transcriber = ManualContinuousTranscriber()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(languageCodes: ["hello": "en"], translation: "привіт"),
            agentContextStore: store,
            duplicateSuppressionWindow: 5
        )

        await service.start()
        await transcriber.emit("hello")
        try? await Task.sleep(for: .milliseconds(20))
        await transcriber.emit("hello") // well within the 5s window
        try? await Task.sleep(for: .milliseconds(20))

        #expect(store.session.turns.count == 1)
        #expect(await spy.displayedPageSets == [["hello\n\nUA: привіт"]])
    }

    // MARK: - "Glasses Chat" persistence

    @Test("a finalized turn is appended to the Glasses Chat as a real, persisted message")
    func turnIsAppendedToGlassesChat() async throws {
        let spy = SpyGlassesTransport()
        let chatService = RecordingAppendChatService()
        let provider = GlassesChatProvider(chatService: chatService, defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["hello there"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["hello there": "en"], translation: "привіт"),
            chatService: chatService,
            glassesChatProvider: provider
        )

        await service.start()
        try? await Task.sleep(for: .milliseconds(60))

        let appended = await chatService.appendedMessages
        #expect(appended.count == 1)
        #expect(appended.first?.role == .user)
        #expect(appended.first?.content.contains("hello there") == true)
        #expect(appended.first?.content.contains("привіт") == true)
    }

    @Test("when no ChatServicing/GlassesChatProvider is configured, Live Translation still works normally — Chat persistence is simply skipped")
    func noChatServiceConfiguredIsHarmless() async throws {
        let spy = SpyGlassesTransport()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["hello there"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["hello there": "en"], translation: "привіт")
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(await spy.displayedPageSets == [["hello there\n\nUA: привіт"]])
    }

    // MARK: - Turn ordering / stale-async-task races

    /// Regression guard: phrase A's Glasses Chat append and suggested-reply
    /// generation are both slow (network-bound); phrase B finalizes before
    /// either completes. Neither of A's late-arriving side effects may
    /// disturb what's now on screen for B — A's chat message still gets
    /// appended (history is preserved, per the product requirement — the
    /// message itself is independent of "what's currently displayed"), but
    /// A's suggested replies must never redisplay over B's translation.
    @Test("phrase B's display is never clobbered by phrase A's slow, late-arriving suggested replies")
    func newerTurnDisplayIsNeverClobberedByOlderStaleReplies() async throws {
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let generator = GatedSuggestedReplyGenerator(repliesByOriginalText: [
            "phrase A": [SuggestedReply(originalLanguageText: "A-reply", ukrainianText: "А-відповідь", ordering: 0)],
        ])
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["phrase A", "phrase B"]),
            translator: ScriptedLanguageTranslator(
                languageCodes: ["phrase A": "en", "phrase B": "en"],
                translation: "переклад"
            ),
            agentContextStore: store,
            replyGenerator: generator
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)
        // Both translations displayed; A's replies still gated (never released).
        #expect(await spy.displayedPageSets.count == 2)

        // Release A's replies now, well after B is already the active turn.
        await generator.release("phrase A")
        try? await Task.sleep(for: Self.propagationDelay)

        let final = await spy.displayedPageSets
        #expect(final.count == 2) // no third, stale display update from A
        #expect(!final.contains { pages in pages.contains { $0.contains("A-reply") } })
        #expect(store.session.latestTurn?.originalText == "phrase B")
    }

    /// Same race, one level up: A's *Chat* append (a real, awaited network
    /// call in production) is slow enough to still be in flight when B
    /// finalizes and B's own append starts. Both must complete and land in
    /// history — chat history is a log, not a "latest wins" display — in
    /// the order they actually reach the backend, without either call
    /// corrupting or dropping the other.
    @Test("phrase A's slow Glasses Chat append and phrase B's append never interfere with each other")
    func concurrentGlassesChatAppendsDoNotInterfere() async throws {
        let spy = SpyGlassesTransport()
        let chatService = RecordingAppendChatService(artificialDelay: .milliseconds(40))
        let provider = GlassesChatProvider(chatService: chatService, defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["phrase A", "phrase B"]),
            translator: ScriptedLanguageTranslator(
                languageCodes: ["phrase A": "en", "phrase B": "en"],
                translation: "переклад"
            ),
            chatService: chatService,
            glassesChatProvider: provider
        )

        await service.start()
        try? await Task.sleep(for: .milliseconds(200))

        let appended = await chatService.appendedMessages
        #expect(appended.count == 2)
        #expect(appended.contains { $0.content.contains("phrase A") })
        #expect(appended.contains { $0.content.contains("phrase B") })
    }

    // MARK: - Explicit source-language selection

    /// Isolated `UserDefaults` for every test in this section — `sourceLanguageMode`
    /// persists to `UserDefaults`, and these tests actively call
    /// `setSourceLanguageMode(_:)`; sharing `.standard` across the whole
    /// test target would leak a selection from one test into every other
    /// test in this file (including ones that never touch language mode
    /// at all and assume the `.auto` default).
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "LiveTranslationServiceTests.\(UUID().uuidString)")!
    }

    @Test("explicit English mode bypasses auto language detection entirely — a translator that can never detect anything still succeeds")
    func explicitEnglishBypassesDetection() async throws {
        let spy = SpyGlassesTransport()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["some phrase"]),
            translator: ScriptedLanguageTranslator(languageCodes: [:], translation: "переклад"),
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(.en)

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(await spy.displayedPageSets == [["some phrase\n\nUA: переклад"]])
    }

    @Test("explicit German mode bypasses auto language detection entirely — a translator that can never detect anything still succeeds")
    func explicitGermanBypassesDetection() async throws {
        let spy = SpyGlassesTransport()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["ein Satz"]),
            translator: ScriptedLanguageTranslator(languageCodes: [:], translation: "переклад"),
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(.de)

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(await spy.displayedPageSets == [["ein Satz\n\nUA: переклад"]])
    }

    @Test("explicit Polish mode bypasses auto language detection entirely — a translator that can never detect anything still succeeds")
    func explicitPolishBypassesDetection() async throws {
        let spy = SpyGlassesTransport()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["jakieś zdanie"]),
            translator: ScriptedLanguageTranslator(languageCodes: [:], translation: "переклад"),
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(.pl)

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(await spy.displayedPageSets == [["jakieś zdanie\n\nUA: переклад"]])
    }

    @Test("the selected source language mode persists across LiveTranslationService instances, simulating an app relaunch")
    func sourceLanguageModePersists() async throws {
        let defaults = freshDefaults()
        let service1 = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: []),
            translator: ScriptedLanguageTranslator(languageCodes: [:]),
            defaults: defaults
        )
        #expect(service1.sourceLanguageMode == .auto) // nothing persisted yet
        service1.setSourceLanguageMode(.de)

        // A fresh instance reading the SAME defaults — stands in for the
        // app relaunching, since LiveTranslationService is constructed
        // once at app level in production.
        let service2 = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: []),
            translator: ScriptedLanguageTranslator(languageCodes: [:]),
            defaults: defaults
        )
        #expect(service2.sourceLanguageMode == .de)
    }

    // MARK: - Auto mode detection, locking, and hysteresis

    @Test("Auto detects and locks English from the first confidently-detected utterance")
    func autoLocksEnglish() async throws {
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: ["hello there"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["hello there": "en"], translation: "переклад"),
            agentContextStore: store,
            defaults: freshDefaults()
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(store.session.turns.last?.detectedLanguage == "en")
    }

    @Test("Auto detects and locks German from the first confidently-detected utterance")
    func autoLocksGerman() async throws {
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: ["Guten Tag"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["Guten Tag": "de"], translation: "переклад"),
            agentContextStore: store,
            defaults: freshDefaults()
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(store.session.turns.last?.detectedLanguage == "de")
    }

    @Test("Auto detects and locks Polish from the first confidently-detected utterance")
    func autoLocksPolish() async throws {
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: ["Dzień dobry"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["Dzień dobry": "pl"], translation: "переклад"),
            agentContextStore: store,
            defaults: freshDefaults()
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(store.session.turns.last?.detectedLanguage == "pl")
    }

    /// The core hysteresis regression guard: the translator is scripted so
    /// that if detection were consulted for "okay", it would say English —
    /// the WRONG answer once the session is locked to German. A correctly
    /// implemented lock reuses German instead of trusting that detection,
    /// exactly matching "short ambiguous phrases... must not cause
    /// unnecessary language switching."
    @Test("Auto reuses the locked language for a short ambiguous phrase, even when detection alone would disagree")
    func autoReusesLockForShortAmbiguousPhraseDespiteConflictingDetection() async throws {
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: ["Guten Tag", "okay"], autoFinish: false),
            translator: ScriptedLanguageTranslator(
                languageCodes: ["Guten Tag": "de", "okay": "en"],
                translation: "переклад"
            ),
            agentContextStore: store,
            defaults: freshDefaults()
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(store.session.turns.map(\.detectedLanguage) == ["de", "de"])
    }

    @Test("Auto does not oscillate away from a locked language when a later, longer phrase confidently agrees with it")
    func autoDoesNotOscillateWhenDetectionAgrees() async throws {
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: ["Guten Tag", "Wie geht es dir heute"], autoFinish: false),
            translator: ScriptedLanguageTranslator(
                languageCodes: ["Guten Tag": "de", "Wie geht es dir heute": "de"],
                translation: "переклад"
            ),
            agentContextStore: store,
            defaults: freshDefaults()
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(store.session.turns.map(\.detectedLanguage) == ["de", "de"])
    }

    @Test("Auto switches the lock when a longer, later phrase confidently detects a genuinely different primary language")
    func autoSwitchesOnStrongEvidence() async throws {
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: ["Guten Tag", "How are you doing today"], autoFinish: false),
            translator: ScriptedLanguageTranslator(
                languageCodes: ["Guten Tag": "de", "How are you doing today": "en"],
                translation: "переклад"
            ),
            agentContextStore: store,
            defaults: freshDefaults()
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(store.session.turns.map(\.detectedLanguage) == ["de", "en"])
    }

    @Test("a new Live Translation session resets the Auto lock — a stale lock from a previous session never survives stop()/start()")
    func newSessionResetsAutoLock() async throws {
        let store = AgentContextStore()
        let transcriber = ManualContinuousTranscriber()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(languageCodes: ["Guten Tag": "de", "okay": "en"], translation: "переклад"),
            agentContextStore: store,
            defaults: freshDefaults()
        )

        await service.start()
        await transcriber.emit("Guten Tag")
        try? await Task.sleep(for: Self.propagationDelay)
        #expect(store.session.turns.last?.detectedLanguage == "de")

        await service.stop()
        await service.start() // a new session — the Auto lock must reset

        // "okay" is short/ambiguous. If the German lock had survived,
        // it would be reused as "de"; a correctly reset lock runs
        // detection fresh instead and gets "en".
        await transcriber.emit("okay")
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(store.session.turns.last?.detectedLanguage == "en")
    }

    // MARK: - Per-turn concurrency / "hangs on one phrase" regression guards

    /// The core regression guard for the actual reported bug: before the
    /// per-turn task split, `consume(_:)`'s loop awaited the ENTIRE
    /// pipeline (including translation) for one phrase before it could
    /// even read the next final transcript — a translation that never
    /// returns meant phrase B was never processed AT ALL, no matter how
    /// long the test waits. `translationTimeout` is set far longer than
    /// this test's own wait so it can't be timeout recovery masking the
    /// real fix: B must complete while A's translation task is still
    /// genuinely, unboundedly pending.
    @Test("translation A never returns — phrase B still processes independently, without waiting for A")
    func stuckTranslationDoesNotBlockLaterPhrase() async throws {
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["phrase A", "phrase B"], autoFinish: false),
            translator: HangingLanguageTranslator(
                languageCodes: ["phrase A": "en", "phrase B": "en"],
                hangingTexts: ["phrase A"],
                translation: "переклад"
            ),
            agentContextStore: store,
            translationTimeout: .seconds(3600) // effectively unbounded for this test's lifetime
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        // B completed and displayed even though A's translation task is
        // still (and will remain, for this test's duration) pending. A
        // itself is present in history as an early-appended draft (still
        // `ukrainianTranslation == nil` — the early-append design needed
        // for correct arrival-order history), but was never displayed.
        #expect(store.session.turns.map(\.originalText) == ["phrase A", "phrase B"])
        #expect(store.session.turns.first(where: { $0.originalText == "phrase A" })?.ukrainianTranslation == nil)
        #expect(await spy.displayedPageSets == [["phrase B\n\nUA: переклад"]])
    }

    /// Same guard, one stage later: replies A never return, but that must
    /// never delay or block phrase B's own translation/display — replies
    /// were already decoupled via their own `Task` before this milestone,
    /// but this proves it explicitly, with the new per-turn architecture.
    @Test("replies A never return — phrase B still processes independently, translation is never blocked by stuck reply generation")
    func stuckReplyGenerationDoesNotBlockLaterPhrase() async throws {
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let generator = GatedSuggestedReplyGenerator() // "phrase A" is never release()d
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["phrase A", "phrase B"], autoFinish: false),
            translator: ScriptedLanguageTranslator(
                languageCodes: ["phrase A": "en", "phrase B": "en"],
                translation: "переклад"
            ),
            agentContextStore: store,
            replyGenerator: generator,
            repliesTimeout: .seconds(3600) // effectively unbounded for this test's lifetime
        )

        await service.start()
        try? await Task.sleep(for: Self.propagationDelay)

        // Both phrases translated and displayed normally; A's reply
        // generation is still (and will remain) pending the whole time.
        #expect(store.session.turns.map(\.originalText) == ["phrase A", "phrase B"])
        #expect(await spy.displayedPageSets.count == 2)
    }

    @Test("a translation that times out cleans up after itself — no turn left behind, session stays alive, later phrases still work")
    func translationTimeoutCleansUpCleanly() async throws {
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["phrase A", "phrase B"], autoFinish: false),
            translator: HangingLanguageTranslator(
                languageCodes: ["phrase A": "en", "phrase B": "en"],
                hangingTexts: ["phrase A"],
                translation: "переклад"
            ),
            agentContextStore: store,
            translationTimeout: .milliseconds(50)
        )

        await service.start()
        try? await Task.sleep(for: .milliseconds(300))

        // A timed out: no lingering draft turn, nothing displayed for it.
        // B: entirely normal.
        #expect(store.session.turns.map(\.originalText) == ["phrase B"])
        #expect(await spy.displayedPageSets == [["phrase B\n\nUA: переклад"]])
        #expect(service.state == .listening)
    }

    @Test("suggested-reply generation that times out cleans up after itself — no replies shown, translation for that turn is unaffected")
    func repliesTimeoutCleansUpCleanly() async throws {
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let generator = GatedSuggestedReplyGenerator(repliesByOriginalText: [
            "phrase A": [SuggestedReply(originalLanguageText: "A-reply", ukrainianText: "А-відповідь", ordering: 0)],
        ]) // never release()d — the generator call itself never returns
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["phrase A"], autoFinish: false),
            translator: ScriptedLanguageTranslator(languageCodes: ["phrase A": "en"], translation: "переклад"),
            agentContextStore: store,
            replyGenerator: generator,
            repliesTimeout: .milliseconds(50)
        )

        await service.start()
        try? await Task.sleep(for: .milliseconds(300))

        // Translation displayed normally; replies never arrived (timed
        // out), so no second display call and no replies recorded.
        #expect(await spy.displayedPageSets == [["phrase A\n\nUA: переклад"]])
        #expect(store.session.turns.first?.suggestedReplies.isEmpty == true)
        #expect(service.state == .listening)
    }

    /// Direct regression guard for the sequence-based staleness fix,
    /// exercised at the *translation* level (existing tests already cover
    /// this for replies) — phrase A is spoken first but its translation
    /// is deliberately slower than phrase B's, so B displays first; when
    /// A's translation finally resolves, it must never overwrite B's
    /// already-shown, newer content. Before this fix, the staleness check
    /// compared against "has a newer turn been *spoken*" rather than "has
    /// a newer turn already *displayed*" — which could suppress a turn's
    /// translation entirely even when nothing newer had displayed yet;
    /// this test's shape (A slower, B faster) is exactly the case that
    /// requires the corrected "newest-displayed-wins" comparison to get
    /// right in both directions.
    @Test("phrase A's slower translation, arriving after phrase B's faster one already displayed, never overwrites B on G2")
    func slowerOlderTranslationNeverOverwritesFasterNewerOne() async throws {
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let translator = DelayedLanguageTranslator(
            languageCodes: ["phrase A": "en", "phrase B": "en"],
            delays: ["phrase A": .milliseconds(120)],
            translations: ["phrase A": "А-переклад", "phrase B": "Б-переклад"]
        )
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["phrase A", "phrase B"], autoFinish: false),
            translator: translator,
            agentContextStore: store
        )

        await service.start()
        try? await Task.sleep(for: .milliseconds(220))

        // B displayed (it was faster); A's later-arriving translation was
        // correctly discarded from display — but both turns still exist
        // in history (a log, not "latest wins").
        let displayed = await spy.displayedPageSets
        #expect(displayed.contains(["phrase B\n\nUA: Б-переклад"]))
        #expect(!displayed.contains(["phrase A\n\nUA: А-переклад"]))
        #expect(store.session.turns.map(\.originalText).sorted() == ["phrase A", "phrase B"])
    }

    // MARK: - Streaming translation (major performance pass)

    /// The core streaming behavior: a partial transcript, on its own,
    /// produces a provisional translation and updates G2 in place — no
    /// need to wait for a final. `ScriptedContinuousTranscriber` (no
    /// partials) can't express this; `ManualContinuousTranscriber
    /// .emitPartial(_:)` can.
    @Test("a partial transcript triggers a provisional translation and updates G2 in place")
    func partialTranscriptTriggersProvisionalTranslation() async throws {
        let spy = SpyGlassesTransport()
        let transcriber = ManualContinuousTranscriber()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(languageCodes: ["Where are": "en"], translation: "Куди ви"),
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(.en)

        await service.start()
        await transcriber.emitPartial("Where are")
        try? await Task.sleep(for: .milliseconds(250)) // past the 150ms partial debounce

        #expect(service.currentPartialTranscript == "Where are")
        #expect(service.currentPartialTranslation == "Куди ви")
        #expect(await spy.displayedPageSets == [["Where are\n\nUA: Куди ви"]])
    }

    /// A second, later partial for the same utterance supersedes the
    /// first before its debounce ever fires — only the newest partial's
    /// translation is ever requested, matching "only newest partial
    /// matters, never queue dozens of old requests."
    @Test("a newer partial supersedes an older one before its debounce fires — only the latest text is ever translated/displayed")
    func newerPartialSupersedesOlderBeforeDebounce() async throws {
        let spy = SpyGlassesTransport()
        let transcriber = ManualContinuousTranscriber()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(
                languageCodes: ["Where": "en", "Where are you going": "en"],
                translation: "Куди ви йдете?"
            ),
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(.en)

        await service.start()
        await transcriber.emitPartial("Where")
        try? await Task.sleep(for: .milliseconds(40)) // well under the 150ms debounce
        await transcriber.emitPartial("Where are you going")
        try? await Task.sleep(for: .milliseconds(250))

        #expect(service.currentPartialTranscript == "Where are you going")
        let displayed = await spy.displayedPageSets
        // Exactly one display call — "Where" never got far enough to
        // translate or display anything at all.
        #expect(displayed.count == 1)
        #expect(displayed == [["Where are you going\n\nUA: Куди ви йдете?"]])
    }

    /// The harder case: "Where"'s debounce DOES fire and its (slow)
    /// translation call is genuinely in flight when "Where are you going"
    /// arrives — its own (fast) translation settles first. "Where"'s
    /// stale response, whenever it eventually resolves, must never
    /// overwrite what's already on screen.
    @Test("a stale, slower partial translation response can never overwrite a newer, faster-settling partial's result")
    func stalePartialTranslationNeverOverwritesNewer() async throws {
        let spy = SpyGlassesTransport()
        let transcriber = ManualContinuousTranscriber()
        let translator = DelayedLanguageTranslator(
            languageCodes: ["Where": "en", "Where are you going": "en"],
            delays: ["Where": .milliseconds(400)],
            translations: ["Where": "Де", "Where are you going": "Куди ви йдете?"]
        )
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: translator,
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(.en)

        await service.start()
        await transcriber.emitPartial("Where")
        // Past the 150ms debounce — "Where"'s slow (400ms) translate call
        // is now genuinely in flight, not merely scheduled.
        try? await Task.sleep(for: .milliseconds(220))
        await transcriber.emitPartial("Where are you going")
        // Past both the new debounce AND "Where"'s full 400ms delay.
        try? await Task.sleep(for: .milliseconds(600))

        #expect(service.currentPartialTranscript == "Where are you going")
        #expect(service.currentPartialTranslation == "Куди ви йдете?")
        let displayed = await spy.displayedPageSets
        #expect(!displayed.contains { pages in pages.contains { $0.contains("Де") } })
        #expect(displayed.last == ["Where are you going\n\nUA: Куди ви йдете?"])
    }

    /// Once the utterance's final arrives, it supersedes ALL provisional
    /// (partial) state — the authoritative final translation is what
    /// remains, and the streaming state is cleared for the next
    /// utterance.
    @Test("the final translation supersedes provisional partial state and clears it for the next utterance")
    func finalTranslationSupersedesProvisionalState() async throws {
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let transcriber = ManualContinuousTranscriber()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(
                languageCodes: ["Where are": "en", "Where are you going": "en"],
                translation: "Куди ви йдете?"
            ),
            agentContextStore: store,
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(.en)

        await service.start()
        await transcriber.emitPartial("Where are")
        try? await Task.sleep(for: .milliseconds(250))
        #expect(service.currentPartialTranscript != nil)

        await transcriber.emit("Where are you going")
        try? await Task.sleep(for: .milliseconds(100))

        #expect(service.currentPartialTranscript == nil)
        #expect(service.currentPartialTranslation == nil)
        #expect(service.finalTranscript == "Where are you going")
        #expect(service.finalTranslation == "Куди ви йдете?")
        #expect(store.session.turns.map(\.originalText) == ["Where are you going"])
    }

    /// The explicit "no ConversationTurn history for every partial"
    /// requirement — several partials for one utterance must never
    /// accumulate into `agentContextStore.session.turns`; only the final
    /// does, and exactly once.
    @Test("partials never create ConversationTurn history entries — only the final does, exactly once")
    func partialsNeverCreateHistoryEntries() async throws {
        let store = AgentContextStore()
        let transcriber = ManualContinuousTranscriber()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(
                languageCodes: ["W": "en", "Wh": "en", "Whe": "en", "Where are you going": "en"],
                translation: "Куди ви йдете?"
            ),
            agentContextStore: store,
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(.en)

        await service.start()
        await transcriber.emitPartial("W")
        await transcriber.emitPartial("Wh")
        await transcriber.emitPartial("Whe")
        try? await Task.sleep(for: .milliseconds(250))
        #expect(store.session.turns.isEmpty) // still nothing — all partials so far

        await transcriber.emit("Where are you going")
        try? await Task.sleep(for: .milliseconds(100))

        #expect(store.session.turns.count == 1)
        #expect(store.session.turns.first?.originalText == "Where are you going")
    }

    /// The Glasses Chat side of the same requirement: partials must never
    /// reach Chat persistence at all — only the final's own append call
    /// does, exactly once.
    @Test("partials are never persisted to Glasses Chat — only the final turn is, exactly once")
    func partialsNeverReachGlassesChat() async throws {
        let chatService = RecordingAppendChatService()
        let provider = GlassesChatProvider(chatService: chatService, defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        let transcriber = ManualContinuousTranscriber()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(
                languageCodes: ["Where are": "en", "Where are you going": "en"],
                translation: "Куди ви йдете?"
            ),
            chatService: chatService,
            glassesChatProvider: provider,
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(.en)

        await service.start()
        await transcriber.emitPartial("Where are")
        try? await Task.sleep(for: .milliseconds(250))
        #expect(await chatService.appendedMessages.isEmpty) // partial alone: nothing persisted yet

        await transcriber.emit("Where are you going")
        try? await Task.sleep(for: .milliseconds(100))

        let appended = await chatService.appendedMessages
        #expect(appended.count == 1)
        #expect(appended.first?.content.contains("Where are you going") == true)
    }

    /// Reply generation for an OLDER, already-finalized turn must never
    /// delay or block a NEWER utterance's streaming partial translation
    /// — translation has absolute priority over replies (Section C).
    @Test("suggested-reply generation for an older turn never blocks or delays a newer utterance's streaming partial translation")
    func repliesForOlderTurnNeverBlockNewerPartial() async throws {
        let spy = SpyGlassesTransport()
        let generator = GatedSuggestedReplyGenerator() // never released — replies for "Guten Tag" hang forever
        let transcriber = ManualContinuousTranscriber()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(
                languageCodes: ["Guten Tag": "de", "Wie geht": "de"],
                translation: "переклад"
            ),
            replyGenerator: generator,
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(.de)

        await service.start()
        await transcriber.emit("Guten Tag")
        try? await Task.sleep(for: .milliseconds(60))
        #expect(await spy.displayedPageSets.count == 1) // translated; replies still gated/pending forever

        // A brand-new utterance's partial must still stream normally.
        await transcriber.emitPartial("Wie geht")
        try? await Task.sleep(for: .milliseconds(250))

        #expect(service.currentPartialTranscript == "Wie geht")
        #expect(service.currentPartialTranslation == "переклад")
        #expect(await spy.displayedPageSets.count == 2)
    }

    // MARK: - Explicit language-selection state bug ("select a language" repeating loop)

    /// Physical bug: selecting EN/DE/PL never actually reached the real
    /// on-device `TranslationSession` (only `RootView`'s own doc comment
    /// and `LiveTranslationService.resolvedSourceLanguageCode`'s doc
    /// comment tell that full story — this file can't touch the real
    /// `TranslationSession` at all). What IS fully unit-testable, and
    /// what these tests pin down: `sourceLanguageMode` and
    /// `resolvedSourceLanguageCode` update synchronously, immediately,
    /// the instant `setSourceLanguageMode(_:)` is called — no delay, no
    /// restart, no async gap where a stale value could leak through.
    @Test("selecting EN updates the active service's mode and resolved language immediately")
    func selectingEnglishUpdatesImmediately() {
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: []),
            translator: ScriptedLanguageTranslator(languageCodes: [:]),
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(.en)
        #expect(service.sourceLanguageMode == .en)
        #expect(service.resolvedSourceLanguageCode == "en")
    }

    @Test("selecting DE updates the active service's mode and resolved language immediately")
    func selectingGermanUpdatesImmediately() {
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: []),
            translator: ScriptedLanguageTranslator(languageCodes: [:]),
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(.de)
        #expect(service.sourceLanguageMode == .de)
        #expect(service.resolvedSourceLanguageCode == "de")
    }

    @Test("selecting PL updates the active service's mode and resolved language immediately")
    func selectingPolishUpdatesImmediately() {
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: []),
            translator: ScriptedLanguageTranslator(languageCodes: [:]),
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(.pl)
        #expect(service.sourceLanguageMode == .pl)
        #expect(service.resolvedSourceLanguageCode == "pl")
    }

    @Test(
        "explicit mode's PARTIAL translation never invokes language detection, for every explicit language",
        arguments: [SourceLanguageMode.en, .de, .pl]
    )
    func explicitPartialNeverInvokesDetection(mode: SourceLanguageMode) async throws {
        let recorder = RecordingLanguageTranslator(translation: "переклад")
        let transcriber = ManualContinuousTranscriber()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: transcriber,
            translator: recorder,
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(mode)

        await service.start()
        await transcriber.emitPartial("some phrase")
        try? await Task.sleep(for: .milliseconds(250))

        #expect(await recorder.detectionCallCount == 0)
        let translateCalls = await recorder.translateCalls
        #expect(translateCalls.count == 1)
        #expect(translateCalls.first?.languageCode == mode.explicitLanguageCode)
    }

    @Test(
        "explicit mode's FINAL translation never invokes language detection, for every explicit language",
        arguments: [SourceLanguageMode.en, .de, .pl]
    )
    func explicitFinalNeverInvokesDetection(mode: SourceLanguageMode) async throws {
        let recorder = RecordingLanguageTranslator(translation: "переклад")
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: ["some phrase"]),
            translator: recorder,
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(mode)

        await service.start()
        try? await Task.sleep(for: .milliseconds(100))

        #expect(await recorder.detectionCallCount == 0)
        let translateCalls = await recorder.translateCalls
        #expect(translateCalls.count == 1)
        #expect(translateCalls.first?.languageCode == mode.explicitLanguageCode)
    }

    /// The literal "a detection failure must not be capable of producing
    /// a language-selection-required state while explicit mode is
    /// active" requirement: `RecordingLanguageTranslator`'s default
    /// `detectionResult: nil` simulates TOTAL, permanent detection
    /// failure — the worst case Apple's own on-device detector could ever
    /// produce. Explicit mode must still translate and display normally,
    /// completely unaffected, because it never asks the detector
    /// anything in the first place.
    @Test("total detection failure cannot block or degrade explicit-mode translation — detection is never consulted")
    func detectionFailureCannotAffectExplicitMode() async throws {
        let recorder = RecordingLanguageTranslator(translation: "переклад") // detectionResult defaults to nil
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["some phrase"], autoFinish: false),
            translator: recorder,
            agentContextStore: store,
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(.en)

        await service.start()
        try? await Task.sleep(for: .milliseconds(100))

        #expect(await recorder.detectionCallCount == 0)
        #expect(store.session.turns.map(\.originalText) == ["some phrase"])
        #expect(await spy.displayedPageSets == [["some phrase\n\nUA: переклад"]])
        #expect(service.state == .listening)
    }

    @Test("switching Auto → EN while the session is already running affects the very next partial immediately")
    func switchingAutoToExplicitAffectsNextPartialImmediately() async throws {
        let recorder = RecordingLanguageTranslator(translation: "переклад")
        let transcriber = ManualContinuousTranscriber()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: transcriber,
            translator: recorder,
            defaults: freshDefaults()
        )
        #expect(service.sourceLanguageMode == .auto)

        await service.start()
        service.setSourceLanguageMode(.en)
        await transcriber.emitPartial("some phrase")
        try? await Task.sleep(for: .milliseconds(250))

        #expect(await recorder.detectionCallCount == 0)
        let translateCalls = await recorder.translateCalls
        #expect(translateCalls.first?.languageCode == "en")
    }

    @Test("switching EN → DE mid-session affects the very next partial immediately — no restart needed")
    func switchingExplicitLanguagesAffectsNextPartialImmediately() async throws {
        let recorder = RecordingLanguageTranslator(translation: "переклад")
        let transcriber = ManualContinuousTranscriber()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: transcriber,
            translator: recorder,
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(.en)
        await service.start()

        await transcriber.emitPartial("first phrase")
        try? await Task.sleep(for: .milliseconds(250))
        #expect(await recorder.translateCalls.last?.languageCode == "en")

        // Switch mid-session — no stop()/start() anywhere in this test.
        service.setSourceLanguageMode(.de)
        await transcriber.emit("first phrase") // finalize so the next utterance starts clean
        try? await Task.sleep(for: .milliseconds(60))

        await transcriber.emitPartial("second phrase")
        try? await Task.sleep(for: .milliseconds(250))

        #expect(await recorder.translateCalls.last?.languageCode == "de")
        #expect(await recorder.detectionCallCount == 0)
    }

    @Test("an explicit selection survives multiple consecutive turns — every one resolves to the same language")
    func explicitSelectionSurvivesMultipleTurns() async throws {
        let recorder = RecordingLanguageTranslator(translation: "переклад")
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: ["one", "two", "three"], autoFinish: false),
            translator: recorder,
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(.de)

        await service.start()
        try? await Task.sleep(for: .milliseconds(150))

        #expect(await recorder.detectionCallCount == 0)
        let languages = await recorder.translateCalls.map(\.languageCode)
        #expect(languages == ["de", "de", "de"])
        #expect(service.sourceLanguageMode == .de)
    }

    @Test("an explicit selection survives suggested replies being generated and displayed")
    func explicitSelectionSurvivesReplies() async throws {
        let recorder = RecordingLanguageTranslator(translation: "переклад")
        let generator = FakeSuggestedReplyGenerator(defaultReplies: [
            SuggestedReply(originalLanguageText: "Sure", ukrainianText: "Так", ordering: 0),
        ])
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: ["Guten Tag"]),
            translator: recorder,
            replyGenerator: generator,
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(.de)

        await service.start()
        try? await Task.sleep(for: .milliseconds(100)) // translation + replies both settle

        #expect(service.sourceLanguageMode == .de)
        #expect(service.resolvedSourceLanguageCode == "de")
        #expect(await recorder.detectionCallCount == 0)
    }

    @Test("an explicit selection survives the streaming partial-to-final transition for the same utterance")
    func explicitSelectionSurvivesPartialToFinalTransition() async throws {
        let recorder = RecordingLanguageTranslator(translation: "переклад")
        let transcriber = ManualContinuousTranscriber()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: transcriber,
            translator: recorder,
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(.pl)
        await service.start()

        await transcriber.emitPartial("Gdzie")
        try? await Task.sleep(for: .milliseconds(250))
        await transcriber.emit("Gdzie jesteś")
        try? await Task.sleep(for: .milliseconds(100))

        #expect(await recorder.detectionCallCount == 0)
        let languages = await recorder.translateCalls.map(\.languageCode)
        #expect(languages.allSatisfy { $0 == "pl" })
        #expect(service.finalTranscript == "Gdzie jesteś")
    }

    /// Auto mode's own detection failure (an undetectable phrase — no
    /// entry in `languageCodes`, matching `LanguageTranslating`'s
    /// "uncertain ⇒ nil" contract) must never loop, block, or interrupt
    /// listening — it just drops that one phrase and keeps going.
    @Test("repeated Auto-mode detection failures never block listening or create any kind of prompt loop")
    func autoDetectionFailureNeverLoops() async throws {
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(
                finals: ["mmm", "uhh", "hmm"], // none present in languageCodes below — all undetectable
                autoFinish: false
            ),
            translator: ScriptedLanguageTranslator(languageCodes: [:]),
            defaults: freshDefaults()
        )

        await service.start()
        try? await Task.sleep(for: .milliseconds(150))

        // Nothing was ever detectable, but the session is still healthy,
        // still listening, and never entered any error state.
        #expect(service.state == .listening)
    }

    /// The literal end-to-end recovery scenario: Auto fails to detect,
    /// the user picks EN (exactly what the "select a language" surface
    /// is for), and the NEXT phrase must translate correctly without
    /// stopping/restarting Live Translation at all.
    @Test("after an Auto detection failure, selecting EN lets the next phrase translate without restarting the session")
    func autoFailureThenExplicitSelectionRecoversWithoutRestart() async throws {
        let recorder = RecordingLanguageTranslator(detectionResult: nil, translation: "переклад")
        let transcriber = ManualContinuousTranscriber()
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: transcriber,
            translator: recorder,
            agentContextStore: store,
            defaults: freshDefaults()
        )

        await service.start()
        await transcriber.emit("undetectable phrase")
        try? await Task.sleep(for: .milliseconds(60))
        #expect(store.session.turns.isEmpty) // Auto couldn't determine a language — dropped, not stuck

        // No stop()/start() here — the exact "must not require restarting
        // Live Translation" requirement.
        service.setSourceLanguageMode(.en)
        await transcriber.emit("now it works")
        try? await Task.sleep(for: .milliseconds(60))

        #expect(store.session.turns.map(\.originalText) == ["now it works"])
        #expect(await recorder.translateCalls.last?.languageCode == "en")
        #expect(service.state == .listening)
    }
}

/// Records every `appendMessage` call — used to verify "Glasses Chat"
/// integration without a real backend. `createChat`/`fetchChat` behave
/// like a normal, empty, always-succeeding backend so `GlassesChatProvider`
/// resolves a chat the first time it's asked.
private actor RecordingAppendChatService: ChatServicing {
    private(set) var appendedMessages: [Message] = []
    private var chatsByID: [Chat.ID: Chat] = [:]
    private let artificialDelay: Duration

    init(artificialDelay: Duration = .zero) {
        self.artificialDelay = artificialDelay
    }

    func fetchChats() async throws -> [Chat] { Array(chatsByID.values) }

    func fetchChat(id: Chat.ID) async throws -> Chat {
        guard let chat = chatsByID[id] else { throw FailingChatService.Failure() }
        return chat
    }

    func createChat(title: String) async throws -> Chat {
        let chat = Chat(title: title)
        chatsByID[chat.id] = chat
        return chat
    }

    func renameChat(id: Chat.ID, title: String) async throws -> Chat { Chat(id: id, title: title) }
    func deleteChat(id: Chat.ID) async throws { chatsByID[id] = nil }
    func fetchMessages(chatID: Chat.ID) async throws -> [Message] { [] }

    func appendMessage(chatID: Chat.ID, role: MessageRole, content: String) async throws -> Message {
        if artificialDelay > .zero { try? await Task.sleep(for: artificialDelay) }
        let message = Message(chatID: chatID, role: role, content: content)
        appendedMessages.append(message)
        return message
    }

    nonisolated func streamReply(chatID: Chat.ID, content: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
