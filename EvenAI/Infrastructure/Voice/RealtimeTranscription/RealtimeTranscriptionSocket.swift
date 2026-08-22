import Foundation

/// Abstraction over one realtime-transcription WebSocket connection to
/// our own backend (`src/realtimeTranscription/wsServer.js`) — the seam
/// `OpenAIRealtimeTranscriber` is built against, so tests can inject
/// `FakeRealtimeTranscriptionSocket` instead of a real network
/// connection, the same role `GlassesTransport` plays for BLE and
/// `ContinuousTranscribing` plays for STT as a whole.
protocol RealtimeTranscriptionSocket: Sendable {
    /// Opens the connection. Throws if the connection attempt itself
    /// fails outright (e.g. the initial HTTP upgrade is rejected).
    /// Returns a stream of every event the backend sends until the
    /// connection ends — via a `.closed` event, a thrown error, or the
    /// stream simply finishing with no further explanation.
    func connect() async throws -> AsyncThrowingStream<RealtimeTranscriptionEvent, Error>

    /// Sends one chunk of raw G2 PCM (16kHz/16-bit/mono, unmodified — the
    /// backend owns resampling/encoding for whichever provider it talks
    /// to; nothing provider-specific ever happens on this side of the
    /// connection).
    func sendPCM(_ data: Data) async throws

    /// Closes the connection — safe to call even if never connected or
    /// already closed.
    func close() async
}

enum RealtimeTranscriptionSocketError: Error, Sendable, Equatable {
    case notConnected
}
