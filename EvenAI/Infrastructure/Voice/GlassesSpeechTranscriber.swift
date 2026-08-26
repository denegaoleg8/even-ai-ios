import AVFoundation
import Foundation
import Speech

/// `ContinuousTranscribing` implementation using only Apple's `Speech`
/// framework — no third-party dependency, no network call of any kind (see
/// `startTranscribing`). Consumes raw PCM `Data` (16kHz, 16-bit, mono,
/// signed little-endian — G2's own microphone format, see `MicPcmEvent`) by
/// manually constructing `AVAudioPCMBuffer`s, since this audio never
/// touches `AVAudioEngine`'s own input node — there is no phone microphone
/// involved anywhere in this feature; G2's own microphone, relayed over
/// BLE, is the only audio source.
///
/// Single recognizer at a time, deliberately — a parallel dual-recognizer
/// (`en-US` + `uk-UA`) experiment was tried and reverted: physical-device
/// tracing showed both `recognitionTask`s immediately erroring with
/// `kAFAssistantErrorDomain Code=1110 "No speech detected"` before either
/// ever received a first PCM append, then repeatedly recreating in an
/// uncontrolled restart loop — i.e. running two concurrent `SFSpeechRecognizer`
/// sessions against the same buffer feed did not work on the tested device,
/// for reasons not yet root-caused. That's why this type still can't
/// truly *auto-detect and switch between* EN/DE/PL mid-conversation
/// on-device — but as of the local-first architecture pass, it no longer
/// needs to: `locale` (settable via `setLocale(_:)`) selects WHICH single
/// locale the one active recognizer uses, driven by
/// `SourceLanguageMode.onDeviceLocaleIdentifier` — explicit EN/DE/PL each
/// get their own correctly-localized recognizer; `.auto` picks one locale
/// per session (the device's own region if it's en/de/pl, else `en-US`)
/// and stays on it, rather than running detection across recognizers. Real
/// multi-language auto-switching within one session remains cloud-only
/// (`OpenAIRealtimeTranscriber`) — an honest platform limitation, not
/// papered over; see `TranscriptionProviderRouter`'s doc comment.
///
/// `@MainActor` + `@unchecked Sendable`: all mutable state is confined to
/// the main actor by this class-wide isolation, never accessed
/// concurrently.
///
/// Also owns activating/deactivating a real `AVAudioSession` for the
/// duration of a transcribing session — not because `SFSpeechRecognizer`
/// needs it to process manually-fed buffers (it doesn't; there's no
/// hardware I/O here), but because iOS's `audio` background execution
/// grant is tied to a genuinely active audio session, not merely a
/// declared background mode. Deliberately kept here rather than in
/// `AIConversationEngine`: this is the one place in the Live
/// Translation feature that already imports `AVFoundation`/`Speech`, and
/// keeping it here means `AIConversationEngineTests` (which exercises
/// `AIConversationEngine` through the `ScriptedContinuousTranscriber`
/// fake, never this class) never touches a real system audio API — this
/// class isn't unit-tested directly for that same reason.
/// `.record`/`.default`, no `.mixWithOthers`: the closest honest
/// category for "processing a captured audio stream for speech
/// recognition" (even though the capture itself is BLE-relayed, not local
/// hardware), and omitting `.mixWithOthers` is a deliberate, stronger
/// signal to iOS for background continuation — the real cost is that
/// starting Live Translation does interrupt other apps' audio playback,
/// which is an accepted, known trade-off, not an oversight.
@MainActor
final class GlassesSpeechTranscriber: OnDeviceTranscribing, @unchecked Sendable {
    /// The on-device recognizer locale a NEW session (or a mid-session
    /// restart via `setLocale(_:)`) uses — never `nil` after `init`.
    /// `SFSpeechRecognizer` instances are cheap, locale-scoped value
    /// objects (Apple's own guidance), so a fresh one is constructed per
    /// locale rather than cached indefinitely; this app only ever needs
    /// one of three-plus-default locales in practice.
    private(set) var locale: Locale
    private var recognizer: SFSpeechRecognizer?
    private let audioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(micPcmSampleRate),
        channels: 1,
        interleaved: true
    )

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var pcmConsumerTask: Task<Void, Never>?
    private var isActive = false
    private var continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation?

    /// Debounce-timer task for silence-based utterance finalization — see
    /// `scheduleFinalization(sessionID:)`. `SFSpeechAudioBufferRecognitionRequest`
    /// is fed G2's PCM continuously with no natural end; nothing else ever
    /// signals "this utterance is over" to the recognizer, so without this,
    /// `isFinal` never becomes true (confirmed via physical-device tracing:
    /// interim results kept arriving indefinitely, no final ever landed).
    private var finalizationTask: Task<Void, Never>?
    /// How long to wait after the most recent partial result before treating
    /// the utterance as over and calling `request.endAudio()`. Isolated as
    /// its own tunable constant per the smallest-fix requirement.
    private static let silenceDebounceInterval: Duration = .milliseconds(1300)
    /// Identifies the current recognition session so a callback from an
    /// already-replaced `task` (e.g. a final result or error arriving after
    /// `beginNewSession()` has already run again) is recognized as stale
    /// and dropped — this is what actually prevents overlapping sessions or
    /// double-processing a final phrase, since `SFSpeechRecognitionTask`
    /// gives no synchronous guarantee its old callback won't still fire
    /// once after being superseded.
    private var currentSessionID = UUID()
    /// True from the moment `endAudio()` is called on the current `request`
    /// until `beginNewSession()` replaces it — `append(_:format:)` must not
    /// feed a request that has already been told no more audio is coming
    /// (invalid per `SFSpeechAudioBufferRecognitionRequest`). G2's mic keeps
    /// streaming through this gap (never stopped for rollover); PCM
    /// arriving during it is queued in `pendingBuffersDuringFinalization`
    /// (word-loss hardening pass) rather than dropped — see that
    /// property's own doc comment for why this specific gap is worth
    /// closing.
    private var isFinalizingUtterance = false
    /// Word-loss hardening pass: PCM chunks that arrive while
    /// `isFinalizingUtterance` is true are queued here instead of being
    /// silently discarded, then fed into the NEW request the instant
    /// `beginNewSession(recognizer:)` creates one — closing the one real
    /// audio-loss window this class has (confirmed by code audit; every
    /// OTHER transition in this file is atomic on the main actor, with no
    /// gap for a concurrent `append` to observe). This specific gap is a
    /// genuine round trip to the recognizer (`endAudio()` → waiting for
    /// its actual final result to arrive asynchronously), not a
    /// synchronous step, so it can span a meaningfully long window if the
    /// user starts their NEXT utterance right as the previous one is
    /// finalizing — exactly the "occasionally misses a couple of words"
    /// symptom this pass exists to reduce. Capped defensively (see
    /// `maxPendingBuffersDuringFinalization`) — in practice this queue
    /// holds at most a few hundred milliseconds of 16kHz mono audio
    /// (a handful of chunks), never enough to matter memory-wise; the cap
    /// only guards against a pathological recognizer stall.
    private var pendingBuffersDuringFinalization: [AVAudioPCMBuffer] = []
    private static let maxPendingBuffersDuringFinalization = 64

    /// `locale` defaults to `en-US` — the same default production always
    /// used before this type became locale-configurable. Real callers
    /// (`TranscriptionProviderRouter`) always pass a resolved locale
    /// explicitly (see `SourceLanguageMode.onDeviceLocaleIdentifier` /
    /// `TranscriptionProviderRouter.resolvedLocale(for:)`); this default
    /// only matters for direct construction (previews, tests).
    nonisolated init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
    }

    // `task: SFSpeechRecognitionTask?` isn't `Sendable`, so it can't be
    // touched from `deinit` (nonisolated even on a `@MainActor` class) —
    // only the `Task<Void, Never>` handles, which are `Sendable`, are
    // cancelled here. In practice this type is owned for the app's
    // lifetime (see `AIConversationEngine`), so `deinit` is a belt-and-
    // suspenders safeguard, not a path any real session relies on;
    // `stopInternal()` is what actually cancels `task` during normal use.
    deinit {
        finalizationTask?.cancel()
        pcmConsumerTask?.cancel()
    }

    /// Changes which locale the on-device recognizer uses — called by
    /// `AIConversationEngine.setSourceLanguageMode(_:)` (via
    /// `TranscriptionProviderRouter`) so an explicit EN/DE/PL switch takes
    /// effect immediately, mirroring how `AppleLanguageTranslator`'s real
    /// `TranslationSession` is already reconfigured live on the same
    /// event. A no-op if `newLocale` already matches. If a session is
    /// currently active, seamlessly restarts recognition with the new
    /// locale using the exact same "begin a fresh session mid-stream"
    /// mechanism `beginNewSession(recognizer:)` already uses for
    /// duration-limit rollovers — G2's mic is never toggled, only the
    /// recognizer underneath it changes.
    func setLocale(_ newLocale: Locale) {
        guard newLocale.identifier != locale.identifier else { return }
        locale = newLocale
        recognizer = nil
        guard isActive, let freshRecognizer = SFSpeechRecognizer(locale: newLocale) else { return }
        recognizer = freshRecognizer
        beginNewSession(recognizer: freshRecognizer)
        DiagnosticTrace.log("LOCAL_STT_LOCALE_CHANGED", "locale=\(newLocale.identifier) reason=midSessionSwitch")
    }

    func startTranscribing(pcmUpdates: AsyncStream<Data>) async throws -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        stopInternal()

        guard let freshRecognizer = SFSpeechRecognizer(locale: locale), freshRecognizer.isAvailable, let audioFormat else {
            DiagnosticTrace.log("LOCAL_STT_UNAVAILABLE", "locale=\(locale.identifier)")
            throw VoiceInputError.recognizerUnavailable
        }
        recognizer = freshRecognizer
        DiagnosticTrace.log(
            "LOCAL_STT_SESSION_START",
            "locale=\(locale.identifier) onDeviceSupported=\(freshRecognizer.supportsOnDeviceRecognition)"
        )

        // Off the main actor: `setCategory`/`setActive` are synchronous and
        // can block for a non-trivial duration — running them on the main
        // actor risks freezing the UI for however long CoreAudio takes to
        // negotiate. Constructed fresh inside the closure, so nothing
        // actor-isolated crosses the boundary.
        try await Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        }.value

        isActive = true
        beginNewSession(recognizer: freshRecognizer)

        return AsyncThrowingStream { continuation in
            self.continuation = continuation
            pcmConsumerTask = Task { [weak self] in
                for await data in pcmUpdates {
                    guard let self, self.isActive else { break }
                    self.append(data, format: audioFormat)
                }
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.stopInternal() }
            }
        }
    }

    func stopTranscribing() async {
        stopInternal()
    }

    /// Starts a fresh recognition request/task, replacing whatever was
    /// active — used both for the very first session and for the silent
    /// mid-stream restarts that work around `SFSpeechRecognizer`'s
    /// practical on-device session-duration limit. The G2 microphone
    /// itself is never toggled by this — `append(_:format:)` keeps feeding
    /// whichever request is current.
    private func beginNewSession(recognizer: SFSpeechRecognizer) {
        finalizationTask?.cancel()
        finalizationTask = nil
        isFinalizingUtterance = false

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            newRequest.requiresOnDeviceRecognition = true
        }
        request = newRequest

        // Word-loss hardening pass: replay whatever PCM arrived while the
        // PREVIOUS request was finalizing — see `pendingBuffersDuringFinalization`'s
        // own doc comment. Oldest-first, so word order is preserved
        // exactly as G2's mic produced it.
        if !pendingBuffersDuringFinalization.isEmpty {
            DiagnosticTrace.log("LOCAL_STT_REPLAYED_PENDING_AUDIO", "count=\(pendingBuffersDuringFinalization.count)")
            for buffer in pendingBuffersDuringFinalization {
                newRequest.append(buffer)
            }
            pendingBuffersDuringFinalization.removeAll()
        }

        let sessionID = UUID()
        currentSessionID = sessionID
        task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            Task { @MainActor [weak self] in
                self?.handle(result: result, error: error, recognizer: recognizer, sessionID: sessionID)
            }
        }
    }

    /// `sessionID` must match `currentSessionID` — a callback from a `task`
    /// that `beginNewSession(recognizer:)` has already superseded is stale
    /// and ignored, which is what prevents overlapping sessions and
    /// duplicate final-phrase processing.
    private func handle(
        result: SFSpeechRecognitionResult?,
        error: Error?,
        recognizer: SFSpeechRecognizer,
        sessionID: UUID
    ) {
        guard isActive, sessionID == currentSessionID else { return }

        if let result, result.isFinal {
            finalizationTask?.cancel()
            finalizationTask = nil
            continuation?.yield(.final(result.bestTranscription.formattedString))
            beginNewSession(recognizer: recognizer)
            return
        }

        if let result, !result.isFinal {
            continuation?.yield(.partial(result.bestTranscription.formattedString))
            scheduleFinalization(sessionID: sessionID)
            return
        }

        // A session boundary (duration limit, or any other reason a task
        // ends without an isFinal result) can surface as an error rather
        // than a final result. Restart the same way, seamlessly — `isActive`
        // being false is what distinguishes this from a real failure after
        // `stopTranscribing()`. This is routine and expected (fires on
        // every session-duration-limit restart), not a failure worth
        // logging on its own.
        if error != nil {
            finalizationTask?.cancel()
            finalizationTask = nil
            beginNewSession(recognizer: recognizer)
        }
    }

    /// Resets the silence-debounce timer — called on every non-final
    /// partial result. If no new partial arrives within
    /// `silenceDebounceInterval`, `finalizeCurrentUtterance(sessionID:)`
    /// forces the current request to end, since nothing else ever will
    /// (see `finalizationTask`'s doc comment).
    private func scheduleFinalization(sessionID: UUID) {
        finalizationTask?.cancel()
        finalizationTask = Task { [weak self] in
            try? await Task.sleep(for: Self.silenceDebounceInterval)
            guard !Task.isCancelled else { return }
            self?.finalizeCurrentUtterance(sessionID: sessionID)
        }
    }

    /// Fires after `silenceDebounceInterval` of no new partial results —
    /// calls `endAudio()` so the recognizer can no longer stay open
    /// indefinitely. `beginNewSession(recognizer:)` (in `handle`'s
    /// `isFinal` branch, above) is what actually starts capturing the next
    /// utterance, once the forced final lands.
    private func finalizeCurrentUtterance(sessionID: UUID) {
        guard isActive, sessionID == currentSessionID, !isFinalizingUtterance else { return }
        finalizationTask = nil
        isFinalizingUtterance = true
        request?.endAudio()
    }

    private func append(_ pcm: Data, format: AVAudioFormat) {
        // A `nil` here means a malformed/empty PCM chunk was silently
        // dropped — kept visible rather than swallowed entirely, since
        // there's no other signal anywhere that this happened.
        guard let buffer = Self.pcmBuffer(from: pcm, format: format) else {
            DiagnosticTrace.log("LIVE_TRACE", "append(_:format:) — pcmBuffer(from:format:) returned nil, dropping \(pcm.count) bytes")
            return
        }
        // Word-loss hardening pass: the CURRENT request is winding down
        // after `endAudio()` — appending to it directly is invalid — but
        // G2's mic is never stopped for this, so real speech can still be
        // arriving. Queue it; `beginNewSession(recognizer:)` replays the
        // whole queue into the NEXT request the moment it exists, instead
        // of this audio being lost. Capped defensively against a
        // pathological recognizer stall — if the cap is ever hit, the
        // OLDEST queued audio is dropped first (bounded loss, never
        // unbounded growth), matching this queue's own "at most a few
        // hundred milliseconds" expected size.
        guard !isFinalizingUtterance else {
            if pendingBuffersDuringFinalization.count >= Self.maxPendingBuffersDuringFinalization {
                pendingBuffersDuringFinalization.removeFirst()
            }
            pendingBuffersDuringFinalization.append(buffer)
            return
        }
        request?.append(buffer)
    }

    private func stopInternal() {
        let wasActive = isActive
        isActive = false
        finalizationTask?.cancel()
        finalizationTask = nil
        isFinalizingUtterance = false
        pendingBuffersDuringFinalization.removeAll()
        pcmConsumerTask?.cancel()
        pcmConsumerTask = nil
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        continuation?.finish()
        continuation = nil

        // Only deactivate if a session was actually activated by this
        // instance — guards the defensive `stopInternal()` call at the top
        // of `startTranscribing()` (nothing to deactivate on a fresh
        // start) from needlessly deactivating-then-immediately-reactivating.
        // Fire-and-forget off the main actor for the same blocking-call
        // reason as activation; a stop doesn't need to wait on it.
        guard wasActive else { return }
        Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private static func pcmBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = UInt32(data.count / MemoryLayout<Int16>.size)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.bindMemory(to: Int16.self).baseAddress,
                  let destination = buffer.int16ChannelData?[0]
            else { return }
            destination.update(from: source, count: Int(frameCount))
        }
        return buffer
    }
}

/// Mirrors `MicPcmEvent.sampleRate`'s documented default (16kHz) without
/// requiring `Infrastructure/Voice` to import `MentraBluetoothSDK` — see
/// `GlassesTransport`'s doc comment on which layer may import that SDK.
private let micPcmSampleRate = 16000

enum VoiceInputError: Error, LocalizedError {
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            "Speech recognition isn't available right now. Try again in a moment."
        }
    }
}
