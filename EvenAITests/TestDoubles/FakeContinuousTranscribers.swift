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
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?

    init(finals: [String], autoFinish: Bool = true) {
        self.finals = finals
        self.autoFinish = autoFinish
    }

    func startTranscribing(pcmUpdates: AsyncStream<Data>) async throws -> AsyncThrowingStream<String, Error> {
        let finals = self.finals
        let autoFinish = self.autoFinish
        return AsyncThrowingStream { continuation in
            for final in finals {
                continuation.yield(final)
            }
            if autoFinish {
                continuation.finish()
            } else {
                Task { await self.retain(continuation) }
            }
        }
    }

    private func retain(_ continuation: AsyncThrowingStream<String, Error>.Continuation) {
        self.continuation = continuation
    }

    func stopTranscribing() async {
        stopCallCount += 1
        continuation?.finish()
        continuation = nil
    }
}
