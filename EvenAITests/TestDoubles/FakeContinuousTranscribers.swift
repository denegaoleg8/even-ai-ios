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
    private(set) var stopCallCount = 0
    private var continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation?

    func startTranscribing(pcmUpdates: AsyncStream<Data>) async throws -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in
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
