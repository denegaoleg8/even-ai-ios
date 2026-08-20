import Foundation
@testable import EvenAI

/// `connect()` starts normally, then broadcasts a `.failed(_:)` state
/// carrying the same clean message `MentraGlassesTransport` produces for
/// MentraBluetoothSDK's `"pair_failure"` code — mirrors G2's real dual-
/// peripheral pairing timeout (found only one arm within 10s) without
/// needing a real SDK/CoreBluetooth object. Used to verify
/// `GlassesViewModel` reaches a clean, terminal state instead of staying
/// stuck "connecting".
actor PairFailureGlassesTransport: GlassesTransport {
    static let message = MentraGlassesTransport.failureMessage(
        forCode: "pair_failure",
        rawMessage: "errors:pairNeedDisconnect"
    )

    private var stateContinuation: AsyncStream<GlassesTransportState>.Continuation?

    func connectionStateUpdates() async -> AsyncStream<GlassesTransportState> {
        AsyncStream { continuation in
            stateContinuation = continuation
            continuation.yield(.disconnected)
        }
    }

    func connect() async throws {
        stateContinuation?.yield(.failed(Self.message))
    }

    func disconnect() async {
        stateContinuation?.yield(.disconnected)
    }

    func sendText(_ text: String) async throws {
        throw GlassesTransportError.notConnected
    }
}
