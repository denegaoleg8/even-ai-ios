import Foundation

/// Abstraction over continuous, foreground speech transcription sourced
/// from G2's own microphone PCM stream (`GlassesTransport.microphonePCMUpdates()`)
/// — G2's own microphone, relayed over BLE, is the only audio source
/// anywhere in this app; there is no phone-microphone path.
/// `GlassesSpeechTranscriber` is the concrete implementation (Apple's
/// `Speech` framework, fed manually constructed `AVAudioPCMBuffer`s — no
/// `AVAudioEngine` mic tap, since the audio doesn't come from the phone's
/// own hardware).
///
/// Only finalized utterances are ever yielded — interim results are
/// filtered out internally; a caller never sees growing partials.
/// `SFSpeechRecognizer`'s practical on-device session-duration limit is
/// handled internally too: sessions are restarted transparently mid-stream
/// so the caller sees one continuous sequence of final transcripts, never
/// a stream termination caused by a duration limit alone.
protocol ContinuousTranscribing: Sendable {
    /// Starts transcribing `pcmUpdates`. Each stream element is one
    /// finalized utterance. Finishes only when `stopTranscribing()` is
    /// called, the PCM source stream ends, or recognition fails
    /// unrecoverably (surfaced as a thrown error).
    func startTranscribing(pcmUpdates: AsyncStream<Data>) async throws -> AsyncThrowingStream<String, Error>

    /// Stops the current session and tears down any in-flight recognition
    /// state. Safe to call even if not currently transcribing.
    func stopTranscribing() async
}
