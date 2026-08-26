import Foundation
@testable import EvenAI

/// Yields a caller-scripted sequence of "final" transcripts — lets a test
/// drive `LiveTranslationService`'s consume loop without a real `Speech`/
/// PCM pipeline. `startTranscribing(pcmUpdates:)` ignores the PCM stream
/// entirely; only `finals` matters for these tests.
///
/// `autoFinish` (default `true`) matches most tests' needs: yield the
/// scripted finals, then finish, exactly like a short recognition session
/// that completes on its own. Set `false` to model a still-listening
/// session that only ends when `stopTranscribing()` is called — needed by
/// any test that must observe `.listening` before triggering a stop (e.g.
/// a connection-loss or backgrounding test), since a stream that finishes
/// immediately lets `LiveTranslationService.consume(_:)` flip back to
/// `.idle` on its own before the test ever gets to look.
actor ScriptedContinuousTranscriber: ContinuousTranscribing {
    private let finals: [String]
    private let autoFinish: Bool
    private(set) var stopCallCount = 0
    private var continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation?

    init(finals: [String], autoFinish: Bool = true) {
        self.finals = finals
        self.autoFinish = autoFinish
    }

    func startTranscribing(pcmUpdates: AsyncStream<Data>) async throws -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        let finals = self.finals
        let autoFinish = self.autoFinish
        return AsyncThrowingStream { continuation in
            for final in finals {
                continuation.yield(.final(final))
            }
            if autoFinish {
                continuation.finish()
            } else {
                Task { await self.retain(continuation) }
            }
        }
    }

    private func retain(_ continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation) {
        self.continuation = continuation
    }

    func stopTranscribing() async {
        stopCallCount += 1
        continuation?.finish()
        continuation = nil
    }
}

/// Like `ScriptedContinuousTranscriber`, but updates are emitted on demand
/// via `emit(_:)`/`emitPartial(_:)` rather than all up front — lets a test
/// control the real wall-clock gap between two updates (e.g. to test a
/// time-bounded dedupe window's boundary, or a streaming-translation race
/// between two partials), which a fixed, synchronously-yielded array can't.
actor ManualContinuousTranscriber: ContinuousTranscribing {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private var continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation?

    func startTranscribing(pcmUpdates: AsyncStream<Data>) async throws -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        startCallCount += 1
        return AsyncThrowingStream { continuation in
            Task { await self.retain(continuation) }
        }
    }

    private func retain(_ continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation) {
        self.continuation = continuation
    }

    /// Emits a final transcript — the old, still-most-common test shape.
    func emit(_ text: String) {
        continuation?.yield(.final(text))
    }

    /// Emits a still-growing partial for the utterance in progress.
    func emitPartial(_ text: String) {
        continuation?.yield(.partial(text))
    }

    /// Fails the CURRENT stream with `error` — models a provider that
    /// started successfully (unlike `ThrowingStartContinuousTranscriber`/
    /// `HandshakeFailingContinuousTranscriber`, which fail before or at
    /// the very first iteration) but then drops mid-session, e.g. a cloud
    /// connection whose bounded reconnect budget is later exhausted. Used
    /// by `CloudTranscriptionFallbackTests` to exercise
    /// `TranscriptionProviderRouter`'s Cloud→local mid-stream fallback.
    func failStream(with error: Error) {
        continuation?.finish(throwing: error)
        continuation = nil
    }

    func stopTranscribing() async {
        stopCallCount += 1
        continuation?.finish()
        continuation = nil
    }
}

/// `startTranscribing(pcmUpdates:)` throws the given error SYNCHRONOUSLY,
/// before ever returning a stream — models a `transcriber
/// .startTranscribing` call that fails outright (e.g. session recovery
/// failing inside `URLSessionRealtimeTranscriptionSocket.connect()`,
/// which `OpenAIRealtimeTranscriber.startTranscribing` propagates the
/// same way). Used to verify `LiveTranslationService.start()`'s
/// `LiveTranslationStartError` classification for auth/backend/STT
/// failures, which a script-based fake (no way to inject an arbitrary
/// thrown error type) can't exercise.
actor ThrowingStartContinuousTranscriber: ContinuousTranscribing {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func startTranscribing(pcmUpdates: AsyncStream<Data>) async throws -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        throw error
    }

    func stopTranscribing() async {}
}

