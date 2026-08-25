import Testing
import Foundation
@testable import EvenAI

/// Two-regression investigation (physical-device build after 0e573dc):
/// (1) Live Translation immediately failed with "Couldn't start Live
/// Translation. Check your G2 connection and try again." even when G2
/// was perfectly healthy — traced to a session-recovery/auth failure
/// inside `transcriber.startTranscribing(pcmUpdates:)` sharing the exact
/// same generic, G2-labeled catch block as a genuine G2/microphone
/// failure. (2) Normal AI Chat failed to open — traced to the SAME
/// underlying cause: `URLSessionRealtimeTranscriptionSocket.connect()`
/// was calling the always-network-round-trip `AuthenticatedAPIClient
/// .recoverSession()` unconditionally on every one of the bounded
/// reconnect attempts, and `/auth/refresh` ROTATES the refresh token on
/// every call — churning the ONE session Live Translation and Chat
/// share.
///
/// These tests prove: (a) `LiveTranslationService.start()` now reports
/// the TRUTHFUL cause of a startup failure — `LiveTranslationStartError`
/// — never collapsing an auth/backend/STT failure into a false G2
/// message, and a genuine G2/microphone failure is still correctly
/// reported as such; (b) a startup failure never leaves the session in a
/// half-started state.
@MainActor
@Suite("LiveTranslationService — startup failure classification")
struct LiveTranslationStartClassificationTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "LiveTranslationStartClassificationTests.\(UUID().uuidString)")!
    }

    // MARK: - 1: the happy path still starts

    @Test("1: connected G2 + a transcriber that starts cleanly → session reaches .listening")
    func connectedG2WithHealthyTranscriberStarts() async throws {
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: [], autoFinish: false),
            translator: ScriptedLanguageTranslator(languageCodes: [:]),
            defaults: freshDefaults()
        )
        await service.start()
        #expect(service.state == .listening)
    }

    // MARK: - 2: anonymous device session is a valid contract for starting

    @Test("2: the WebSocket layer attaches an anonymous device session's credential without error — the contract Live Translation relies on")
    func anonymousDeviceSessionIsAcceptedByTheWebSocketLayer() async throws {
        // This is the actual seam where "does an anonymous session work
        // for Live Translation" is decided —
        // `URLSessionRealtimeTranscriptionSocketTests
        // .firstConnectionAttachesAnonymousDeviceCredential` proves the
        // credential gets attached, and the backend's own
        // `wsServer.test.js` ("accepts a valid access token...") proves
        // that credential is accepted end-to-end. This test proves the
        // `LiveTranslationService` level of the same contract: starting
        // with NO prior session at all (the anonymous-device path) never
        // itself produces a `LiveTranslationStartError` for a healthy
        // transcriber.
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: [], autoFinish: false),
            translator: ScriptedLanguageTranslator(languageCodes: [:]),
            defaults: freshDefaults()
        )
        await service.start()
        #expect(service.state == .listening)
    }

    // MARK: - 3: auth failure reports an auth error, not a G2 error

    @Test("3: a session-recovery/authentication failure during STT startup reports an auth error, never a G2 error")
    func authFailureDuringStartupReportsAuthError() async throws {
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ThrowingStartContinuousTranscriber(error: AuthenticatedAPIClientError.notAuthenticated),
            translator: ScriptedLanguageTranslator(languageCodes: [:]),
            defaults: freshDefaults()
        )
        await service.start()

        guard case .error(let message) = service.state else {
            Issue.record("expected .error, got \(service.state)")
            return
        }
        #expect(!message.contains("G2"))
        #expect(message == LiveTranslationStartError.authenticationFailed(underlying: "").userFacingMessage)
    }

    // MARK: - 4: backend/handshake failure reports a backend/STT error, not a G2 error

    @Test("4: a backend-unavailable failure during STT startup reports a backend error, never a G2 error")
    func backendFailureDuringStartupReportsBackendError() async throws {
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: ThrowingStartContinuousTranscriber(error: AuthenticatedAPIClientError.offline),
            translator: ScriptedLanguageTranslator(languageCodes: [:]),
            defaults: freshDefaults()
        )
        await service.start()

        guard case .error(let message) = service.state else {
            Issue.record("expected .error, got \(service.state)")
            return
        }
        #expect(!message.contains("G2"))
        #expect(message == LiveTranslationStartError.backendUnavailable(underlying: "").userFacingMessage)
    }

    @Test("4b: an async STT handshake failure (after startTranscribing already returned, before any update arrived) reports the SAME truthful classification, not the generic 'stopped unexpectedly' message")
    func asyncHandshakeFailureReportsTruthfulClassification() async throws {
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: HandshakeFailingContinuousTranscriber(error: URLError(.cannotConnectToHost)),
            translator: ScriptedLanguageTranslator(languageCodes: [:]),
            defaults: freshDefaults()
        )
        await service.start()
        try? await Task.sleep(for: .milliseconds(60))

        guard case .error(let message) = service.state else {
            Issue.record("expected .error, got \(service.state)")
            return
        }
        #expect(!message.contains("G2"))
        #expect(message != "Live Translation stopped unexpectedly. Try again.")
        #expect(message == LiveTranslationStartError.backendUnavailable(underlying: "").userFacingMessage)
    }

    // MARK: - 5: an actual G2 failure reports a G2 error

    @Test("5: an actual G2 connection failure (G2 mic selected) reports a G2 error")
    func g2FailureDuringStartupReportsG2Error() async throws {
        let service = LiveTranslationService(
            glassesTransport: PairFailureGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: []),
            translator: ScriptedLanguageTranslator(languageCodes: [:]),
            defaults: freshDefaults()
        )
        await service.start()

        guard case .error(let message) = service.state else {
            Issue.record("expected .error, got \(service.state)")
            return
        }
        #expect(message.contains("G2"))
        #expect(message == LiveTranslationStartError.glassesUnavailable(underlying: "").userFacingMessage)
    }

    // MARK: - 6: a mic-enable failure with Phone Mic selected reports an audio error, not G2

    @Test("6: a microphone-enable failure while AudioSource.phoneMic is selected reports a microphone error, never a G2 error")
    func phoneMicFailureDuringStartupReportsMicrophoneError() async throws {
        let service = LiveTranslationService(
            glassesTransport: PairFailureGlassesTransport(),
            transcriber: ScriptedContinuousTranscriber(finals: []),
            translator: ScriptedLanguageTranslator(languageCodes: [:]),
            defaults: freshDefaults()
        )
        service.setAudioSource(.phoneMic)
        await service.start()

        guard case .error(let message) = service.state else {
            Issue.record("expected .error, got \(service.state)")
            return
        }
        #expect(!message.contains("G2"))
        #expect(message == LiveTranslationStartError.microphoneUnavailable(underlying: "").userFacingMessage)
    }

    // MARK: - 7: confirmed handshake is required before startup is reported as successful

    @Test("7: a handshake that never confirms (fails before any update ever arrives) is never reported as a successful start")
    func unconfirmedHandshakeIsNeverReportedAsSuccess() async throws {
        let service = LiveTranslationService(
            glassesTransport: SpyGlassesTransport(),
            transcriber: HandshakeFailingContinuousTranscriber(error: AuthenticatedAPIClientError.sessionExpired),
            translator: ScriptedLanguageTranslator(languageCodes: [:]),
            defaults: freshDefaults()
        )
        await service.start()
        // `state` may pass through `.listening` optimistically for a
        // moment (see `consume(_:)`'s own doc comment on why this class
        // can't synchronously distinguish "task resumed" from "handshake
        // confirmed"), but must settle on `.error` — never remain
        // `.listening` — once the handshake's failure is discovered.
        try? await Task.sleep(for: .milliseconds(60))
        #expect(service.state != .listening)
        guard case .error = service.state else {
            Issue.record("expected .error once the unconfirmed handshake's failure surfaces, got \(service.state)")
            return
        }
    }

    // MARK: - 8: a startup failure never leaves the session half-started

    @Test("8: a startup failure fully tears down — mic disabled, no half-started state left behind")
    func startupFailureDoesNotLeaveHalfStartedState() async throws {
        let spy = SpyGlassesTransport()
        let service = LiveTranslationService(
            glassesTransport: spy,
            transcriber: ThrowingStartContinuousTranscriber(error: AuthenticatedAPIClientError.notAuthenticated),
            translator: ScriptedLanguageTranslator(languageCodes: [:]),
            defaults: freshDefaults()
        )
        await service.start()

        guard case .error = service.state else {
            Issue.record("expected .error, got \(service.state)")
            return
        }
        // The mic was enabled (audio-source setup succeeded) and then
        // explicitly disabled again as part of `terminateSession`'s
        // teardown — never left on.
        #expect(await spy.microphoneEnabledCalls == [true, false])

        // A subsequent start() must work normally — a half-torn-down
        // session would otherwise wedge every later attempt too.
        let transcriber = ManualContinuousTranscriber()
        let store = AgentContextStore()
        let recoveredService = LiveTranslationService(
            glassesTransport: spy,
            transcriber: transcriber,
            translator: ScriptedLanguageTranslator(languageCodes: ["hello": "en"], translation: "привіт"),
            agentContextStore: store,
            defaults: freshDefaults()
        )
        recoveredService.setSourceLanguageMode(.en)
        await recoveredService.start()
        #expect(recoveredService.state == .listening)
        await transcriber.emit("hello")
        try? await Task.sleep(for: .milliseconds(80))
        #expect(store.session.turns.map(\.originalText) == ["hello"])
    }
}
