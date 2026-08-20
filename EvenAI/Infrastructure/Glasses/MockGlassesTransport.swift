import Foundation

/// In-memory placeholder implementation used for tests and previews.
/// Mirrors `MockChatService`/`MockAuthService`'s role for their protocols —
/// `MentraGlassesTransport` is what the running app will talk to once the
/// Glasses feature is built on top of this transport.
actor MockGlassesTransport: GlassesTransport {
    private var state: GlassesTransportState = .disconnected
    private var stateContinuation: AsyncStream<GlassesTransportState>.Continuation?

    func connectionStateUpdates() async -> AsyncStream<GlassesTransportState> {
        AsyncStream { continuation in
            stateContinuation = continuation
            continuation.yield(state)
        }
    }

    func connect() async throws {
        state = .connected
        stateContinuation?.yield(state)
    }

    func disconnect() async {
        state = .disconnected
        stateContinuation?.yield(state)
    }

    func sendText(_ text: String) async throws {
        guard state == .connected else {
            throw GlassesTransportError.notConnected
        }
    }

    func microphonePCMUpdates() async -> AsyncStream<Data> {
        AsyncStream { _ in }
    }

    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        guard !enabled || state == .connected else {
            throw GlassesTransportError.notConnected
        }
    }
}
