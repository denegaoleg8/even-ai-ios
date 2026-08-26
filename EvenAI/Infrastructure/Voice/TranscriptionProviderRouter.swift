import Foundation

/// `ContinuousTranscribing` implementation that owns provider SELECTION —
/// the local-first architecture pass's central fix. Before this type
/// existed, `EvenAIApp` hardcoded `OpenAIRealtimeTranscriber` as THE
/// production transcriber (Milestone 8b), meaning Live Translation
/// structurally could not start without Railway/auth succeeding first (see
/// `URLSessionRealtimeTranscriptionSocket.connect()`'s `ensureSession()`
/// call). This type wraps both a local (`GlassesSpeechTranscriber`) and a
/// cloud (`OpenAIRealtimeTranscriber`) transcriber behind the same
/// `ContinuousTranscribing` protocol and decides, per `startTranscribing`
/// call, which one actually runs — `LiveTranslationService` itself has no
/// idea which provider is active, exactly as it had no idea before this
/// type existed.
///
/// ## Provider selection contract (never violated silently)
///
/// - `.onDevice`: ALWAYS uses `local`, never `cloud` — if `local` can't
///   start (recognizer unavailable for the resolved locale, on-device
///   model not installed), this THROWS rather than silently sending audio
///   to a backend. Matches the product requirement verbatim: "Do not
///   silently send audio/text to cloud if the user selected On-device."
/// - `.cloud`: ALWAYS uses `cloud` — identical to production behavior
///   before this pass existed, requires Railway/auth, by explicit user
///   choice.
/// - `.auto` (default): tries `local` first; only if `local.startTranscribing`
///   throws (i.e. can't even begin — never mid-stream, since a stream that
///   already started successfully is trusted for its own lifetime) does it
///   fall back to `cloud`, and ONLY if `cloudFallbackAllowed()` says a
///   cloud attempt is reasonable right now (keeps a fully airplane-mode
///   session from wasting time on a doomed network attempt before
///   surfacing the real, local failure). A local failure is logged
///   (`STT_PROVIDER_FALLBACK`) either way so which path actually ran is
///   always traceable.
///
/// `lastActiveProvider` is the one piece of state `LiveTranslationService`
/// (and the Settings/Live Translation UI, per the product's "clear
/// provider labeling" requirement) reads back — never inferred, always set
/// at the exact moment a provider's `startTranscribing` call is about to
/// be attempted.
@MainActor
final class TranscriptionProviderRouter: ContinuousTranscribing, @unchecked Sendable {
    private let local: any OnDeviceTranscribing
    private let cloud: ContinuousTranscribing
    private let mode: @MainActor () -> TranscriptionProviderMode
    /// Resolves the on-device locale `local` should use for the CURRENT
    /// source-language setting — re-read every time a session (re)starts
    /// or `applyCurrentLocale()` is called, never cached, so it always
    /// reflects whatever `LiveTranslationService.sourceLanguageMode` is
    /// right now. Defaulted to `Locale.autoupdatingCurrent`-driven Auto
    /// resolution; overridable for tests.
    private let resolveLocale: @MainActor () -> Locale
    /// `.auto` mode's cloud-fallback gate — real production wiring checks
    /// basic network reachability so a genuinely offline device fails fast
    /// with the true local error instead of hanging on a doomed connection
    /// attempt first. Defaults to `true` (always allowed to try) so tests/
    /// previews that don't care about this nuance don't need to supply it.
    private let cloudFallbackAllowed: @MainActor () -> Bool

    private(set) var lastActiveProvider: ActiveTranscriptionProvider?

    init(
        local: any OnDeviceTranscribing,
        cloud: ContinuousTranscribing,
        mode: @escaping @MainActor () -> TranscriptionProviderMode,
        resolveLocale: @escaping @MainActor () -> Locale,
        cloudFallbackAllowed: @escaping @MainActor () -> Bool = { true }
    ) {
        self.local = local
        self.cloud = cloud
        self.mode = mode
        self.resolveLocale = resolveLocale
        self.cloudFallbackAllowed = cloudFallbackAllowed
    }

    /// Pushes the current `resolveLocale()` result into `local` — called by
    /// `LiveTranslationService.setSourceLanguageMode(_:)` so an explicit
    /// EN/DE/PL switch (or a switch back to Auto) takes effect immediately
    /// on an already-listening on-device session, mirroring how the real
    /// `TranslationSession` is already reconfigured live on the same
    /// event (see `RootView.syncTranslationConfiguration()`). Harmless,
    /// cheap no-op if the resolved locale hasn't actually changed or if
    /// `.cloud` is currently active (the local transcriber isn't even
    /// running, so there's nothing to reconfigure).
    func applyCurrentLocale() {
        local.setLocale(resolveLocale())
    }

    func startTranscribing(pcmUpdates: AsyncStream<Data>) async throws -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        local.setLocale(resolveLocale())
        switch mode() {
        case .onDevice:
            lastActiveProvider = .onDevice
            DiagnosticTrace.log("STT_PROVIDER_SELECTED", "provider=onDevice mode=onDevice locale=\(local.locale.identifier)")
            return try await local.startTranscribing(pcmUpdates: pcmUpdates)
        case .cloud:
            lastActiveProvider = .cloud
            DiagnosticTrace.log("STT_PROVIDER_SELECTED", "provider=cloud mode=cloud")
            return try await cloud.startTranscribing(pcmUpdates: pcmUpdates)
        case .auto:
            do {
                lastActiveProvider = .onDevice
                DiagnosticTrace.log("STT_PROVIDER_SELECTED", "provider=onDevice mode=auto locale=\(local.locale.identifier)")
                return try await local.startTranscribing(pcmUpdates: pcmUpdates)
            } catch {
                DiagnosticTrace.log("STT_PROVIDER_FALLBACK", "reason=localUnavailable error=\(error) cloudAllowed=\(cloudFallbackAllowed())")
                guard cloudFallbackAllowed() else { throw error }
                lastActiveProvider = .cloud
                DiagnosticTrace.log("STT_PROVIDER_SELECTED", "provider=cloud mode=auto reason=localFallback")
                return try await cloud.startTranscribing(pcmUpdates: pcmUpdates)
            }
        }
    }

    func stopTranscribing() async {
        // Both are safe to call unconditionally even if never started —
        // each implementation's own `stopInternal()` guards on its own
        // `isActive`/`wasActive` flag and is a no-op otherwise (confirmed
        // by reading both `GlassesSpeechTranscriber.stopInternal()` and
        // `OpenAIRealtimeTranscriber.stopInternal()`). Stopping the one
        // that ISN'T active is always a harmless no-op — simpler and just
        // as correct as branching on `lastActiveProvider`.
        await local.stopTranscribing()
        await cloud.stopTranscribing()
    }

    var reconnectCount: Int {
        get async {
            switch lastActiveProvider {
            case .cloud: await cloud.reconnectCount
            case .onDevice, nil: await local.reconnectCount
            }
        }
    }
}
