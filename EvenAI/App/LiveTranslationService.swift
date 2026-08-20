import Foundation
import Observation

/// Ambient G2-microphone translation — app-level, not owned by any screen.
/// G2's own mic stays enabled continuously once started; finalized foreign-
/// language phrases are translated to Ukrainian and shown directly on G2
/// via `GlassesTransport.sendText(_:)`. Nothing here ever touches
/// `ChatMessageSending`/`ChatServicing` — recognized/translated phrases are
/// only ever exposed as read-only observable state (`lastRecognizedPhrase`/
/// `lastTranslation`) for `ChatView` to display, never submitted as chat
/// messages.
///
/// Constructed once in `EvenAIApp` and injected via `.environment(_:)`,
/// mirroring `AppState`/`AuthState` — survives navigation between Voice,
/// Chat, Settings, etc. by construction, since it isn't owned by any of
/// those views. `RootView` hosts the one `.translationTask` this needs
/// (SwiftUI only vends a `TranslationSession` through that modifier, and it
/// has to be attached to something that outlives any single screen).
///
/// Stops itself — never silently keeps the mic hot — on two conditions
/// only: an explicit `stop()` call, or G2 disconnecting
/// (`observeConnection()`). Deliberately does *not* react to navigation or
/// `scenePhase` — an earlier foreground-only milestone stopped Live
/// Translation whenever the app left `.active`, which also meant it
/// stopped the instant the Voice screen was merely navigated away from or
/// the screen locked; that was removed once the product requirement
/// became "survives navigation and stays active while locked, provided
/// iOS permits it" (see `UIBackgroundModes: audio` in `project.yml`, added
/// alongside this removal so a genuinely active `AVAudioSession` —
/// `GlassesSpeechTranscriber` already holds one while transcribing — has
/// something to extend background execution from). A future interruption
/// (e.g. iOS forcibly deactivating the audio session for a phone call)
/// still surfaces through the existing `consume(_:)` error path, which
/// already calls `stop()` — no separate handling needed for that case.
/// Constructing this eagerly at app launch is inert in the
/// same sense `AppContainer.live`'s `glassesTransport` already
/// is: subscribing to `connectionStateUpdates()` does not, by itself,
/// force `MentraGlassesTransport`'s lazy SDK construction or prompt for
/// Bluetooth access — only an explicit `start()` (via `setMicrophoneEnabled`)
/// does that.
@MainActor
@Observable
final class LiveTranslationService {
    enum State: Sendable, Equatable {
        case idle
        case listening
        case error(String)
    }

    private(set) var state: State = .idle
    /// The most recent recognized (source-language) phrase — read-only
    /// live information `ChatView` displays alongside `lastTranslation`.
    private(set) var lastRecognizedPhrase: String?
    /// The most recent Ukrainian translation actually sent to G2.
    private(set) var lastTranslation: String?

    private let glassesTransport: GlassesTransport
    private let transcriber: ContinuousTranscribing
    private let translator: LanguageTranslating

    private var consumeTask: Task<Void, Never>?
    private var connectionObserverTask: Task<Void, Never>?
    /// The user's explicit on/off intent, distinct from `state` — guards
    /// `observeConnection()` so a disconnect/reconnect cycle before the
    /// user has ever started Live Translation doesn't do anything.
    private var isEnabledIntent = false

    private static let ukrainianLanguageCode = "uk"

    init(
        glassesTransport: GlassesTransport,
        transcriber: ContinuousTranscribing,
        translator: LanguageTranslating
    ) {
        self.glassesTransport = glassesTransport
        self.transcriber = transcriber
        self.translator = translator
        observeConnection()
    }

    /// Enables the G2 microphone and starts the continuous transcribe →
    /// detect → translate → display loop. Safe to call again while already
    /// `.listening` (no-op).
    func start() async {
        guard state != .listening else { return }
        isEnabledIntent = true
        lastRecognizedPhrase = nil

        do {
            try await glassesTransport.setMicrophoneEnabled(true)
            let pcmUpdates = await glassesTransport.microphonePCMUpdates()
            let finals = try await transcriber.startTranscribing(pcmUpdates: pcmUpdates)
            state = .listening
            consumeTask = Task { [weak self] in
                await self?.consume(finals)
            }
        } catch {
            state = .error("Couldn't start Live Translation. Check your G2 connection and try again.")
            await stop()
        }
    }

    /// Stops transcription and disables the G2 microphone. Safe to call
    /// from any state, including if `start()` never succeeded — this is
    /// the "never leave the microphone active" guarantee, called explicitly
    /// by the user or by a lost connection.
    func stop() async {
        isEnabledIntent = false
        consumeTask?.cancel()
        consumeTask = nil
        await transcriber.stopTranscribing()
        try? await glassesTransport.setMicrophoneEnabled(false)
        // Only clears a `.listening` state — an `.error` set immediately
        // before this call (the `start()` failure path) must stay visible
        // to the user, not be silently overwritten back to `.idle`.
        if state == .listening {
            state = .idle
        }
    }

    private func observeConnection() {
        connectionObserverTask = Task { [weak self] in
            guard let self else { return }
            let updates = await self.glassesTransport.connectionStateUpdates()
            for await connectionState in updates {
                guard self.isEnabledIntent else { continue }
                switch connectionState {
                case .disconnected, .failed(_):
                    await self.stop()
                case .connected, .connecting, .scanning:
                    break
                }
            }
        }
    }

    private func consume(_ finals: AsyncThrowingStream<String, Error>) async {
        do {
            for try await final in finals {
                await handle(final: final)
            }
            if state == .listening { state = .idle }
        } catch {
            state = .error("Live Translation stopped unexpectedly. Try again.")
            await stop()
        }
    }

    /// The decision pipeline: empty/duplicate finals are dropped before
    /// ever reaching language detection; uncertain detection and Ukrainian
    /// speech both produce no output; only a confidently-detected non-
    /// Ukrainian phrase reaches `glassesTransport.sendText(_:)`. Reuses
    /// the existing `sendText(_:)`/`GlassesTextPaginator` path unchanged —
    /// no separate truncation logic needed here to keep results short
    /// enough for G2's display.
    private func handle(final rawText: String) async {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text != lastRecognizedPhrase else { return }
        lastRecognizedPhrase = text

        guard let languageCode = await translator.detectedLanguageCode(for: text) else { return }
        guard languageCode != Self.ukrainianLanguageCode else { return }

        // Deliberately not `try?`: a translation failure here has no other
        // visibility anywhere in this class — `state` stays `.listening`
        // either way, since one failed phrase shouldn't interrupt an
        // otherwise-healthy session — so this log is the only record that
        // it happened, not a diagnostic left over from investigating a
        // specific bug.
        let translated: String?
        do {
            translated = try await translator.translateToUkrainian(text, from: languageCode)
        } catch {
            DiagnosticTrace.log("LIVE_TRACE", "translation failed for \"\(text.prefix(60))\": \(error)")
            translated = nil
        }
        guard let translated else { return }
        let displayText = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayText.isEmpty else { return }

        lastTranslation = displayText
        do {
            try await glassesTransport.sendText(displayText)
        } catch {
            // Same reasoning as the translation catch above — `sendText`
            // failing here has no other visibility.
            DiagnosticTrace.log("LIVE_TRACE", "sendText failed for \"\(displayText.prefix(60))\": \(error)")
        }
    }
}
