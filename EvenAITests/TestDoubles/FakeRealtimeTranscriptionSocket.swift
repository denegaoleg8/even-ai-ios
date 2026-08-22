import Foundation
@testable import EvenAI

/// Test double for `RealtimeTranscriptionSocket` — lets
/// `OpenAIRealtimeTranscriberTests` drive every event/failure path
/// (partial/final/language/error/closed, connect failure, mid-stream
/// drop) without any real network connection. An `actor` so it safely
/// satisfies `RealtimeTranscriptionSocket: Sendable` while still being
/// directly manipulable from test code via `await`.
actor FakeRealtimeTranscriptionSocket: RealtimeTranscriptionSocket {
    private(set) var connectCallCount = 0
    private(set) var sentPCM: [Data] = []
    private(set) var isClosed = false
    private var continuation: AsyncThrowingStream<RealtimeTranscriptionEvent, Error>.Continuation?
    private var connectError: Error?

    /// Makes the *next* `connect()` call throw `error` instead of
    /// succeeding — consumed once, so a later reconnect attempt (a fresh
    /// `connect()` call) can still succeed normally.
    func failNextConnect(with error: Error) {
        connectError = error
    }

    func connect() async throws -> AsyncThrowingStream<RealtimeTranscriptionEvent, Error> {
        connectCallCount += 1
        if let connectError {
            self.connectError = nil
            throw connectError
        }
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }

    func sendPCM(_ data: Data) async throws {
        sentPCM.append(data)
    }

    func close() async {
        isClosed = true
        continuation?.finish()
    }

    /// Test-only: pushes one event as if the backend had sent it.
    func emit(_ event: RealtimeTranscriptionEvent) {
        continuation?.yield(event)
    }

    /// Test-only: ends the event stream as if the connection itself
    /// dropped — with no `.closed` event ever arriving — exercising
    /// `OpenAIRealtimeTranscriber`'s "stream ended unexpectedly" reconnect
    /// path, distinct from an explicit `.closed` event.
    func endStream(throwing error: Error? = nil) {
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }
}

/// Hands out sequential `FakeRealtimeTranscriptionSocket` instances —
/// `OpenAIRealtimeTranscriber`'s `makeSocket` factory is called again on
/// every reconnect, so tests need a way to tell the first socket apart
/// from the second/third rather than reusing one instance across
/// attempts.
actor FakeRealtimeTranscriptionSocketFactory {
    private(set) var createdSockets: [FakeRealtimeTranscriptionSocket] = []

    func makeSocket() -> RealtimeTranscriptionSocket {
        let socket = FakeRealtimeTranscriptionSocket()
        createdSockets.append(socket)
        return socket
    }
}

struct FakeError: Error, Equatable {
    let message: String
}
