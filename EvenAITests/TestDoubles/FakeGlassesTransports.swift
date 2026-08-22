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

    func displayPages(_ pages: [String]) async throws {
        throw GlassesTransportError.notConnected
    }

    func microphonePCMUpdates() async -> AsyncStream<Data> {
        AsyncStream { _ in }
    }

    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        throw GlassesTransportError.notConnected
    }
}

/// Records every `sendText` call so a test can assert exactly what was
/// mirrored to the glasses — used to verify `ChatMessageSender` (and, via
/// it, `ChatViewModel.sendDraft()`) actually reaches the glasses mirror,
/// without needing a real connection. Also used directly by
/// `LiveTranslationServiceTests`. Always reports `.connected` so
/// `sendText` never short-circuits on `GlassesTransportError.notConnected`.
actor SpyGlassesTransport: GlassesTransport {
    private(set) var sentTexts: [String] = []
    /// Every `displayPages(_:)` call, in order — kept entirely separate
    /// from `sentTexts` (not derived from it, and `sendText(_:)` below is
    /// deliberately left untouched) so a test can assert on the new
    /// Milestone 6 page-set API without any risk of changing what
    /// `sentTexts`-based assertions already see.
    private(set) var displayedPageSets: [[String]] = []
    /// Every `setMicrophoneEnabled(_:)` call, in order — used by
    /// `LiveTranslationServiceTests` to verify the mic is enabled on
    /// start and disabled on stop.
    private(set) var microphoneEnabledCalls: [Bool] = []

    func connectionStateUpdates() async -> AsyncStream<GlassesTransportState> {
        AsyncStream { $0.yield(.connected) }
    }

    func connect() async throws {}
    func disconnect() async {}

    func sendText(_ text: String) async throws {
        sentTexts.append(text)
    }

    func displayPages(_ pages: [String]) async throws {
        displayedPageSets.append(pages)
    }

    func microphonePCMUpdates() async -> AsyncStream<Data> {
        AsyncStream { _ in }
    }

    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        microphoneEnabledCalls.append(enabled)
    }
}

/// Like `SpyGlassesTransport`, but its connection state can be changed
/// after the fact via `simulateConnectionChange(_:)` — used by
/// `LiveTranslationServiceTests` to verify the service stops itself when
/// G2 disconnects mid-session, something `SpyGlassesTransport`'s
/// single-value-forever stream can't simulate.
actor ControllableGlassesTransport: GlassesTransport {
    private(set) var sentTexts: [String] = []
    private(set) var displayedPageSets: [[String]] = []
    private(set) var microphoneEnabledCalls: [Bool] = []
    private var currentState: GlassesTransportState
    private var stateContinuation: AsyncStream<GlassesTransportState>.Continuation?

    init(initialState: GlassesTransportState = .connected) {
        currentState = initialState
    }

    func connectionStateUpdates() async -> AsyncStream<GlassesTransportState> {
        AsyncStream { continuation in
            stateContinuation = continuation
            continuation.yield(currentState)
        }
    }

    func connect() async throws {}
    func disconnect() async {}

    // Deliberately no connected-state guard here — unchanged from before
    // this milestone, since "existing plain sendText behavior remains
    // unchanged" is an explicit requirement.
    func sendText(_ text: String) async throws {
        sentTexts.append(text)
    }

    func displayPages(_ pages: [String]) async throws {
        guard currentState == .connected else {
            throw GlassesTransportError.notConnected
        }
        displayedPageSets.append(pages)
    }

    func microphonePCMUpdates() async -> AsyncStream<Data> {
        AsyncStream { _ in }
    }

    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        microphoneEnabledCalls.append(enabled)
    }

    /// Test hook: simulate an out-of-band connection-state change (e.g. an
    /// unexpected disconnect) after a subscriber has already started
    /// observing `connectionStateUpdates()`.
    func simulateConnectionChange(_ state: GlassesTransportState) {
        currentState = state
        stateContinuation?.yield(state)
    }
}
