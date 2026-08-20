import Foundation
import MentraBluetoothSDK

/// `GlassesTransport` implementation backed by the third-party
/// MentraBluetoothSDK (Mentra-Community), talking directly to Even Realities
/// G2 glasses over BLE. Chosen over Even Realities' own "Even Hub" SDK, which
/// only supports building WebView mini-apps hosted inside the official Even
/// Realities app — not usable from a standalone native app like this one —
/// and over a direct CoreBluetooth implementation, which would mean
/// reimplementing an undocumented, community-reverse-engineered protocol from
/// scratch. See ARCHITECTURE.md / ROADMAP.md Milestone 4 for the full
/// comparison.
///
/// Kept as a thin adapter deliberately: MentraBluetoothSDK exposes a large
/// surface (camera, Wi-Fi, OTA, streaming, ...) this milestone has no use
/// for. Only what `GlassesTransport` requires is wired up here — extend the
/// protocol first if a future feature needs more of the underlying SDK.
///
/// `sdk` is constructed lazily, not in `init()`: `MentraBluetoothSDK.init()`
/// touches `CBCentralManager` internally (via its own `BluetoothAvailability`
/// singleton), which triggers iOS's Bluetooth permission prompt on first use.
/// Nothing calls into this transport yet (no Glasses UI, no Chat wiring —
/// see Milestone 4's phased plan), so constructing this adapter — which
/// `AppContainer.live` does eagerly, matching every other service there —
/// must not, by itself, prompt the user for Bluetooth access.
///
/// `@MainActor` + `@unchecked Sendable`: `MentraBluetoothSDK` itself is a
/// `@MainActor`-isolated class, so every access to `sdk` must happen on the
/// main actor; this type mirrors that isolation. `@unchecked Sendable`
/// satisfies `GlassesTransport: Sendable` — safe because all mutable state
/// (`sdk`, `stateContinuations`) is confined to the main actor by this same
/// class-wide isolation, never accessed concurrently.
@MainActor
final class MentraGlassesTransport: GlassesTransport, @unchecked Sendable {
    /// Tracks whether `sdk` has been touched yet, so `connectionStateUpdates()`
    /// can report the (trivially correct) `.disconnected` state without
    /// forcing lazy SDK construction — see `sdk`'s own doc comment. Without
    /// this, a Glasses screen that merely subscribes to state on appear
    /// (before the user ever presses Connect) would silently trigger the
    /// Bluetooth permission prompt.
    private var isSDKStarted = false

    private lazy var sdk: MentraBluetoothSDK = {
        isSDKStarted = true
        let sdk = MentraBluetoothSDK()
        sdk.delegate = self
        return sdk
    }()

    private var stateContinuations: [UUID: AsyncStream<GlassesTransportState>.Continuation] = [:]

    nonisolated init() {}

    func connectionStateUpdates() async -> AsyncStream<GlassesTransportState> {
        let currentState: GlassesTransportState = isSDKStarted
            ? Self.mapConnectionState(sdk.glasses.connection)
            : .disconnected
        return AsyncStream { continuation in
            let id = UUID()
            stateContinuations[id] = continuation
            continuation.yield(currentState)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.stateContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    func connect() async throws {
        try sdk.startScan(model: .g2)
    }

    func disconnect() async {
        sdk.disconnect()
    }

    func sendText(_ text: String) async throws {
        guard sdk.glasses.connected else {
            throw GlassesTransportError.notConnected
        }
        try await sdk.displayText(text)
    }

    private static func mapConnectionState(_ state: GlassesConnectionState) -> GlassesTransportState {
        switch state {
        case .disconnected: .disconnected
        case .scanning: .scanning
        case .connecting, .bonding: .connecting
        case .connected: .connected
        }
    }

    private func broadcast(_ state: GlassesTransportState) {
        for continuation in stateContinuations.values {
            continuation.yield(state)
        }
    }
}

extension MentraGlassesTransport: MentraBluetoothSDKDelegate {
    func mentraBluetoothSDK(_ sdk: MentraBluetoothSDK, didUpdateGlasses glasses: GlassesRuntimeState) {
        broadcast(Self.mapConnectionState(glasses.connection))
    }

    func mentraBluetoothSDK(_ sdk: MentraBluetoothSDK, didDiscover device: Device) {
        guard device.model == .g2 else { return }
        sdk.stopScan()
        do {
            try sdk.connect(to: device)
        } catch {
            broadcast(.failed(error.localizedDescription))
        }
    }

    func mentraBluetoothSDK(_ sdk: MentraBluetoothSDK, didFail error: BluetoothSdkError) {
        broadcast(.failed(error.message))
    }
}
