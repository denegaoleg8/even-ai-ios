import Foundation

/// One update from an in-progress or just-finished utterance.
///
/// ## Why this exists (major performance pass, streaming translation)
///
/// `ContinuousTranscribing` used to yield only finalized text — interim
/// results were filtered out internally, so a caller never saw growing
/// partials. That made "the Ukrainian translation should begin appearing
/// on G2 as close to real time as technically possible" structurally
/// impossible: every phrase waited for full utterance finalization
/// (silence-debounced, ~1.3s of dead air) before translation even started.
/// `.partial(_:)` now carries the transcriber's own best-effort, still-
/// growing recognition of the CURRENT utterance — the same interim text
/// `SFSpeechRecognitionResult`/OpenAI's realtime `partial_transcript`
/// event already produce internally, now actually surfaced instead of
/// discarded. `.final(_:)` is exactly the old (only) case: one
/// finalized utterance, authoritative and stable.
enum TranscriptionUpdate: Sendable, Equatable {
    case partial(String)
    case final(String)
}

/// Abstraction over continuous, foreground speech transcription sourced
/// from a PCM stream (`GlassesTransport.microphonePCMUpdates()`) — either
/// G2's own microphone relayed over BLE, or (once `AudioSource.phoneMic`
/// is selected) the phone's own mic, captured by the SDK's own
/// `PhoneMic`/`AVAudioEngine` internals and delivered through the exact
/// same delegate callback; this protocol itself has no audio-source
/// concept of its own either way. `GlassesSpeechTranscriber` is the
/// concrete implementation (Apple's `Speech` framework, fed manually
/// constructed `AVAudioPCMBuffer`s — no `AVAudioEngine` mic tap of its
/// own, since the audio arrives already captured, from whichever source
/// was selected).
///
/// `SFSpeechRecognizer`'s practical on-device session-duration limit is
/// handled internally too: sessions are restarted transparently mid-stream
/// so the caller sees one continuous sequence of updates, never a stream
/// termination caused by a duration limit alone.
protocol ContinuousTranscribing: Sendable {
    /// Starts transcribing `pcmUpdates`. Yields zero or more `.partial(_:)`
    /// updates for the utterance currently being spoken, followed by
    /// exactly one `.final(_:)` once it's finalized, then repeats for the
    /// next utterance. Finishes only when `stopTranscribing()` is called,
    /// the PCM source stream ends, or recognition fails unrecoverably
    /// (surfaced as a thrown error).
    func startTranscribing(pcmUpdates: AsyncStream<Data>) async throws -> AsyncThrowingStream<TranscriptionUpdate, Error>

    /// Stops the current session and tears down any in-flight recognition
    /// state. Safe to call even if not currently transcribing.
    func stopTranscribing() async

    /// Lifetime count of automatic reconnect attempts made by this
    /// transcriber instance — `CONVERSATION_SESSION_METRICS`'s
    /// `sttReconnects` field (Section 2/3 audio-reliability
    /// instrumentation). Defaults to `0` via the extension below; only
    /// `OpenAIRealtimeTranscriber` (the one implementation that owns a
    /// real, reconnectable socket) has anything to report.
    /// `ScriptedContinuousTranscriber`/`GlassesSpeechTranscriber` (no
    /// reconnect concept) need no changes to conform.
    var reconnectCount: Int { get async }
}

extension ContinuousTranscribing {
    var reconnectCount: Int {
        get async { 0 }
    }
}

/// A `ContinuousTranscribing` implementation that recognizes ONE
/// configurable on-device locale at a time — `GlassesSpeechTranscriber` is
/// the real implementation. Factored out as its own protocol (rather than
/// `TranscriptionProviderRouter` depending on the concrete class directly)
/// so tests can substitute a fake that doesn't touch the real `Speech`
/// framework/audio session (which needs a real, authorized device/
/// simulator environment `xcodebuild test` can't always guarantee) while
/// still exercising the router's actual provider-selection logic.
@MainActor
protocol OnDeviceTranscribing: ContinuousTranscribing {
    var locale: Locale { get }
    func setLocale(_ locale: Locale)
}
