import Testing
import Foundation
import SwiftData
@testable import EvenAI

/// A brand-new, isolated in-memory SwiftData container — backs
/// `LocalGlassesChatStore` in every test below that exercises the
/// (local-first, no-network) Glasses Chat append path, so tests never
/// share persisted state with each other or the real app.
private func freshGlassesChatStore() -> LocalGlassesChatStore {
    let schema = Schema([ChatEntity.self, MessageEntity.self])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: schema, configurations: [configuration])
    return LocalGlassesChatStore(modelContainer: container)
}

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
    private static let propagationDelay: Duration = .milliseconds(250)

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
        // The second "hello" now also carries one page of look-back
        // context (the first "hello" turn) — see
        // GlassesPresentationLayer.conversationPages(for:previousTurn:).
        #expect(await spy.displayedPageSets == [
            ["hello\n\nUA: привіт"],
            ["hello\n\nUA: привіт", "Previous:\nhello\n\nUA: привіт"],
        ])
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

    @Test("a finalized turn is appended to the Glasses Chat as a real, LOCALLY persisted message — no network/ChatServicing involved")
    func turnIsAppendedToGlassesChat() async throws {
        let spy = SpyGlassesTransport()
        let store = freshGlassesChatStore()
        let provider = GlassesChatProvider(localStore: store, defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["hello there"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["hello there": "en"], translation: "привіт"),
            glassesChatProvider: provider
        )

        await service.start()
        try? await Task.sleep(for: .milliseconds(60))

        let chat = try await provider.findOrCreateGlassesChat()
        let appended = await store.fetchMessages(chatID: chat.id)
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
    @Test("phrase A's Glasses Chat append and phrase B's append never interfere with each other")
    func concurrentGlassesChatAppendsDoNotInterfere() async throws {
        let spy = SpyGlassesTransport()
        let store = freshGlassesChatStore()
        let provider = GlassesChatProvider(localStore: store, defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["phrase A", "phrase B"]),
            translator: ScriptedLanguageTranslator(
                languageCodes: ["phrase A": "en", "phrase B": "en"],
                translation: "переклад"
            ),
            glassesChatProvider: provider
        )

        await service.start()
        try? await Task.sleep(for: .milliseconds(200))

        let chat = try await provider.findOrCreateGlassesChat()
        let appended = await store.fetchMessages(chatID: chat.id)
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
        // Past AdaptiveStreamingTranslationBuffer's 350ms stability
        // window (plus tick granularity/translate/display overhead) —
        // no punctuation here, so stability (a pause) is what fires it.
        try? await Task.sleep(for: .milliseconds(600))

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
        try? await Task.sleep(for: .milliseconds(40)) // well under the 350ms stability window
        await transcriber.emitPartial("Where are you going")
        try? await Task.sleep(for: .milliseconds(600)) // past the 350ms stability window from here

        #expect(service.currentPartialTranscript == "Where are you going")
        let displayed = await spy.displayedPageSets
        // Exactly one display call — "Where" never got far enough to
        // translate or display anything at all.
        #expect(displayed.count == 1)
        #expect(displayed == [["Where are you going\n\nUA: Куди ви йдете?"]])
    }

    /// The harder case: "Where"'s chunk becomes ready and its (very slow)
    /// translation call is genuinely in flight when "Where are you going"
    /// arrives — its own (fast, undelayed) translation settles first.
    /// "Where"'s stale response, whenever it eventually resolves, must
    /// never overwrite what's already on screen. "Where"'s artificial
    /// delay (1200ms) is deliberately much longer than the ~450ms it
    /// takes "Where are you going" to become ready and resolve, so the
    /// two results are never a close enough race to make this test flaky
    /// — the point is proving correctness with a comfortable margin, not
    /// finding the exact timing boundary.
    @Test("a stale, slower partial translation response can never overwrite a newer, faster-settling partial's result")
    func stalePartialTranslationNeverOverwritesNewer() async throws {
        let spy = SpyGlassesTransport()
        let transcriber = ManualContinuousTranscriber()
        let translator = DelayedLanguageTranslator(
            languageCodes: ["Where": "en", "Where are you going": "en"],
            delays: ["Where": .milliseconds(1200)],
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
        // Past the 350ms stability window (plus tick granularity) —
        // "Where"'s slow (1200ms) translate call is now genuinely in
        // flight, not merely scheduled or still buffered.
        try? await Task.sleep(for: .milliseconds(500))
        await transcriber.emitPartial("Where are you going")
        // Long enough for "Where are you going" to become ready, translate
        // (instantly — no delay scripted for it) and display, AND for
        // "Where"'s full 1200ms delay (started around the 500ms mark) to
        // have elapsed too — proving its stale result never landed.
        try? await Task.sleep(for: .milliseconds(1400))

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
        let store = freshGlassesChatStore()
        let provider = GlassesChatProvider(localStore: store, defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        let transcriber = ManualContinuousTranscriber()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(
                languageCodes: ["Where are": "en", "Where are you going": "en"],
                translation: "Куди ви йдете?"
            ),
            glassesChatProvider: provider,
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(.en)

        await service.start()
        await transcriber.emitPartial("Where are")
        try? await Task.sleep(for: .milliseconds(250))
        let chat = try await provider.findOrCreateGlassesChat()
        #expect(await store.fetchMessages(chatID: chat.id).isEmpty) // partial alone: nothing persisted yet

        await transcriber.emit("Where are you going")
        try? await Task.sleep(for: .milliseconds(100))

        let appended = await store.fetchMessages(chatID: chat.id)
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
        try? await Task.sleep(for: .milliseconds(600))

        #expect(service.currentPartialTranscript == "Wie geht")
        #expect(service.currentPartialTranslation == "переклад")
        #expect(await spy.displayedPageSets.count == 2)
    }

    // MARK: - Adaptive phrase streaming (word-by-word regression guards)

    /// End-to-end regression guard for the physically-reported bug: a
    /// long sentence spoken continuously, word by word, must NOT produce
    /// one translation request per word — `AdaptiveStreamingTranslationBufferTests`
    /// covers the pure buffer logic in isolation; this proves the same
    /// holds once it's wired into the real `LiveTranslationService`
    /// pipeline (language resolution, translate call dispatch, display).
    @Test("a long sentence spoken as many rapid partials does not translate every fragment — far fewer, semantically fuller requests")
    func rapidWordByWordPartialsDoNotEachTranslate() async throws {
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

        let words = ["How", "are", "you", "going", "to", "get", "there", "tomorrow"]
        var accumulated = ""
        for word in words {
            accumulated += (accumulated.isEmpty ? "" : " ") + word
            await transcriber.emitPartial(accumulated)
            try? await Task.sleep(for: .milliseconds(80)) // fast continuous speech — well under the 350ms stability window
        }
        // Let the final accumulated (unpunctuated) text settle via the
        // stability window now that the "speaker" has stopped.
        try? await Task.sleep(for: .milliseconds(600))

        let translateCalls = await recorder.translateCalls
        // Nowhere near "one request per word" (8 words) — realistically
        // just the one final stable chunk once the rapid growth stops.
        #expect(translateCalls.count <= 2)
        #expect(translateCalls.last?.text == "How are you going to get there tomorrow")
    }

    /// A long, continuous, never-pausing run of speech must still update
    /// periodically (the max-latency budget), never silently falling
    /// behind and never queuing up translation requests — at most one
    /// streaming request is ever outstanding at a time.
    @Test("continuous fast speech with no pauses produces a small, bounded number of chunk translations, not an unbounded queue")
    func continuousFastSpeechNeverQueuesUnboundedRequests() async throws {
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

        var accumulated = ""
        // 30 words, 80ms apart — 2.4 seconds of continuous fast speech,
        // never pausing long enough to trigger stability on its own.
        for index in 1...30 {
            accumulated += (accumulated.isEmpty ? "" : " ") + "word\(index)"
            await transcriber.emitPartial(accumulated)
            try? await Task.sleep(for: .milliseconds(80))
        }
        try? await Task.sleep(for: .milliseconds(600)) // let the final chunk settle

        let translateCalls = await recorder.translateCalls
        // ~2.4s of speech / ~0.9s max-latency budget ≈ 3-4 periodic
        // chunks, plus the final settle — nowhere near 30 (one per word).
        #expect(translateCalls.count >= 2)
        #expect(translateCalls.count <= 6)
    }

    /// Suggested replies must be generated from the FINAL, authoritative
    /// turn's full semantic content — never from a tiny streaming
    /// fragment. Proven by checking exactly what text the reply
    /// generator actually received.
    @Test("suggested replies are generated from the final semantic turn, never from a partial fragment")
    func repliesUseFinalSemanticContentNotPartialFragments() async throws {
        let generator = FakeSuggestedReplyGenerator(defaultReplies: [
            SuggestedReply(originalLanguageText: "Sure", ukrainianText: "Так", ordering: 0),
        ])
        let transcriber = ManualContinuousTranscriber()
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(
                languageCodes: ["How": "en", "How are you going to get there tomorrow": "en"],
                translation: "переклад"
            ),
            replyGenerator: generator,
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(.en)
        await service.start()

        // A partial fragment streams first...
        await transcriber.emitPartial("How")
        try? await Task.sleep(for: .milliseconds(500))
        // ...then the full final arrives.
        await transcriber.emit("How are you going to get there tomorrow")
        try? await Task.sleep(for: .milliseconds(100))

        let calls = await generator.calls
        #expect(calls.count == 1)
        #expect(calls.first?.turn.originalText == "How are you going to get there tomorrow")
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
        try? await Task.sleep(for: .milliseconds(600))

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
        try? await Task.sleep(for: .milliseconds(600))

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
        try? await Task.sleep(for: .milliseconds(600))
        #expect(await recorder.translateCalls.last?.languageCode == "en")

        // Switch mid-session — no stop()/start() anywhere in this test.
        service.setSourceLanguageMode(.de)
        await transcriber.emit("first phrase") // finalize so the next utterance starts clean
        try? await Task.sleep(for: .milliseconds(60))

        await transcriber.emitPartial("second phrase")
        try? await Task.sleep(for: .milliseconds(600))

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
        try? await Task.sleep(for: .milliseconds(600))
        await transcriber.emit("Gdzie jesteś")
        try? await Task.sleep(for: .milliseconds(100))

        #expect(await recorder.detectionCallCount == 0)
        let languages = await recorder.translateCalls.map(\.languageCode)
        #expect(languages.count == 2) // the partial's chunk, then the final
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

    // MARK: - Conversation Mode: follow-live / manual G2 navigation

    @Test("a new session always starts with followLive true")
    func sessionStartsFollowingLive() async throws {
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: []),
            translator: ScriptedLanguageTranslator(languageCodes: [:]),
            defaults: freshDefaults()
        )
        await service.start()
        #expect(service.followLive)
    }

    @Test("navigating G2 to a non-live page (index > 0) disables followLive")
    func navigatingAwayDisablesFollowLive() async throws {
        let spy = SpyGlassesTransport()
        let transcriber = ManualContinuousTranscriber()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(languageCodes: ["first phrase": "en", "second phrase": "en"], translation: "переклад"),
            defaults: freshDefaults()
        )
        await service.start()
        // Classification is now semantic, derived from
        // `agentContextStore.session` — it needs an actual live turn
        // (and, to land on a genuine HISTORY target rather than a
        // no-op, a turn before it) to have anything to classify a
        // non-zero index against, matching what real hardware would
        // require too (nothing to swipe to otherwise).
        await transcriber.emit("first phrase")
        await transcriber.emit("second phrase")
        try? await Task.sleep(for: .milliseconds(100))

        await spy.simulateNavigation(.pageChanged(index: 1))
        try? await Task.sleep(for: .milliseconds(100))

        #expect(!service.followLive)
    }

    @Test("returning to page 0 re-enables followLive")
    func returningToPageZeroReenablesFollowLive() async throws {
        let spy = SpyGlassesTransport()
        let transcriber = ManualContinuousTranscriber()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(languageCodes: ["first phrase": "en", "second phrase": "en"], translation: "переклад"),
            defaults: freshDefaults()
        )
        await service.start()
        await transcriber.emit("first phrase")
        await transcriber.emit("second phrase")
        try? await Task.sleep(for: .milliseconds(100))

        await spy.simulateNavigation(.pageChanged(index: 1))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!service.followLive)

        await spy.simulateNavigation(.pageChanged(index: 0))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(service.followLive)
    }

    @Test("a double-tap (returnToLiveRequested) re-enables followLive even from a deep page")
    func doubleTapReenablesFollowLive() async throws {
        let spy = SpyGlassesTransport()
        let transcriber = ManualContinuousTranscriber()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(languageCodes: ["first phrase": "en", "second phrase": "en"], translation: "переклад"),
            defaults: freshDefaults()
        )
        await service.start()
        await transcriber.emit("first phrase")
        await transcriber.emit("second phrase")
        try? await Task.sleep(for: .milliseconds(100))

        await spy.simulateNavigation(.pageChanged(index: 3))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!service.followLive)

        await spy.simulateNavigation(.returnToLiveRequested)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(service.followLive)
    }

    /// The core Conversation Mode guarantee for DELIBERATE history
    /// browsing: navigating onto the trailing look-back page (the
    /// previous turn's context) must never stop listening or
    /// translating — new turns keep arriving and keep being recorded in
    /// history — they just aren't pushed to G2's display while the user
    /// is deliberately reading something else. Contrast with
    /// `newSpeechDuringReplyBrowsingReturnsToLive` below: THIS is
    /// `.browsingHistory`, which new speech must NOT override.
    @Test("browsing HISTORY (the trailing look-back page): new speech still translates and persists, but G2's display is not overwritten")
    func newTurnsStillProcessWhileBrowsingHistory() async throws {
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let transcriber = ManualContinuousTranscriber()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(
                languageCodes: ["first phrase": "en", "second phrase": "en", "third phrase": "en"],
                translation: "переклад"
            ),
            agentContextStore: store,
            defaults: freshDefaults()
        )
        await service.start()
        await transcriber.emit("first phrase")
        try? await Task.sleep(for: .milliseconds(30))
        // The second turn's own display includes one page of look-back
        // context for the first turn — page 1 of THIS page set is the
        // genuine trailing HISTORY page, not a reply page.
        await transcriber.emit("second phrase")
        try? await Task.sleep(for: .milliseconds(30))
        #expect(service.followLive)

        await spy.simulateNavigation(.pageChanged(index: 1))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!service.followLive)
        // Semantic, not positional: browsing history is anchored to the
        // FIRST turn's own identity, not "whatever page 1 happened to
        // be" — see `DisplayMode`'s own doc comment.
        guard case .browsingHistory(let anchorTurnID) = service.displayMode else {
            Issue.record("expected .browsingHistory, got \(service.displayMode)")
            return
        }
        #expect(anchorTurnID == store.session.turns.first(where: { $0.originalText == "first phrase" })?.id)
        let displayCountWhileAway = await spy.displayedPageSets.count

        // A third turn arrives while the user is deliberately browsing
        // history — must still translate and persist...
        await transcriber.emit("third phrase")
        try? await Task.sleep(for: .milliseconds(30))

        #expect(store.session.turns.map(\.originalText) == ["first phrase", "second phrase", "third phrase"])
        #expect(store.session.turns.last?.ukrainianTranslation == "переклад")
        // ...but G2's display, which the user deliberately navigated to
        // review, must not have been touched — unlike reply browsing.
        #expect(await spy.displayedPageSets.count == displayCountWhileAway)
        guard case .browsingHistory(let anchorTurnIDAfter) = service.displayMode else {
            Issue.record("expected .browsingHistory to persist, got \(service.displayMode)")
            return
        }
        #expect(anchorTurnIDAfter == anchorTurnID)
    }

    /// The core Conversation Mode guarantee for reply browsing: unlike
    /// deliberate history browsing above, reply pages are temporary,
    /// assistive UI for the turn that just finished — new speech must
    /// IMMEDIATELY reclaim the live display, with no double-tap required.
    @Test("browsing REPLY pages: new speech automatically reclaims the live display — no double-tap required")
    func newSpeechDuringReplyBrowsingReturnsToLive() async throws {
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let transcriber = ManualContinuousTranscriber()
        let generator = FakeSuggestedReplyGenerator(defaultReplies: [
            SuggestedReply(originalLanguageText: "Sure", ukrainianText: "Так", ordering: 0),
            SuggestedReply(originalLanguageText: "No thanks", ukrainianText: "Ні, дякую", ordering: 1),
        ])
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(
                languageCodes: ["first phrase": "en", "second phrase": "en"],
                translation: "переклад"
            ),
            agentContextStore: store,
            replyGenerator: generator,
            defaults: freshDefaults()
        )
        await service.start()
        await transcriber.emit("first phrase")
        // Let both the translation and the two-reply generation settle
        // — TWO reply pages means page 1 is a genuine reply page,
        // distinct from page 0 (a single reply stays on page 0 alongside
        // the header — see `GlassesPresentationLayer.pages(for:)`).
        try? await Task.sleep(for: .milliseconds(80))
        #expect(store.session.turns.first?.suggestedReplies.count == 2)

        // Swipe onto reply page 1 — still part of turn 1's own page set,
        // not history (there's no previous turn yet). Page 0 already
        // shows `suggestedReplies[0]` merged with the live header (see
        // `GlassesPresentationLayer.pages(for:)`); page 1 is the first
        // page distinctly showing `suggestedReplies[1]`.
        await spy.simulateNavigation(.pageChanged(index: 1))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!service.followLive)
        // Semantic, not positional: this is turn 1's own reply index 1,
        // not "whatever page 1 happened to be" — see `DisplayMode`'s own
        // doc comment.
        guard case .browsingReplies(let turnID, let replyIndex) = service.displayMode else {
            Issue.record("expected .browsingReplies, got \(service.displayMode)")
            return
        }
        #expect(turnID == store.session.turns.first?.id)
        #expect(replyIndex == 1)
        let displayCountWhileBrowsingReplies = await spy.displayedPageSets.count

        // New speech starts — must IMMEDIATELY reclaim the live display.
        await transcriber.emit("second phrase")
        try? await Task.sleep(for: .milliseconds(30))

        #expect(service.displayMode == .followLive)
        #expect(store.session.turns.map(\.originalText) == ["first phrase", "second phrase"])
        // The second turn's own translation WAS pushed to G2 — display
        // count grew, unlike the history-browsing case above.
        let finalCount = await spy.displayedPageSets.count
        #expect(finalCount > displayCountWhileBrowsingReplies)
        #expect(await spy.displayedPageSets.last?.first?.contains("second phrase") == true)
    }

    @Test("returning to live redisplays the freshest available content")
    func returningToLiveRedisplaysFreshContent() async throws {
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let transcriber = ManualContinuousTranscriber()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(languageCodes: ["hello there": "en"], translation: "привіт"),
            agentContextStore: store,
            defaults: freshDefaults()
        )
        await service.start()
        await transcriber.emit("hello there")
        try? await Task.sleep(for: .milliseconds(60))
        let countAfterFirstTurn = await spy.displayedPageSets.count

        await spy.simulateNavigation(.pageChanged(index: 1))
        try? await Task.sleep(for: .milliseconds(30))

        await spy.simulateNavigation(.returnToLiveRequested)
        try? await Task.sleep(for: .milliseconds(30))

        // Returning to live triggers a fresh redisplay, even with no new
        // turn having arrived — this is the "catch up" behavior.
        let finalCount = await spy.displayedPageSets.count
        #expect(finalCount > countAfterFirstTurn)
        #expect(await spy.displayedPageSets.last == ["hello there\n\nUA: привіт"])
    }

    // MARK: - Conversation Mode: audio source selection

    @Test("audio source defaults to G2 mic")
    func audioSourceDefaultsToG2Mic() {
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: []),
            translator: ScriptedLanguageTranslator(languageCodes: [:]),
            defaults: freshDefaults()
        )
        #expect(service.audioSource == .g2Mic)
    }

    @Test("starting a session applies the persisted audio source preference before enabling the mic")
    func startAppliesAudioSourcePreference() async throws {
        let spy = SpyGlassesTransport()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: []),
            translator: ScriptedLanguageTranslator(languageCodes: [:]),
            defaults: freshDefaults()
        )
        service.setAudioSource(.phoneMic)

        await service.start()

        #expect(await spy.audioSourceCalls.last == .phoneMic)
    }

    @Test("switching audio source mid-session propagates immediately, no restart required")
    func switchingAudioSourceMidSessionPropagatesImmediately() async throws {
        let spy = SpyGlassesTransport()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: []),
            translator: ScriptedLanguageTranslator(languageCodes: [:]),
            defaults: freshDefaults()
        )
        await service.start()
        #expect(await spy.audioSourceCalls.last == .g2Mic)

        service.setAudioSource(.phoneMic)
        try? await Task.sleep(for: .milliseconds(30))

        #expect(service.audioSource == .phoneMic)
        #expect(await spy.audioSourceCalls.last == .phoneMic)
    }

    @Test("audio source selection survives across LiveTranslationService instances, simulating an app relaunch")
    func audioSourcePersistsAcrossRelaunch() {
        let defaults = freshDefaults()
        let service1 = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: []),
            translator: ScriptedLanguageTranslator(languageCodes: [:]),
            defaults: defaults
        )
        service1.setAudioSource(.phoneMic)

        let service2 = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: []),
            translator: ScriptedLanguageTranslator(languageCodes: [:]),
            defaults: defaults
        )
        #expect(service2.audioSource == .phoneMic)
    }

    // MARK: - Conversation Mode: Meeting Mode (reply priority)

    @Test("conversation mode defaults to standard")
    func conversationModeDefaultsToStandard() {
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: []),
            translator: ScriptedLanguageTranslator(languageCodes: [:]),
            defaults: freshDefaults()
        )
        #expect(service.conversationMode == .standard)
    }

    @Test("in Standard mode, suggested replies auto-display on G2 exactly as before")
    func standardModeAutoDisplaysReplies() async throws {
        let generator = FakeSuggestedReplyGenerator(defaultReplies: [
            SuggestedReply(originalLanguageText: "Sure", ukrainianText: "Так", ordering: 0),
        ])
        let spy = SpyGlassesTransport()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["Guten Tag"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["Guten Tag": "de"], translation: "Добрий день"),
            replyGenerator: generator,
            defaults: freshDefaults()
        )
        await service.start()
        try? await Task.sleep(for: .milliseconds(150))

        #expect(await spy.displayedPageSets.count == 2) // translation, then +replies
    }

    /// Meeting Mode's core guarantee: replies are still generated and
    /// recorded (Chat/history unaffected) but never auto-pushed to G2 —
    /// the screen stays dedicated to the conversation transcript.
    @Test("in Meeting mode, suggested replies are generated and recorded but never auto-displayed on G2")
    func meetingModeSuppressesReplyAutoDisplay() async throws {
        let generator = FakeSuggestedReplyGenerator(defaultReplies: [
            SuggestedReply(originalLanguageText: "Sure", ukrainianText: "Так", ordering: 0),
        ])
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ScriptedContinuousTranscriber(finals: ["Guten Tag"]),
            translator: ScriptedLanguageTranslator(languageCodes: ["Guten Tag": "de"], translation: "Добрий день"),
            agentContextStore: store,
            replyGenerator: generator,
            defaults: freshDefaults()
        )
        service.setConversationMode(.meeting)

        await service.start()
        try? await Task.sleep(for: .milliseconds(80))

        // Only the translation was ever pushed to G2 — no second,
        // reply-carrying display call.
        #expect(await spy.displayedPageSets.count == 1)
        // But the reply itself is still recorded, for Glasses Chat/history.
        #expect(store.session.latestTurn?.suggestedReplies.map(\.originalLanguageText) == ["Sure"])
    }

    @Test("conversation mode selection survives across LiveTranslationService instances, simulating an app relaunch")
    func conversationModePersistsAcrossRelaunch() {
        let defaults = freshDefaults()
        let service1 = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: []),
            translator: ScriptedLanguageTranslator(languageCodes: [:]),
            defaults: defaults
        )
        service1.setConversationMode(.meeting)

        let service2 = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: []),
            translator: ScriptedLanguageTranslator(languageCodes: [:]),
            defaults: defaults
        )
        #expect(service2.conversationMode == .meeting)
    }

    // MARK: - Conversation Mode: explicit returnToLive()

    @Test("calling returnToLive() explicitly re-enables followLive and redisplays the freshest content, from the iPhone side")
    func explicitReturnToLiveWorks() async throws {
        let spy = SpyGlassesTransport()
        let transcriber = ManualContinuousTranscriber()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(languageCodes: ["hi there": "en", "hello there": "en"], translation: "привіт"),
            defaults: freshDefaults()
        )
        await service.start()
        // Two turns — classification is semantic, derived from
        // `agentContextStore.session`, and needs a turn before the live
        // one for a non-zero index to resolve to a genuine history
        // target (see `navigatingAwayDisablesFollowLive`'s own comment).
        await transcriber.emit("hi there")
        await transcriber.emit("hello there")
        try? await Task.sleep(for: .milliseconds(60))

        await spy.simulateNavigation(.pageChanged(index: 2))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!service.followLive)

        await service.returnToLive()

        #expect(service.followLive)
        #expect(await spy.displayedPageSets.last == [
            "hello there\n\nUA: привіт",
            "Previous:\nhi there\n\nUA: привіт",
        ])
    }
}

