import CoreBluetooth
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

    /// Upper bound on how long `connect()` will wait for CoreBluetooth's
    /// central-manager state to settle before giving up — see
    /// `BluetoothReadinessWatcher`. This is a safety net for a wait that is
    /// otherwise driven entirely by the real `centralManagerDidUpdateState`
    /// event, not the primary mechanism itself.
    private static let bluetoothReadyTimeout: Duration = .seconds(10)

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
    /// this exact call — see `sdk`'s doc comment. That internal manager's
    /// `.state` doesn't reflect the real (already-granted, already-on)
    /// hardware state until CoreBluetooth's async
    /// `centralManagerDidUpdateState` callback lands — confirmed against
    /// MentraBluetoothSDK's own source (`BluetoothAvailability.
    /// requirePoweredOn`, which is what `startScan` throws
    /// `BluetoothSdkError(code: "bluetooth_not_ready", ...)` from).
    /// `BluetoothAvailability` is internal to that module, so there's no
    /// public hook to await its readiness directly.
    ///
    /// `BluetoothReadinessWatcher` bridges the same real, event-driven
    /// signal via a second, independent `CBCentralManager` — `CBManagerState`
    /// reflects this app's Bluetooth authorization/radio state process-wide,
    /// so a fresh manager observes the same ground truth as the SDK's
    /// internal one, without needing to touch it and without triggering a
    /// second permission prompt. `startScan` is therefore only ever called
    /// once we already know it will succeed; a real `.unauthorized`/
    /// `.poweredOff`/`.unsupported` condition (or a timeout) surfaces
    /// immediately instead of being retried.
    func connect() async throws {
        let sdk = self.sdk // starts MentraBluetoothSDK before we wait for readiness
        try await BluetoothReadinessWatcher().waitUntilReady(timeout: Self.bluetoothReadyTimeout)
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

/// Bridges CoreBluetooth's own async central-manager readiness signal into
/// Swift concurrency, entirely via Apple's public `CoreBluetooth` API — not
/// MentraBluetoothSDK, which exposes no public way to observe this (see
/// `connect()`'s doc comment). Waits for the real
/// `centralManagerDidUpdateState` event rather than guessing an interval;
/// `timeout` is only a safety net for the case that event never arrives.
@MainActor
private final class BluetoothReadinessWatcher: NSObject, CBCentralManagerDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var manager: CBCentralManager?
    private var timeoutTask: Task<Void, Never>?

    func waitUntilReady(timeout: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            manager = CBCentralManager(
                delegate: self,
                queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: false]
            )
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resume(with: .failure(BluetoothReadinessError.timedOut))
            }
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor [weak self] in
            self?.handleStateUpdate(state)
        }
    }

    private func handleStateUpdate(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            resume(with: .success(()))
        case .poweredOff:
            resume(with: .failure(BluetoothReadinessError.poweredOff))
        case .unauthorized:
            resume(with: .failure(BluetoothReadinessError.unauthorized))
        case .unsupported:
            resume(with: .failure(BluetoothReadinessError.unsupported))
        case .resetting, .unknown:
            break // the transient window this type exists to wait out
        @unknown default:
            break
        }
    }

    private func resume(with result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(with: result)
    }
}

private enum BluetoothReadinessError: Error, LocalizedError {
    case poweredOff
    case unauthorized
    case unsupported
    case timedOut

    var errorDescription: String? {
        switch self {
        case .poweredOff:
            "Turn on Bluetooth to connect to your glasses."
        case .unauthorized:
            "Allow Bluetooth access in Settings to connect to your glasses."
        case .unsupported:
            "This iPhone does not support Bluetooth."
        case .timedOut:
            "Couldn't reach Bluetooth. Try again."
        }
    }
}
