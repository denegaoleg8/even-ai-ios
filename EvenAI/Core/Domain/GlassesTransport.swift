import Foundation

/// A user-visible navigation event originating from G2's own touchpad —
/// surfaced so `AIConversationEngine` can know when the user has
/// manually navigated away from (or explicitly back to) the "live" page
/// of the conversation timeline, without owning any BLE/pagination
/// detail itself. See `MentraGlassesTransport`'s doc comment on
/// `didReceive(event:)` for exactly which G2 touch gestures produce
/// which case.
enum GlassesNavigationEvent: Sendable, Equatable {
    /// The currently visible page within whatever page set is active
    /// changed to `index` (0-based) — page 0 is always "the live page"
    /// by convention (see `GlassesPresentationLayer.conversationPages`).
    case pageChanged(index: Int)
    /// The user double-tapped — G2's one distinct, unambiguous "take me
    /// back" gesture (confirmed against the vendored SDK's own
    /// `OsEventType`/gesture mapping: `.doubleClick` → `"double_tap"`,
    /// never produced by a swipe). Requests an immediate jump back to
    /// the live page, regardless of how many pages away the user
    /// currently is.
    case returnToLiveRequested
}

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

    /// Displays an already-paginated sequence of pages — e.g. from
    /// `GlassesPresentationLayer.pages(for:)` — skipping the "derive
    /// pages from one string" step `sendText(_:)` itself does via
    /// `GlassesTextPaginator`. Same semantics as `sendText(_:)`: always
    /// replaces whatever pagination state existed, starting fresh at
    /// page 1 — no "append to the previous message" case, and no second/
    /// duplicate pagination state anywhere. Throws
    /// `GlassesTransportError.notConnected` if not currently connected.
    func displayPages(_ pages: [String]) async throws

    /// Raw PCM audio frames captured from G2's own microphone (16kHz,
    /// 16-bit, mono, signed little-endian). No elements are delivered
    /// unless `setMicrophoneEnabled(true)` has been called and glasses are
    /// connected. Foreground-only — this does not imply any background
    /// audio capability.
    func microphonePCMUpdates() async -> AsyncStream<Data>

    /// Enables or disables the microphone (whichever `AudioSource`
    /// `setPreferredAudioSource(_:)` was last called with — `.g2Mic` if
    /// never called), routing raw PCM to `microphonePCMUpdates()`.
    /// Independent of `connect()`/`disconnect()` — does not affect
    /// connection lifecycle. Throws `GlassesTransportError.notConnected`
    /// if enabling while not connected; disabling is always safe to call.
    func setMicrophoneEnabled(_ enabled: Bool) async throws

    /// Selects which physical microphone subsequent `setMicrophoneEnabled(true)`
    /// calls use — see `AudioSource`'s own doc comment. Safe to call at
    /// any time, including mid-session; takes effect on the next
    /// `setMicrophoneEnabled(true)` call. A default no-op implementation
    /// is provided below so every existing conformer (tests, `MockGlassesTransport`)
    /// keeps compiling unchanged; only `MentraGlassesTransport` gives
    /// this real behavior.
    func setPreferredAudioSource(_ source: AudioSource) async

    /// User-initiated navigation events from G2's own touchpad — see
    /// `GlassesNavigationEvent`. A default no-op (empty stream)
    /// implementation is provided below for the same reason as
    /// `setPreferredAudioSource(_:)`.
    func navigationEvents() async -> AsyncStream<GlassesNavigationEvent>
}

extension GlassesTransport {
    func setPreferredAudioSource(_ source: AudioSource) async {}
    func navigationEvents() async -> AsyncStream<GlassesNavigationEvent> {
        AsyncStream { _ in }
    }
}
