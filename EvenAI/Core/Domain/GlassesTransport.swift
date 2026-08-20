import Foundation

/// Abstraction over the glasses BLE transport. `MentraGlassesTransport` is the
/// concrete implementation (Milestone 4, phase 1), wrapping the third-party
/// MentraBluetoothSDK; `MockGlassesTransport` is an in-memory stand-in for
/// tests/previews, mirroring `MockChatService`/`MockAuthService`'s role for
/// their own protocols.
///
/// Nothing outside `Infrastructure/Glasses` may import MentraBluetoothSDK
/// directly — every caller talks only to this protocol, so the underlying
/// transport (a different SDK, a future Even Hub bridge, direct CoreBluetooth)
/// is swappable later without touching Chat, backend, or any other feature
/// code. See ARCHITECTURE.md / ROADMAP.md, Milestone 4, for why
/// MentraBluetoothSDK was chosen over Even Realities' own Even Hub SDK
/// (WebView mini-apps hosted inside the official Even app only — not usable
/// from a standalone native app) and over a direct, undocumented
/// CoreBluetooth implementation.
protocol GlassesTransport: Sendable {
    /// Connection-state changes, starting with the transport's current state.
    func connectionStateUpdates() async -> AsyncStream<GlassesTransportState>

    /// Scans for and connects to a G2. A successful return only means the
    /// scan/connect attempt was started — the actual outcome (including
    /// failure) is delivered via `connectionStateUpdates()`.
    func connect() async throws

    func disconnect() async

    /// Sends text content to be displayed on the glasses.
    /// Throws `GlassesTransportError.notConnected` if not currently connected.
    func sendText(_ text: String) async throws
}
