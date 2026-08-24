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

    /// Subscribers to raw G2 microphone PCM — see `microphonePCMUpdates()`.
    private var pcmContinuations: [UUID: AsyncStream<Data>.Continuation] = [:]

    /// Mirrors `GlassesSpeechTranscriber`'s hardcoded format assumption —
    /// see `micPcmSampleRate` and its `AVAudioFormat(commonFormat: .pcmFormatInt16, channels: 1, ...)`.
    private static let assumedSampleRate = 16000
    private static let assumedBitsPerSample = 16
    private static let assumedChannels = 1

    /// Pagination for whatever text is currently on G2's display — pure
    /// state, no SDK dependency (see its own doc comment). One instance
    /// per transport, replaced wholesale on every `sendText(_:)` call.
    private var pagination = GlassesPaginationState()

    /// Root-cause fix (Display-First milestone): `sdk.glasses.connected`
    /// and `sdk.glasses.ready` are two distinct vendored-SDK flags —
    /// `connected` is true as soon as basic BLE pairing completes,
    /// `ready` (== the SDK's internal `fullyBooted`) only becomes true
    /// once the SDK's own G2 auth sequence finishes and it starts the
    /// internal loop that actually creates a page / writes anything over
    /// BLE (confirmed by reading the vendored G2.swift/DeviceManager.swift
    /// sources — see this milestone's report). A `displayPages(_:)` call
    /// made while connected-but-not-ready was previously silently
    /// swallowed by the SDK forever. This pure, SDK-independent gate
    /// (mirrors `GlassesPaginationState`'s own testability pattern) holds
    /// at most the single newest such call and replays it once readiness
    /// is observed, so nothing is dropped and nothing is duplicated.
    private var readinessGate = GlassesReadinessGate()

    /// TEMPORARY — Display-First milestone diagnostics. Identifies each
    /// `displayPages(_:)` call in the `G2_DISPLAY_TRACE` log so a second
    /// call replacing the first (or a stale-turn race) is visible as two
    /// distinct call IDs rather than an ambiguous pair of identical-looking
    /// log lines. Remove once the production G2 display path is
    /// physically confirmed reliable.
    private var displayCallCounter = 0

    /// Upper bound on how long `connect()` will wait for CoreBluetooth's
    /// central-manager state to settle before giving up — see
    /// `BluetoothReadinessWatcher`. This is a safety net for a wait that is
    /// otherwise driven entirely by the real `centralManagerDidUpdateState`
    /// event, not the primary mechanism itself.
    private static let bluetoothReadyTimeout: Duration = .seconds(10)

    /// See `setMicrophoneEnabled(_:)`'s doc comment — covers the vendored
    /// SDK's traced ~1.6s worst-case internal mic-arm sequence with margin.
    private static let micArmSettleDelay: Duration = .seconds(2)

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
        DiagnosticTrace.log("G2_DISPLAY_TRACE", "DISCONNECTED explicit disconnect() called")
        sdk.disconnect()
        pagination.clear()
        readinessGate.discardPending()
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
        try await displayPages(GlassesTextPaginator.pages(for: text))
    }

    /// Displays an already-paginated sequence of pages — `sendText(_:)`
    /// above is now just this, fed `GlassesTextPaginator`'s own output,
    /// so there is exactly one place pagination is actually started/sent
    /// from, not two. Milestone 6: `LiveTranslationService` calls this
    /// directly with `GlassesPresentationLayer.pages(for:)`'s output,
    /// which is already page-shaped and needs no further splitting.
    func displayPages(_ pages: [String]) async throws {
        // TEMPORARY diagnostics for the Display-First milestone — remove
        // once the production G2 display path is physically confirmed
        // reliable. Never logs raw audio/PCM, never fires per-PCM-packet
        // (this is a per-display-call log, at most a few times a minute).
        displayCallCounter += 1
        let callID = displayCallCounter
        DiagnosticTrace.log(
            "G2_DISPLAY_TRACE",
            "DISPLAY_START callID=\(callID) pageCount=\(pages.count) firstText=\"\(pages.first?.prefix(60) ?? "")\""
        )
        DiagnosticTrace.log("G2_ROOT_TRACE", "DISPLAY_CALL text=\"\(pages.first?.prefix(60) ?? "")\" connected=\(sdk.glasses.connected) ready=\(sdk.glasses.ready)")

        guard sdk.glasses.connected else {
            DiagnosticTrace.log("G2_DISPLAY_TRACE", "DISPLAY_ERROR callID=\(callID) reason=notConnected")
            DiagnosticTrace.log("G2_ROOT_TRACE", "DISPLAY_DROPPED reason=notConnected")
            throw GlassesTransportError.notConnected
        }
        DiagnosticTrace.log("G2_DISPLAY_TRACE", "CONNECTED callID=\(callID)")
        DiagnosticTrace.log("G2_ROOT_TRACE", "CONNECTED connected=true ready=\(sdk.glasses.ready)")

        // Root-cause fix: `connected` alone does not mean the SDK's
        // internal display-reconcile loop has started (see
        // `readinessGate`'s doc comment) — sending now would be silently
        // swallowed forever. Queue the newest request instead; the
        // `didUpdateGlasses` delegate callback below replays it the
        // moment `ready` actually becomes true.
        guard let pagesToSendNow = readinessGate.requestDisplay(pages, ready: sdk.glasses.ready) else {
            DiagnosticTrace.log("G2_ROOT_TRACE", "DISPLAY_DROPPED reason=notReadyYet(fullyBooted=false) — queued, will flush once ready")
            return
        }
        try await performDisplay(pagesToSendNow, callID: callID)
    }

    /// The actual SDK call — pagination + `sdk.displayText`. Shared by the
    /// direct (`ready == true`) path in `displayPages(_:)` and the
    /// readiness-flush path in `didUpdateGlasses`, so there is exactly one
    /// place that ever touches `pagination`/calls the SDK, matching this
    /// file's existing "one choke point" convention.
    private func performDisplay(_ pages: [String], callID: Int) async throws {
        // A previous page set was still active — this call replaces it.
        // Surfacing this explicitly is what would reveal a stale-turn
        // race (an older async result clobbering a newer one) or an
        // unexpectedly rapid double-call.
        if let previousPage = pagination.currentPage {
            DiagnosticTrace.log(
                "G2_DISPLAY_TRACE",
                "DISPLAY_REPLACED callID=\(callID) previousPageCount=\(pagination.pages.count) previousCurrentText=\"\(previousPage.prefix(60))\""
            )
        }

        pagination.start(withPages: pages)
        DiagnosticTrace.log("G2_DISPLAY_TRACE", "PAGE_COUNT=\(pages.count) callID=\(callID)")

        guard let firstPage = pagination.currentPage else {
            DiagnosticTrace.log("G2_DISPLAY_TRACE", "DISPLAY_ERROR callID=\(callID) reason=emptyPageSet")
            return
        }
        // G2_ROOT_TRACE — the exact (only) SDK entry point this file calls
        // to reach the glasses. SDK audit (confirmed by reading the
        // vendored source, not assumed): `MentraBluetoothSDK.displayText(_:)`
        // → `DeviceManager.displayText(_:)` → `Task { await sgc?.sendTextWall(text) }`
        // — a detached, unawaited Task. `sendTextWall`/`sendTextAt` do not
        // write to BLE themselves either: they only mutate a private
        // `textContainers` array and signal a separate ~100ms-interval
        // reconcile loop (`displayReconcileTask`/`reconcileDisplay()`),
        // which is the sole actual sender — and only sends at all if the
        // SDK's own private `pageCreated` flag is true; otherwise the
        // content is buffered until reconcile itself detects "page down
        // with pending content" and rebuilds. None of `pageCreated`,
        // `reconcileDisplay()`, or the BLE write inside it are reachable
        // through the public API, so a true `DISPLAY_COMMAND_SERIALIZED`/
        // `DISPLAY_COMMAND_SENT`/`DISPLAY_ACK` checkpoint cannot be added
        // at this layer without modifying the vendored SDK. The closest
        // available equivalent is `G2_SDK_LOG` (see `didLog(_:)` above),
        // which forwards that internal reconcile/recovery activity's own
        // logging verbatim — e.g. "G2: updateText id=..." is the real
        // evidence a command left the SDK toward the device; its absence
        // after a DISPLAY_SDK_ENTRY is evidence it didn't.
        DiagnosticTrace.log("G2_ROOT_TRACE", "SDK_CALL method=MentraBluetoothSDK.displayText(_:) text=\"\(firstPage.prefix(60))\"")
        DiagnosticTrace.log("G2_DISPLAY_TRACE", "DISPLAY_SDK_ENTRY callID=\(callID)")
        do {
            try await sdk.displayText(firstPage)
        } catch {
            DiagnosticTrace.log("G2_DISPLAY_TRACE", "DISPLAY_ERROR callID=\(callID) error=\(error)")
            DiagnosticTrace.log("G2_ROOT_TRACE", "SDK_ERROR \(error)")
            throw error
        }
        // Reaching this line only proves `MentraBluetoothSDK.displayText`
        // returned without throwing — per the vendored source, that
        // function's body is fire-and-forget (an unawaited `Task` all the
        // way down to the actual BLE write), so this is NOT proof the
        // text reached G2. See this milestone's report, question 2.
        DiagnosticTrace.log("G2_ROOT_TRACE", "DISPLAY_DONE (Swift call returned — NOT proof of physical display, see report)")
        DiagnosticTrace.log("G2_DISPLAY_TRACE", "DISPLAY_COMMAND_SEND_RESULT callID=\(callID) result=returnedWithoutThrowing (NOT proof of physical display — see G2_SDK_LOG for the SDK's own internal reconcile/send activity)")
        DiagnosticTrace.log("G2_DISPLAY_TRACE", "PAGE_1_SENT callID=\(callID) text=\"\(firstPage.prefix(60))\"")
        DiagnosticTrace.log("G2_DISPLAY_TRACE", "DISPLAY_COMPLETE callID=\(callID)")
    }

    /// See `pcmContinuations`. No seeding of a "current" value — unlike
    /// `connectionStateUpdates()`, there is no meaningful "current" PCM
    /// frame, only a live feed while the mic is enabled.
    func microphonePCMUpdates() async -> AsyncStream<Data> {
        AsyncStream { continuation in
            let id = UUID()
            pcmContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.pcmContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    /// `sendTranscript`/`sendLc3Data` are always `false`: the SDK's local-
    /// transcription pipeline (`SherpaOnnxTranscriber`) is compiled out of
    /// this SwiftPM distribution (`#if !SWIFT_PACKAGE || MENTRA_FEATURE_LOCAL_STT`
    /// in the vendored source), so `.localTranscription` events never fire
    /// in this build — confirmed by tracing every call site of
    /// `Bridge.sendLocalTranscription`. Raw PCM (`didReceiveMicPcm`,
    /// forwarded via `microphonePCMUpdates()`) is transcribed ourselves
    /// instead (see `GlassesSpeechTranscriber`). LC3 is skipped too: it's
    /// a bandwidth optimization with no on-device decoder available here,
    /// and PCM already works.
    ///
    /// Enabling when not yet connected doesn't force lazy `sdk` construction
    /// on its own — `sdk.glasses.connected` is checked first, which is only
    /// ever true after `sdk` already exists. Disabling is guarded on
    /// `isSDKStarted` for the same reason `connectionStateUpdates()` avoids
    /// touching `sdk` before it's needed: constructing it would trigger the
    /// Bluetooth permission prompt as a side effect of merely leaving Live
    /// Translation.
    ///
    /// `micArmSettleDelay` after enabling: confirmed against the vendored
    /// SDK's `G2.swift` that `setMicEnabled(true)` is NOT a simple one-shot
    /// command — G2's mic only exists inside a live "EvenHub page"
    /// (`pageCreated`). If none exists yet (e.g. Live Translation is
    /// started before anything has ever been displayed on G2 this
    /// session), `setMicEnabled` routes through `restartMic()` →
    /// (0.5s settle) → `rebuildState()` (0.3s + 0.3s settle) →
    /// `restartMicIfAlreadyEnabled()` → `restartMic()` again (another 0.5s
    /// settle) before the actual `audioControlMessage(enable: true)` is
    /// sent — roughly 1.6s worst-case, entirely internal to the SDK, with
    /// no completion event or error exposed through the public API. Without
    /// this delay, a caller that starts feeding PCM immediately after
    /// `setMicrophoneEnabled(true)` returns may see no audio at all for
    /// that entire window. Sized with margin above the traced worst case.
    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        guard enabled else {
            if isSDKStarted {
                sdk.setMicState(enabled: false, useGlassesMic: true)
            }
            return
        }
        guard isSDKStarted, sdk.glasses.connected else {
            throw GlassesTransportError.notConnected
        }
        sdk.setMicState(enabled: true, useGlassesMic: true, sendTranscript: false, sendLc3Data: false)
        try? await Task.sleep(for: Self.micArmSettleDelay)
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
            DiagnosticTrace.log("G2_DISPLAY_TRACE", "DISCONNECTED glasses reported disconnected, clearing pagination")
            pagination.clear()
            readinessGate.discardPending()
        } else if let pendingPages = readinessGate.flushIfReady(ready: glasses.ready) {
            // Root-cause fix: readiness just became true (or this is the
            // first update where it already was) while a display call was
            // queued — replay it now, exactly once. `displayText` is
            // itself async, and this delegate callback isn't, so this
            // mirrors the existing swipe-handling pattern below (a
            // detached `Task`, not awaited by the delegate call).
            DiagnosticTrace.log("G2_ROOT_TRACE", "flushing pending display now that ready=true, pageCount=\(pendingPages.count)")
            let callID = displayCallCounter + 1
            displayCallCounter = callID
            Task { [weak self] in
                try? await self?.performDisplay(pendingPages, callID: callID)
            }
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
        guard case .touch(let touch) = event else { return }

        // SDK-audit finding: every non-swipe touch/gesture event (including
        // "system_exit") used to be silently discarded right here — this
        // transport had no visibility into G2 exiting our display at all.
        // Confirmed via the vendored G2.swift source: a systemExit/
        // abnormalExit event means "the firmware killed our page (and the
        // mic)" — it marks the SDK's private `pageCreated` flag false and
        // deliberately does NOT rebuild by itself (to avoid a rebuild/exit
        // storm against the firmware's own paired dashboard-close event) —
        // recovery is left to either that paired event or new pending
        // display content reaching the reconcile loop. Logged
        // unconditionally so a future physical test can directly correlate
        // "glasses went blank" with this event's timestamp.
        DiagnosticTrace.log("G2_DEVICE_EVENT", "gestureName=\(touch.gestureName ?? "unknown")")

        if touch.isSwipe {
            let nextPage: String?
            switch touch.gestureName {
            case "swipe_down": nextPage = pagination.advance()
            case "swipe_up": nextPage = pagination.retreat()
            default: nextPage = nil
            }

            guard let nextPage else { return }
            // TEMPORARY diagnostics for the Display-First milestone —
            // remove once the production G2 display path is physically
            // confirmed reliable. `currentIndex` is 0-based; logged
            // 1-based to match the PAGE_N_SENT convention used in
            // displayPages(_:).
            let pageNumber = pagination.currentIndex + 1
            DiagnosticTrace.log("G2_DISPLAY_TRACE", "PAGE_\(pageNumber)_SENT (swipe) text=\"\(nextPage.prefix(60))\"")
            redisplay(nextPage, reason: "swipe")
            return
        }

        // SDK-audit fix: proactively re-send our currently active page when
        // the firmware reports it killed our display. This does not bypass
        // or fake anything — it calls the exact same public
        // `sdk.displayText(_:)` API `performDisplay(_:callID:)` already
        // uses, exactly the same pattern the swipe handler above already
        // relies on to redisplay after a page change. What it fixes: per
        // G2.swift, recovering from a torn-down page depends on either the
        // firmware's own paired dashboard-close event (rate-limited/
        // deduped, and — per that file's own comment — deliberately NOT
        // triggered by systemExit itself) or NEW pending display content
        // reaching the SDK's reconcile loop. Without this, if the exit
        // happens between two translated phrases (or after the last one in
        // a session), nothing would ever prompt a rebuild. Re-sending
        // identical, already-current content is a safe no-op if the page
        // was actually still fine (the reconcile loop simply re-writes the
        // same text) and is what nudges recovery if it wasn't.
        guard let textToRedisplay = Self.exitRecoveryRedisplayText(
            gestureName: touch.gestureName, currentPage: pagination.currentPage
        ) else { return }
        DiagnosticTrace.log("G2_DISPLAY_TRACE", "REDISPLAY_AFTER_EXIT gesture=\(touch.gestureName ?? "unknown") text=\"\(textToRedisplay.prefix(60))\"")
        redisplay(textToRedisplay, reason: "system_exit recovery")
    }

    /// Pure decision logic for the post-exit recovery path above, isolated
    /// so it's unit-testable without touching the real `sdk` — the actual
    /// `sdk.displayText(_:)` call remains untested at that boundary, matching
    /// this file's existing scope (the swipe-redisplay path was never
    /// exercised against a real `sdk` either; see `MentraGlassesTransportTests`).
    /// Returns the text to redisplay, or `nil` if this event shouldn't
    /// trigger one — either it's not an exit-class gesture, or there's
    /// nothing currently on screen to recover.
    nonisolated static func exitRecoveryRedisplayText(gestureName: String?, currentPage: String?) -> String? {
        guard gestureName?.localizedCaseInsensitiveContains("exit") == true else { return nil }
        return currentPage
    }

    /// Shared by the swipe-navigation redisplay and the post-exit recovery
    /// redisplay above — both are delegate-triggered (not `async`), so both
    /// dispatch through the same detached `Task` pattern, and both must
    /// swallow a failure the same way (a screen update failing here is not
    /// a connection failure).
    private func redisplay(_ text: String, reason: String) {
        Task { @MainActor [weak self] in
            do {
                try await self?.sdk.displayText(text)
            } catch {
                DiagnosticTrace.log("G2_DISPLAY_TRACE", "DISPLAY_ERROR (\(reason) redisplay) error=\(error)")
            }
        }
    }

    /// Forwards raw mic PCM to every `microphonePCMUpdates()` subscriber —
    /// no filtering/buffering here, that's `GlassesSpeechTranscriber`'s job.
    func mentraBluetoothSDK(_ sdk: MentraBluetoothSDK, didReceiveMicPcm event: MicPcmEvent) {
        // `GlassesSpeechTranscriber` hardcodes its assumed format (16000 Hz,
        // 16-bit, mono) independently of whatever the SDK actually reports
        // here; this is the one place that sees the SDK's real, per-event
        // metadata, so this ongoing safety check lives here rather than
        // requiring a `GlassesTransport` protocol change to thread the
        // metadata through. Not a leftover diagnostic — a real format
        // drift would otherwise silently corrupt every buffer fed to
        // `SFSpeechRecognizer`, with nothing else to catch it.
        if event.sampleRate != Self.assumedSampleRate
            || event.bitsPerSample != Self.assumedBitsPerSample
            || event.channels != Self.assumedChannels {
            DiagnosticTrace.log(
                "LIVE_TRACE",
                "FORMAT_MISMATCH sdkSampleRate=\(event.sampleRate) sdkBitsPerSample=\(event.bitsPerSample) sdkChannels=\(event.channels) assumedSampleRate=\(Self.assumedSampleRate) assumedBitsPerSample=\(Self.assumedBitsPerSample) assumedChannels=\(Self.assumedChannels)"
            )
        }

        for continuation in pcmContinuations.values {
            continuation.yield(event.pcm)
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

    /// SDK-audit finding: `MentraBluetoothSDKDelegate.didLog(_:)` exists and
    /// was never implemented here — this transport had zero visibility
    /// into the vendored SDK's own internal logging, which is the closest
    /// thing to a "lowest useful boundary" available without modifying the
    /// vendored source (confirmed by reading it: `displayText(_:)`'s
    /// actual work happens inside `G2`'s private `sendTextAt`/
    /// `reconcileDisplay`/`recoverPageAndMic`, none of which is reachable
    /// through the public API — but every step of that internal path logs
    /// through `Bridge.log`, e.g. "G2: sendText() - page down, buffering
    /// latest content...", "G2: reconcileDisplay() - page down with
    /// pending content, rebuilding once", "G2: updateText id=... rect=...
    /// content=...", "G2: recover(dashboard-close) - rebuilding EvenHub
    /// page"). Forwarding these is what actually proves (or disproves)
    /// whether a `displayText(_:)` call's content ever reached the point
    /// of being written to G2, as opposed to merely being buffered into a
    /// container that a torn-down page never got to send.
    func mentraBluetoothSDK(_ sdk: MentraBluetoothSDK, didLog message: String) {
        DiagnosticTrace.log("G2_SDK_LOG", message)
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

/// Pure state machine gating display sends on G2 readiness — no SDK/
/// CoreBluetooth dependency, so it's directly unit-testable, mirroring
/// `GlassesPaginationState`'s own testability pattern. `MentraGlassesTransport`
/// owns one instance and translates its output into `performDisplay(_:callID:)`
/// calls; this type only tracks "is a display request currently waiting
/// on readiness, and if so, what's the newest one."
///
/// Holds at most ONE pending page set: a second `requestDisplay(_:ready:)`
/// call while still not ready replaces (never queues alongside) the first
/// — this is what makes "newest turn wins" and "never duplicate a page
/// set" hold at this layer, matching `LiveTranslationService`'s own
/// newest-turn-wins guarantee at the presentation layer above it.
struct GlassesReadinessGate {
    private(set) var pendingPages: [String]?

    /// Call on every `displayPages(_:)` request. Returns the pages to
    /// send immediately when already ready; returns `nil` (and records
    /// `pages` as the new — and only — pending set) when not.
    mutating func requestDisplay(_ pages: [String], ready: Bool) -> [String]? {
        guard ready else {
            pendingPages = pages
            return nil
        }
        // A ready, direct send supersedes anything still queued from a
        // moment ago (e.g. a not-ready call immediately followed by one
        // that arrived once readiness had already landed).
        pendingPages = nil
        return pages
    }

    /// Call whenever the SDK reports its current readiness (e.g. from the
    /// `didUpdateGlasses` delegate callback). Returns the pending pages to
    /// flush — exactly once — if `ready` is true and something is
    /// waiting; `nil` otherwise (nothing pending, or still not ready).
    mutating func flushIfReady(ready: Bool) -> [String]? {
        guard ready, let pages = pendingPages else { return nil }
        pendingPages = nil
        return pages
    }

    /// Call on disconnect (explicit or SDK-reported) — a pending display
    /// for a session that no longer exists must never be replayed into a
    /// future, unrelated one.
    mutating func discardPending() {
        pendingPages = nil
    }
}
