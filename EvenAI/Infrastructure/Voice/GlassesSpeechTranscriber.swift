import AVFoundation
import Foundation
import Speech

/// `ContinuousTranscribing` implementation using only Apple's `Speech`
/// framework — no third-party dependency. Consumes raw PCM `Data` (16kHz,
/// 16-bit, mono, signed little-endian — G2's own microphone format, see
/// `MicPcmEvent`) by manually constructing `AVAudioPCMBuffer`s, since this
/// audio never touches `AVAudioEngine`'s own input node — there is no
/// phone microphone involved anywhere in this feature; G2's own
/// microphone, relayed over BLE, is the only audio source.
///
/// First-milestone limitation, deliberate: a single `en-US` recognizer is
/// used regardless of what's actually being spoken — "support at minimum
/// English → Ukrainian" per the product spec for this milestone. Genuine
/// Ukrainian speech fed through an English-locale recognizer will not
/// transcribe cleanly (there is no Cyrillic in its language model), so it
/// will tend to produce garbled or low-quality English-ish text rather
/// than clean Ukrainian — `LiveTranslationViewModel`'s language-detection
/// step operates on whatever this recognizer outputs, so its accuracy is
/// bounded by this single-locale choice. Recognizing additional source
/// languages (e.g. running a second recognizer, or switching locale) is
/// the natural extension point for a later milestone.
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
/// `LiveTranslationService`: this is the one place in the Live
/// Translation feature that already imports `AVFoundation`/`Speech`, and
/// keeping it here means `LiveTranslationServiceTests` (which exercises
/// `LiveTranslationService` through the `ScriptedContinuousTranscriber`
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
final class GlassesSpeechTranscriber: ContinuousTranscribing, @unchecked Sendable {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
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
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?

    nonisolated init() {}

    func startTranscribing(pcmUpdates: AsyncStream<Data>) async throws -> AsyncThrowingStream<String, Error> {
        stopInternal()

        guard let recognizer, recognizer.isAvailable, let audioFormat else {
            throw VoiceInputError.recognizerUnavailable
        }

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
        beginNewSession(recognizer: recognizer)

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
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            newRequest.requiresOnDeviceRecognition = true
        }
        request = newRequest
        task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            Task { @MainActor [weak self] in
                self?.handle(result: result, error: error, recognizer: recognizer)
            }
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, recognizer: SFSpeechRecognizer) {
        guard isActive else { return }

        if let result, result.isFinal {
            continuation?.yield(result.bestTranscription.formattedString)
            beginNewSession(recognizer: recognizer)
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
            beginNewSession(recognizer: recognizer)
        }
    }

    private func append(_ pcm: Data, format: AVAudioFormat) {
        // A `nil` here means a malformed/empty PCM chunk was silently
        // dropped — kept visible rather than swallowed entirely, since
        // there's no other signal anywhere that this happened.
        guard let buffer = Self.pcmBuffer(from: pcm, format: format) else {
            DiagnosticTrace.log("LIVE_TRACE", "append(_:format:) — pcmBuffer(from:format:) returned nil, dropping \(pcm.count) bytes")
            return
        }
        request?.append(buffer)
    }

    private func stopInternal() {
        let wasActive = isActive
        isActive = false
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
