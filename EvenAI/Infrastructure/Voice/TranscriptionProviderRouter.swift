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
/// - `.cloud`: prefers `cloud`, but — as of the Cloud-mode production-safety
///   fix below — transparently falls back to `local` if `cloud` fails,
///   EITHER at start time (e.g. `ensureSession()`/`POST auth/device` failing
///   because Railway is unreachable — the confirmed real-world cause; see
///   this type's own fix history) OR mid-session (the WebSocket handshake
///   or connection dropping after `startTranscribing` already returned —
///   `OpenAIRealtimeTranscriber`'s own bounded reconnect budget exhausted).
///   Explicit Cloud selection is a REQUEST, not a hard requirement the
///   session must die for — the whole point of the local-first
///   architecture is that Railway being unavailable must never break Live
///   Translation, regardless of which provider setting is selected. Only
///   if BOTH `cloud` and the subsequent `local` fallback fail does this
///   throw. `onCloudFallback` is invoked (main-actor) exactly when this
///   happens, so `LiveTranslationService` can surface a truthful,
///   non-blocking notice instead of a misleading auth/G2 error.
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
/// be attempted, and updated again (still on the main actor) if a Cloud
/// session transparently falls back to local mid-stream.
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
    /// The error that caused the MOST RECENT explicit-Cloud session to
    /// fall back to local — `nil` whenever the current/most recent session
    /// didn't need to fall back (including any `.onDevice`/`.auto`
    /// session, where this concept doesn't apply). Cleared at the start of
    /// every new `startTranscribing` call so a stale reason from a
    /// previous session never lingers.
    private(set) var lastCloudFailureReason: Error?
    /// Invoked on the main actor exactly when an explicit-Cloud session
    /// falls back to on-device — at start time or mid-session — so
    /// `LiveTranslationService` can surface a truthful, immediate notice
    /// ("Cloud transcription is currently unavailable. Using on-device
    /// transcription.") without polling. Settable post-construction (not
    /// an init parameter): `EvenAIApp` constructs this router before
    /// `LiveTranslationService` exists (this router is one of that type's
    /// own init parameters), so the callback is wired up right after.
    var onCloudFallback: (@MainActor (Error) -> Void)?

    /// Tracks the background task supervising an in-flight Cloud→local
    /// fallback (see `startTranscribing`'s `.cloud` case) purely so
    /// `stopTranscribing()` can cancel it defensively — the task already
    /// exits on its own the moment `local`/`cloud`'s own stream finishes
    /// (which their own `stopTranscribing()` calls trigger), so this is a
    /// belt-and-suspenders safeguard against a leaked task, not something
    /// correctness actually depends on.
    private var cloudSupervisorTask: Task<Void, Never>?

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
        lastCloudFailureReason = nil
        switch mode() {
        case .onDevice:
            lastActiveProvider = .onDevice
            DiagnosticTrace.log("STT_PROVIDER_SELECTED", "provider=onDevice mode=onDevice locale=\(local.locale.identifier)")
            return try await local.startTranscribing(pcmUpdates: pcmUpdates)
        case .cloud:
            return startCloudWithLocalFallback(pcmUpdates: pcmUpdates)
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

    /// Explicit Cloud mode, made production-safe: attempts `cloud` first
    /// (the user's actual selection), but never lets a cloud failure —
    /// whether it happens before a single byte of audio is sent (Railway
    /// unreachable at `ensureSession()`/`POST auth/device`, confirmed the
    /// real-world failure mode) or after the stream nominally started
    /// (a WebSocket handshake/connection that drops once
    /// `OpenAIRealtimeTranscriber`'s own bounded reconnect budget is
    /// exhausted) — end the session. Either failure lands in the SAME
    /// `catch` below, because a `ContinuousTranscribing.startTranscribing`
    /// call's contract is "throws, or returns a stream that itself can
    /// later throw" — both are caught by wrapping the whole attempt
    /// (the initial `try await cloud.startTranscribing` AND the
    /// subsequent `for try await` over its stream) in one `do` block.
    ///
    /// Returns ONE continuous outward stream — `LiveTranslationService`
    /// never sees a "provider changed" event, exactly like it never sees
    /// `OpenAIRealtimeTranscriber`'s own internal reconnects or
    /// `GlassesSpeechTranscriber`'s own internal session-duration-limit
    /// rollovers. `pcmUpdates` is safe to hand to `local` after `cloud`
    /// fails: if `cloud` never got far enough to start consuming it (a
    /// start-time failure — the confirmed common case), it's untouched;
    /// if `cloud` DID start consuming it and then failed, `cloud
    /// .stopTranscribing()` (called before the fallback attempt) tears
    /// down its consumer task first, so `local` becomes the sole consumer
    /// going forward — the same "a few in-flight chunks are lost, G2's
    /// mic keeps streaming regardless" trade-off this codebase already
    /// accepts for `OpenAIRealtimeTranscriber`'s own reconnects and
    /// `GlassesSpeechTranscriber`'s own session rollovers.
    private func startCloudWithLocalFallback(pcmUpdates: AsyncStream<Data>) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        // Set SYNCHRONOUSLY, before the stream is even constructed — a
        // caller awaiting `startTranscribing(pcmUpdates:)`'s return must
        // see `lastActiveProvider == .cloud` immediately after that
        // `await` resolves, matching every other case's own synchronous
        // assignment. The `Task` below only does the async attempt/
        // fallback work; the "which provider is this attempt" bookkeeping
        // itself can't wait on it without racing any caller that checks
        // `lastActiveProvider` right after `startTranscribing` returns.
        lastActiveProvider = .cloud
        DiagnosticTrace.log("STT_PROVIDER_SELECTED", "provider=cloud mode=cloud")
        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    let cloudStream = try await self.cloud.startTranscribing(pcmUpdates: pcmUpdates)
                    for try await update in cloudStream {
                        continuation.yield(update)
                    }
                    // The cloud stream ended without throwing — either an
                    // explicit stop (stopTranscribing() was called
                    // externally, which is what makes `cloud`'s own
                    // continuation finish cleanly) or, in principle, a
                    // provider that simply ends its stream on its own.
                    // Either way, NOT a failure — no fallback warranted.
                    continuation.finish()
                } catch {
                    guard !Task.isCancelled else { return }
                    self.lastCloudFailureReason = error
                    DiagnosticTrace.log("STT_CLOUD_FALLBACK", "reason=\(error)")
                    await self.cloud.stopTranscribing()
                    self.onCloudFallback?(error)
                    do {
                        self.lastActiveProvider = .onDevice
                        DiagnosticTrace.log(
                            "STT_PROVIDER_SELECTED",
                            "provider=onDevice mode=cloud reason=cloudFallback locale=\(self.local.locale.identifier)"
                        )
                        let localStream = try await self.local.startTranscribing(pcmUpdates: pcmUpdates)
                        for try await update in localStream {
                            continuation.yield(update)
                        }
                        continuation.finish()
                    } catch {
                        // Mirrors the outer catch's own guard: a deliberate
                        // `stopTranscribing()` while the fallback's local
                        // stream is active must end cleanly, never be
                        // misreported as "both providers failed" — see
                        // this method's own doc comment on why cancellation
                        // is handled defensively at both levels.
                        guard !Task.isCancelled else { return }
                        // Both cloud AND the local fallback failed — there
                        // is genuinely nothing left to try. Surfaces the
                        // LOCAL error (not the original cloud one): it's
                        // the truthful, final reason nothing could start,
                        // and `LiveTranslationStartError.classifyTranscriberStartFailure`
                        // already classifies e.g. `VoiceInputError`
                        // correctly as an on-device-speech message, never
                        // a misleading G2/auth one.
                        DiagnosticTrace.log("STT_PROVIDER_FALLBACK_EXHAUSTED", "cloudError=\(String(describing: self.lastCloudFailureReason)) localError=\(error)")
                        continuation.finish(throwing: error)
                    }
                }
            }
            self.cloudSupervisorTask = task
            continuation.onTermination = { _ in
                task.cancel()
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
        cloudSupervisorTask?.cancel()
        cloudSupervisorTask = nil
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