/// `startTranscribing(pcmUpdates:)` itself SUCCEEDS (returns a stream
/// normally, exactly like a real handshake that hasn't failed YET), but
/// that stream's very first iteration throws the given error — no
/// update, partial or final, is ever yielded first. Models a WebSocket
/// handshake that fails ASYNCHRONOUSLY, moments after `connect()` already
/// returned (see `URLSessionRealtimeTranscriptionSocket.connect()`'s own
/// doc comment on why that return doesn't prove the handshake succeeded)
/// — the scenario `LiveTranslationService.consume(_:)`'s own
/// `hasReceivedAnyUpdateThisSession` reclassification exists to still
/// report truthfully, not as the generic "stopped unexpectedly".
actor HandshakeFailingContinuousTranscriber: ContinuousTranscribing {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func startTranscribing(pcmUpdates: AsyncStream<Data>) async throws -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        let capturedError = error
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: capturedError)
        }
    }

    func stopTranscribing() async {}
}

/// `OnDeviceTranscribing` fake — used by `TranscriptionProviderRouterTests`
/// to exercise `TranscriptionProviderRouter`'s provider-selection logic
/// without touching the real `Speech` framework/audio session (which
/// `GlassesSpeechTranscriber` needs a genuinely authorized device/simulator
/// for — not guaranteed in every `xcodebuild test` environment). `@MainActor`,
/// mirroring `GlassesSpeechTranscriber`'s own isolation — `OnDeviceTranscribing
/// .locale`/`.setLocale(_:)` are synchronous protocol requirements, which
/// only same-actor (not cross-actor) access can satisfy without `await`.
/// `startError` decides whether `startTranscribing` succeeds (yielding
/// `finals`) or throws synchronously — models both "on-device recognition
/// unavailable for this locale" (throws) and "on-device recognition
/// worked" (succeeds) without any real recognizer.
@MainActor
final class FakeOnDeviceTranscriber: OnDeviceTranscribing, @unchecked Sendable {
    private(set) var locale: Locale
    private(set) var setLocaleCallCount = 0
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private let finals: [String]
    private let startError: Error?
    /// Retained across the CURRENT `startTranscribing` call so
    /// `emit(_:)`/`emitPartial(_:)`/`failStream(with:)` can drive it on
    /// demand — the same "manual" pattern `ManualContinuousTranscriber`
    /// uses, needed here (rather than reusing that type directly) because
    /// only a `@MainActor` class, not a plain `actor`, can satisfy
    /// `OnDeviceTranscribing`'s synchronous `locale`/`setLocale`
    /// requirements — see this type's own original doc comment.
    private var continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation?

    init(locale: Locale = Locale(identifier: "en-US"), finals: [String] = [], startError: Error? = nil) {
        self.locale = locale
        self.finals = finals
        self.startError = startError
    }

    func setLocale(_ newLocale: Locale) {
        locale = newLocale
        setLocaleCallCount += 1
    }

    func startTranscribing(pcmUpdates: AsyncStream<Data>) async throws -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        startCallCount += 1
        if let startError { throw startError }
        let finals = self.finals
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
            for final in finals { continuation.yield(.final(final)) }
        }
    }

    /// Emits a final transcript on demand, on the CURRENT session's
    /// stream — for tests that need to control wall-clock timing between
    /// updates (e.g. driving one turn, waiting, then driving another
    /// across a Cloud→local fallback), which the fixed `finals` array
    /// (yielded all at once, immediately on start) can't do.
    func emit(_ text: String) {
        continuation?.yield(.final(text))
    }

    func emitPartial(_ text: String) {
        continuation?.yield(.partial(text))
    }

    /// Fails the CURRENT stream — models a provider that started
    /// successfully but then drops mid-session (e.g. a cloud connection
    /// whose bounded reconnect budget is later exhausted).
    func failStream(with error: Error) {
        continuation?.finish(throwing: error)
        continuation = nil
    }

    func stopTranscribing() async {
        stopCallCount += 1
        continuation?.finish()
        continuation = nil
    }
}

/// A `ContinuousTranscribing` that fails the test outright if ever called
/// — used to prove `.onDevice` mode never touches `cloud` at all, and
/// `.auto` mode never touches `cloud` when `local` succeeds.
actor NeverCalledTranscriber: ContinuousTranscribing {
    struct UnexpectedlyCalled: Error {}

    func startTranscribing(pcmUpdates: AsyncStream<Data>) async throws -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        throw UnexpectedlyCalled()
    }

    func stopTranscribing() async {}
}
