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

    /// `startScan` fails with this exact code when `CBCentralManager`'s
    /// state hasn't synced with the Bluetooth daemon yet — see `connect()`.
    private static let bluetoothNotReadyErrorCode = "bluetooth_not_ready"
    private static let startScanMaxAttempts = 4
    private static let startScanRetryDelay: Duration = .milliseconds(350)

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

    /// `sdk` (and the `CBCentralManager` it owns, via MentraBluetoothSDK's
    /// internal `BluetoothAvailability` singleton) is constructed lazily on
    /// this exact call — see `sdk`'s doc comment — with no run-loop turn
    /// between that construction and `startScan`'s internal readiness check.
    /// `CBCentralManager.state` doesn't reflect the real (already-granted,
    /// already-on) hardware state until CoreBluetooth's async
    /// `centralManagerDidUpdateState` callback lands, so the very first
    /// scan attempt per process launch deterministically sees `.unknown`
    /// and throws `BluetoothSdkError(code: "bluetooth_not_ready", ...)` —
    /// confirmed against MentraBluetoothSDK's own source
    /// (`BluetoothAvailability.requirePoweredOn`). `BluetoothAvailability`
    /// is internal to that module, so there's no public hook to await
    /// readiness directly; a short bounded retry is the only fix available
    /// from here. Only this specific, transient code is retried — a real
    /// `.unauthorized`/`.poweredOff`/`.unsupported` failure (or any other
    /// error) surfaces immediately, since retrying those would just waste
    /// time on a state that isn't going to change on its own.
    func connect() async throws {
        for attempt in 1...Self.startScanMaxAttempts {
            do {
                try sdk.startScan(model: .g2)
                return
            } catch let error as BluetoothSdkError where error.code == Self.bluetoothNotReadyErrorCode {
                guard attempt < Self.startScanMaxAttempts else { throw error }
                try? await Task.sleep(for: Self.startScanRetryDelay)
            }
        }
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
