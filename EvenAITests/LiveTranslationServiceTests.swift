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
    private static let propagationDelay: Duration = .milliseconds(30)

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

        #expect(await spy.sentTexts == ["привіт"])
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

        #expect(await spy.sentTexts == ["привіт"])
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
}
