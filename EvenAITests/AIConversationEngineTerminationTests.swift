import Testing
import Foundation
@testable import EvenAI

/// Physical-device "Live Translation stopped unexpectedly. Try again."
/// investigation and hardening pass. Proves the explicit product
/// requirement — a failure in ONE translation request / ONE display
/// update / suggested replies / ONE provisional partial must NEVER
/// terminate the entire Live Translation session; only a genuinely
/// fatal audio/STT/session failure may stop listening — holds for every
/// one of those four failure classes, each with an explicit
/// `service.state == .listening` assertion (not just "did the turn look
/// right," which `AIConversationEngineTests`/
/// `AIConversationEngineSuggestedRepliesTests` already separately
/// verify for translation/reply failures specifically). Also covers
/// explicit-stop classification, task-cancellation classification,
/// Conversation Mode navigation isolation, and AudioSource-switch
/// isolation — the remaining scenarios this hardening pass asked for
/// dedicated regression coverage on.
///
/// Bounded-reconnect coverage itself (Scenario 5/6 — transient STT
/// socket close reconnects and continues; a failed reconnect only
/// terminates after the bounded retry policy is exhausted) lives in
/// `OpenAIRealtimeTranscriberTests`/
/// `AIConversationEngineOpenAIRealtimeTranscriberTests` — not
/// duplicated here.
@MainActor
@Suite("AIConversationEngine — termination diagnostics & failure isolation")
struct AIConversationEngineTerminationTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AIConversationEngineTerminationTests.\(UUID().uuidString)")!
    }

    // MARK: - 1-4: isolated failures never terminate the session

    @Test("1: a translation failure never sets state to .error — session stays .listening")
    func translationFailureNeverTerminatesSession() async throws {
        let store = AgentContextStore()
        let service = AIConversationEngine(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: ["Guten Tag", "hello there"], autoFinish: false),
            translator: ThrowingLanguageTranslator(failingTexts: ["Guten Tag"], translation: "привіт"),
            agentContextStore: store,
            defaults: freshDefaults()
        )
        await service.start()
        try? await Task.sleep(for: .milliseconds(150))

        #expect(service.state == .listening)
        #expect(store.session.turns.map(\.originalText) == ["hello there"])
    }

    @Test("2: a suggested-reply generation failure never sets state to .error — session stays .listening")
    func replyFailureNeverTerminatesSession() async throws {
        let generator = FakeSuggestedReplyGenerator(error: FakeSuggestedReplyGenerationError(message: "boom"))
        let store = AgentContextStore()
        let service = AIConversationEngine(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: ["Guten Tag"], autoFinish: false),
            translator: ScriptedLanguageTranslator(languageCodes: ["Guten Tag": "de"], translation: "Добрий день"),
            agentContextStore: store,
            replyGenerator: generator,
            defaults: freshDefaults()
        )
        await service.start()
        try? await Task.sleep(for: .milliseconds(150))

        #expect(service.state == .listening)
        #expect(store.session.latestTurn?.ukrainianTranslation == "Добрий день")
    }

    @Test("3: a G2 display failure never sets state to .error — session stays .listening, and later turns still translate/persist")
    func displayFailureNeverTerminatesSession() async throws {
        let transport = DisplayFailingGlassesTransport()
        let store = AgentContextStore()
        let service = AIConversationEngine(
            glassesTransport: transport,
            transcriber: ScriptedContinuousTranscriber(finals: ["first phrase", "second phrase"], autoFinish: false),
            translator: ScriptedLanguageTranslator(
                languageCodes: ["first phrase": "en", "second phrase": "en"],
                translation: "переклад"
            ),
            agentContextStore: store,
            defaults: freshDefaults()
        )
        await service.start()
        try? await Task.sleep(for: .milliseconds(150))

        // Both turns still translated and persisted despite EVERY
        // display call failing — a display failure never blocks
        // capture/translation/persistence, and never touches `state`.
        #expect(service.state == .listening)
        #expect(store.session.turns.map(\.originalText) == ["first phrase", "second phrase"])
        #expect(await transport.displayAttemptCount >= 2)
    }

    @Test("4: a provisional (streaming partial) translation failure/timeout never sets state to .error — session stays .listening")
    func provisionalTranslationFailureNeverTerminatesSession() async throws {
        let store = AgentContextStore()
        let transcriber = ManualContinuousTranscriber()
        let service = AIConversationEngine(
            glassesTransport: SpyGlassesTransport(),
            transcriber: transcriber,
            translator: HangingLanguageTranslator(
                languageCodes: ["a growing partial utterance": "en"],
                hangingTexts: ["a growing partial utterance"],
                translation: "переклад"
            ),
            agentContextStore: store,
            translationTimeout: .milliseconds(50),
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(.en)
        await service.start()

        await transcriber.emitPartial("a growing partial utterance")
        // Past the streaming buffer's own stability/max-latency window
        // (so a chunk is dispatched for translation) AND past the short
        // translation timeout above (so that chunk's translate call
        // definitely times out) — the provisional pipeline's own catch
        // block only logs and returns; it must never reach `state`.
        try? await Task.sleep(for: .milliseconds(1100))

        #expect(service.state == .listening)
    }

    // MARK: - 7: explicit stop terminates cleanly

    @Test("7: an explicit user Stop terminates cleanly — state becomes .idle, never the 'stopped unexpectedly' error")
    func explicitStopTerminatesCleanly() async throws {
        let service = AIConversationEngine(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ManualContinuousTranscriber(),
            translator: ScriptedLanguageTranslator(languageCodes: [:]),
            defaults: freshDefaults()
        )
        await service.start()
        #expect(service.state == .listening)

        await service.stop()

        #expect(service.state == .idle)
        if case .error = service.state {
            Issue.record("explicit stop must never leave state as .error")
        }
    }

    // MARK: - 8: task cancellation from stop() is classified correctly

    @Test("8: stop()'s internal task cancellation is classified as a clean stop, not a fatal failure — a subsequent start() and turn work normally")
    func taskCancellationFromStopIsClassifiedCleanly() async throws {
        let transcriber = ManualContinuousTranscriber()
        let store = AgentContextStore()
        let service = AIConversationEngine(
            glassesTransport: SpyGlassesTransport(),
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(languageCodes: ["hello": "en"], translation: "привіт"),
            agentContextStore: store,
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(.en)
        await service.start()
        #expect(service.state == .listening)

        await service.stop()
        // Not .error — a requested cancellation (stop()'s own
        // `consumeTask?.cancel()`), never misclassified as an
        // unexpected/fatal STT failure.
        #expect(service.state == .idle)

        // A misclassified cancellation could leave stale state behind
        // that breaks a later session — prove it doesn't.
        await service.start()
        #expect(service.state == .listening)
        await transcriber.emit("hello")
        try? await Task.sleep(for: .milliseconds(80))

        #expect(store.session.turns.map(\.originalText) == ["hello"])
        #expect(service.state == .listening)
    }

    // MARK: - 9: Conversation Mode navigation cannot stop the transcriber

    @Test("9: Conversation Mode navigation (history/reply browsing, return-to-live) never stops the transcriber or changes state away from .listening")
    func navigationNeverStopsTranscriber() async throws {
        let spy = SpyGlassesTransport()
        let store = AgentContextStore()
        let transcriber = ManualContinuousTranscriber()
        let service = AIConversationEngine(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(
                languageCodes: ["first phrase": "en", "second phrase": "en"],
                translation: "переклад"
            ),
            agentContextStore: store,
            defaults: freshDefaults()
        )
        await service.start()
        await transcriber.emit("first phrase")
        await transcriber.emit("second phrase")
        try? await Task.sleep(for: .milliseconds(80))
        #expect(service.state == .listening)

        // Every navigation event Conversation Mode supports, back to
        // back.
        await spy.simulateNavigation(.pageChanged(index: 1)) // browsing history
        try? await Task.sleep(for: .milliseconds(30))
        #expect(service.state == .listening)

        await spy.simulateNavigation(.returnToLiveRequested)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(service.state == .listening)

        await spy.simulateNavigation(.pageChanged(index: 0))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(service.state == .listening)

        #expect(await transcriber.stopCallCount == 0) // never stopped, no matter how much navigation happened
    }

    // MARK: - 10: AudioSource switch cannot accidentally terminate the session

    @Test("10: switching AudioSource mid-session never terminates the transcriber or changes state away from .listening")
    func audioSourceSwitchNeverTerminatesSession() async throws {
        let spy = SpyGlassesTransport()
        let transcriber = ManualContinuousTranscriber()
        let store = AgentContextStore()
        let service = AIConversationEngine(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(languageCodes: ["hello": "en"], translation: "переклад"),
            agentContextStore: store,
            defaults: freshDefaults()
        )
        service.setSourceLanguageMode(.en)
        await service.start()
        #expect(service.state == .listening)

        service.setAudioSource(.phoneMic)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(service.state == .listening)
        #expect(await transcriber.stopCallCount == 0)

        // The already-running STT stream keeps working after the switch
        // — `setAudioSource` only touches `glassesTransport
        // .setPreferredAudioSource(_:)` (a G2/transport-level concern),
        // entirely independent of the transcriber's own stream.
        await transcriber.emit("hello")
        try? await Task.sleep(for: .milliseconds(80))
        #expect(store.session.turns.map(\.originalText) == ["hello"])
        #expect(service.state == .listening)
    }
}
