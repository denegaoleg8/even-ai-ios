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

    /// Pagination for whatever text is currently on G2's display — pure
    /// state, no SDK dependency (see its own doc comment). One instance
    /// per transport, replaced wholesale on every `sendText(_:)` call.
    private var pagination = GlassesPaginationState()

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

    /// Broadcasts `.disconnected` immediately rather than waiting on the
    /// SDK's own async `DeviceStore` → `didUpdateGlasses` propagation —
    /// makes the reset deterministic (Phase 2 hardening) instead of
    /// depending on the timing of an internal chain we don't control. If
    /// the SDK's own `didUpdateGlasses` later reports `.disconnected` too,
    /// that's a harmless, idempotent re-broadcast of the same value.
    func disconnect() async {
        sdk.disconnect()
        pagination.clear()
        broadcast(.disconnected)
    }

    /// Splits `text` into pages (see `GlassesTextPaginator`) and displays
    /// only the first — identical to the pre-pagination behavior for any
    /// text short enough to be a single page (`GlassesTextPaginator.pages`
    /// returns the original string verbatim in that case, so this is the
    /// exact same `sdk.displayText(text)` call as before). A new call here
    /// always replaces whatever pagination state existed, starting fresh
    /// at page 1 — there is no "append to the previous message" case.
    /// Subsequent pages are shown only in response to a swipe, via
    /// `didReceive(event:)` below.
    func sendText(_ text: String) async throws {
        guard sdk.glasses.connected else {
            throw GlassesTransportError.notConnected
        }
        pagination.start(withPages: GlassesTextPaginator.pages(for: text))
        guard let firstPage = pagination.currentPage else { return }
        try await sdk.displayText(firstPage)
    }

    /// Maps a raw `BluetoothSdkError` code to a clean, actionable message.
    /// `"pair_failure"` is what `MentraBluetoothSDK` reports when G2's
    /// internal 10-second dual-peripheral pairing timeout fires having
    /// found only one arm (left or right) — traced to `Bridge.
    /// sendPairFailureEvent("errors:pairNeedDisconnect")` → `dispatchBridgeEvent`'s
    /// `case "pair_failure"` → `BluetoothSdkError(code: "pair_failure",
    /// message: "errors:pairNeedDisconnect")`. Left as-is, that raw slug
    /// reaches the UI verbatim via `.failed(_:)` — not stuck, but not
    /// explicit either. Every other code passes through unchanged.
    /// Internal (not `private`) so it's directly unit-testable without
    /// constructing a real `MentraBluetoothSDK`/`CBCentralManager`.
    nonisolated static func failureMessage(forCode code: String, rawMessage: String) -> String {
        guard code == "pair_failure" else { return rawMessage }
        return "Couldn't pair with both sides of your G2. Unpair the glasses in iPhone Settings → Bluetooth, then try again."
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
        let state = Self.mapConnectionState(glasses.connection)
        // Covers every disconnect path, not just our own `disconnect()` —
        // an unexpected drop (out of range, battery, etc.) reports
        // `.disconnected` here too, and pagination must not survive it.
        if state == .disconnected {
            pagination.clear()
        }
        broadcast(state)
    }

    /// G2's touchpad reports swipes as `.touch(TouchEvent)` — confirmed via
    /// source: `OsEventType.scrollTop`/`.scrollBottom` map to
    /// `"swipe_up"`/`"swipe_down"` gesture names in `G2.swift`, forwarded
    /// through `Bridge.sendTouchEvent` to this exact delegate method. This
    /// is the SDK's only navigation-relevant event — there is no separate
    /// "next page" API (see the pagination audit); we drive our own page
    /// state machine from it. Not `async` (protocol requirement), so a
    /// resulting page change is sent via a detached `Task`, matching this
    /// file's existing pattern for delegate-triggered SDK calls (e.g.
    /// `BluetoothReadinessWatcher`'s state-update handling). Swallows a
    /// failed re-display rather than affecting connection state — a screen
    /// update failing is not a connection failure.
    func mentraBluetoothSDK(_ sdk: MentraBluetoothSDK, didReceive event: BluetoothEvent) {
        guard case .touch(let touch) = event, touch.isSwipe else { return }

        let nextPage: String?
        switch touch.gestureName {
        case "swipe_down": nextPage = pagination.advance()
        case "swipe_up": nextPage = pagination.retreat()
        default: nextPage = nil
        }

        guard let nextPage else { return }
        Task { @MainActor [weak self] in
            try? await self?.sdk.displayText(nextPage)
        }
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
        broadcast(.failed(Self.failureMessage(forCode: error.code, rawMessage: error.message)))
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

/// Splits long text into pages sized for G2's fixed-size display. Pure —
/// no SDK/CoreBluetooth dependency — so it's directly unit-testable.
///
/// G2's default text container is the full 576×288px canvas
/// (`G2.defaultTextContainer` in the vendored SDK source) with no
/// documented character limit — rendering is pixel-based, and neither the
/// SDK nor the firmware exposes any pagination/scrolling API (verified:
/// `sendTextAt` just overwrites or adds a fixed-rect container; splitting
/// text across multiple `displayText` calls does not, by itself, create
/// navigable pages). `defaultMaxCharactersPerPage` is therefore a
/// deliberately isolated, conservative estimate — not a documented
/// hardware constant — meant to be tuned after physical-device testing.
enum GlassesTextPaginator {
    /// Deliberately isolated, conservative estimate — not a documented
    /// hardware constant — meant to be tuned after physical-device
    /// testing. Lowered from an earlier, larger value once physical
    /// testing showed page-to-page swipes feeling abrupt: G2 has no true
    /// scroll or transition capability (confirmed against the vendored
    /// SDK — `updateTextMessage`'s `contentOffset`/`contentLength` fields
    /// exist in the wire protocol, but the SDK itself always sends them
    /// as `0`/full-length together, never partially, so there's no
    /// verified scroll semantics to build on), so smaller, more frequent
    /// page changes are the only lever available to make it read as more
    /// incremental than a few large jumps.
    static let defaultMaxCharactersPerPage = 140

    /// How many trailing words of the previous page are repeated at the
    /// start of the next one — a software approximation of continuity in
    /// place of real scrolling: re-showing a little of what was just read
    /// softens the instant cut between pages.
    static let defaultOverlapWordCount = 3

    /// Splits `text` into ordered pages of at most `maxCharactersPerPage`
    /// `Character`s (grapheme clusters, never raw UTF-8 bytes or Unicode
    /// scalars — a multi-byte/multi-scalar character is never split).
    /// Prefers breaking on whitespace so words aren't cut mid-word; only
    /// hard-breaks inside a single "word" when that word alone exceeds the
    /// page budget (e.g. a long URL), so no character is ever dropped.
    /// Text that already fits in one page is returned completely
    /// unchanged — this keeps `sendText`'s behavior for short messages
    /// byte-for-byte identical to before pagination existed.
    ///
    /// Each page after the first is prefixed with the last
    /// `overlapWordCount` words of the page before it (see
    /// `defaultOverlapWordCount`). This only repeats content for
    /// readability — it never changes which page any given character
    /// canonically belongs to; `coreSplit(text:maxCharactersPerPage:)`
    /// (below) is the underlying non-overlapping partition, kept separate
    /// so "no character is ever lost" stays verifiable independently of
    /// the overlap feature.
    static func pages(
        for text: String,
        maxCharactersPerPage: Int = GlassesTextPaginator.defaultMaxCharactersPerPage,
        overlapWordCount: Int = GlassesTextPaginator.defaultOverlapWordCount
    ) -> [String] {
        let corePages = coreSplit(text: text, maxCharactersPerPage: maxCharactersPerPage)
        guard corePages.count > 1, overlapWordCount > 0 else { return corePages }

        var pages: [String] = [corePages[0]]
        for index in 1 ..< corePages.count {
            let previousWords = corePages[index - 1].split(whereSeparator: { $0.isWhitespace })
            let overlapWords = previousWords.suffix(overlapWordCount)
            if overlapWords.isEmpty {
                pages.append(corePages[index])
            } else {
                pages.append(overlapWords.joined(separator: " ") + " " + corePages[index])
            }
        }
        return pages
    }

    private static func coreSplit(text: String, maxCharactersPerPage: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        let characters = Array(text)
        guard characters.count > maxCharactersPerPage, maxCharactersPerPage > 0 else { return [text] }

        var pages: [String] = []
        var pageStart = 0

        while pageStart < characters.count {
            let remaining = characters.count - pageStart
            if remaining <= maxCharactersPerPage {
                pages.append(String(characters[pageStart...]))
                break
            }

            let budgetEnd = pageStart + maxCharactersPerPage
            var breakIndex = budgetEnd
            var lastWhitespace: Int?
            var i = pageStart
            while i < budgetEnd {
                if characters[i].isWhitespace { lastWhitespace = i }
                i += 1
            }
            if let lastWhitespace, lastWhitespace > pageStart {
                breakIndex = lastWhitespace
            }
            // else: no whitespace anywhere in this page's budget (one very
            // long unbroken run of characters) — hard-break exactly at the
            // budget so every character still lands on some page.

            let pageText = String(characters[pageStart..<breakIndex])
            if !pageText.isEmpty {
                pages.append(pageText)
            }
            pageStart = breakIndex
            while pageStart < characters.count, characters[pageStart].isWhitespace {
                pageStart += 1
            }
        }

        return pages
    }
}

/// Pure pagination state machine: which page of the current message is
/// showing, and how `advance()`/`retreat()` move through them. No
/// SDK/CoreBluetooth dependency, so it's directly unit-testable —
/// `MentraGlassesTransport` owns one instance and translates its output
/// into `sdk.displayText(...)` calls; this type only tracks state.
struct GlassesPaginationState {
    private(set) var pages: [String] = []
    private(set) var currentIndex = 0

    var currentPage: String? {
        pages.indices.contains(currentIndex) ? pages[currentIndex] : nil
    }

    /// A new message always replaces whatever was showing and starts at
    /// page 1 — never appends to or merges with a previous message.
    mutating func start(withPages newPages: [String]) {
        pages = newPages
        currentIndex = 0
    }

    /// Moves to the next page and returns its text, or `nil` if already on
    /// the last page (nothing changed, nothing to (re-)send).
    mutating func advance() -> String? {
        guard currentIndex + 1 < pages.count else { return nil }
        currentIndex += 1
        return currentPage
    }

    /// Moves to the previous page and returns its text, or `nil` if
    /// already on the first page.
    mutating func retreat() -> String? {
        guard currentIndex > 0 else { return nil }
        currentIndex -= 1
        return currentPage
    }

    mutating func clear() {
        pages = []
        currentIndex = 0
    }
}
