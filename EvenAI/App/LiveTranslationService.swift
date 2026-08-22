import Foundation
import Observation

/// Ambient G2-microphone translation — app-level, not owned by any screen.
/// G2's own mic stays enabled continuously once started; finalized foreign-
/// language phrases are translated to Ukrainian and shown directly on G2
/// via `GlassesTransport.displayPages(_:)` (Milestone 6) — the translation
/// alone at first, then updated with `GlassesPresentationLayer`-formatted
/// suggested replies once generation completes, guarded so a slower,
/// now-superseded turn's replies can never overwrite a newer turn's
/// display (see `generateSuggestedReplies(for:)`). Nothing here ever touches
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
    /// Milestone 2: the app-level shared conversation/session record —
    /// see `AgentContextStore`'s doc comment. Defaulted to a fresh,
    /// private instance rather than a required parameter so every
    /// existing construction call site (tests included) keeps compiling
    /// unchanged; `EvenAIApp` passes the one real, shared instance
    /// explicitly.
    private let agentContextStore: AgentContextStore
    /// Milestone 4: generates suggested replies for a finalized foreign-
    /// language turn — provider-agnostic (see `SuggestedReplyGenerating`'s
    /// doc comment). Defaulted to `NoOpSuggestedReplyGenerator()` (no
    /// real provider chosen yet) for the same reason `agentContextStore`
    /// is defaulted — every existing construction call site keeps
    /// compiling unchanged.
    private let replyGenerator: SuggestedReplyGenerating

    private var consumeTask: Task<Void, Never>?
    private var connectionObserverTask: Task<Void, Never>?
    /// Milestone 6: one entry per in-flight `generateSuggestedReplies(for:)`
    /// call — tracked (not fire-and-forget-and-forget) purely so `stop()`
    /// can cancel them, satisfying "disconnect/stop does not leave stale
    /// display state." Cleared wholesale on `stop()`; not individually
    /// removed on completion, since a Live Translation session realistically
    /// never accumulates more than a handful of these before it ends.
    private var replyGenerationTasks: [Task<Void, Never>] = []
    /// The user's explicit on/off intent, distinct from `state` — guards
    /// `observeConnection()` so a disconnect/reconnect cycle before the
    /// user has ever started Live Translation doesn't do anything.
    private var isEnabledIntent = false

    private static let ukrainianLanguageCode = "uk"

    init(
        glassesTransport: GlassesTransport,
        transcriber: ContinuousTranscribing,
        translator: LanguageTranslating,
        agentContextStore: AgentContextStore = AgentContextStore(),
        replyGenerator: SuggestedReplyGenerating = NoOpSuggestedReplyGenerator()
    ) {
        self.glassesTransport = glassesTransport
        self.transcriber = transcriber
        self.translator = translator
        self.agentContextStore = agentContextStore
        self.replyGenerator = replyGenerator
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
        // Milestone 6: cancel any suggested-reply generation still in
        // flight — a completion after this point must never call
        // `displayPages` again (the transport itself would likely reject
        // it once disconnected/mic-disabled anyway, but this avoids ever
        // attempting it, and avoids leaving an orphaned Task running).
        replyGenerationTasks.forEach { $0.cancel() }
        replyGenerationTasks.removeAll()
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

        // Milestone 2: record this turn in the shared session — additive
        // only, never affects what reaches G2 below. Uses
        // `liveConversationTurn(...)` (not the plain initializer) for its
        // own belt-and-suspenders Ukrainian-nulling, even though the
        // `languageCode != Self.ukrainianLanguageCode` guard above already
        // means this line is never reached for Ukrainian speech.
        let turn = ConversationTurn.liveConversationTurn(
            originalText: text,
            detectedLanguage: languageCode,
            ukrainianTranslation: displayText
        )
        agentContextStore.appendTurn(turn)

        // Milestone 6: translation must not wait for reply generation —
        // displayed immediately, via `GlassesPresentationLayer` (empty
        // `suggestedReplies` at this point, so this is exactly the
        // translation page(s) alone, byte-for-byte what plain
        // `sendText(displayText)` would have produced).
        do {
            try await glassesTransport.displayPages(GlassesPresentationLayer.pages(for: turn))
        } catch {
            // Same reasoning as the translation catch above — displaying
            // this has no other visibility.
            DiagnosticTrace.log("LIVE_TRACE", "displayPages failed for \"\(displayText.prefix(60))\": \(error)")
        }

        // Runs independently of this method's caller (the consume loop)
        // — a slow/real generator must never delay processing the next
        // finalized phrase. Tracked in `replyGenerationTasks` only so
        // `stop()` can cancel it; nothing here is awaited by `handle`.
        let replyTask = Task { [weak self] in
            guard let self else { return }
            await self.generateSuggestedReplies(for: turn)
        }
        replyGenerationTasks.append(replyTask)
    }

    /// Milestone 4/6: best-effort — runs independently of `handle(final:)`
    /// and never affects the translation already displayed there either
    /// way. `turn` was already appended to `agentContextStore` with empty
    /// `suggestedReplies`; a thrown error, or cancellation, here just
    /// leaves it that way, per the product requirement that a reply-
    /// generation failure must never hide the turn's own translation.
    /// `recentTurns` excludes `turn` by id (not by array position — this
    /// runs concurrently with the next phrase's own processing, so a
    /// later turn may already have been appended by the time this reads
    /// `agentContextStore.session.turns`) and is oldest-first, matching
    /// `SuggestedReplyContext`'s documented convention.
    ///
    /// Guards, right before updating G2's display, that `turn` is still
    /// the session's latest turn — "newest finalized turn always becomes
    /// the active G2 content," so a slower-to-generate older turn must
    /// never overwrite what a newer turn has already put on screen. The
    /// turn's own `suggestedReplies` are still recorded in
    /// `agentContextStore` either way (visible in Chat/history), only the
    /// G2 *display* update is skipped when stale.
    private func generateSuggestedReplies(for turn: ConversationTurn) async {
        guard !Task.isCancelled else { return }

        let context = SuggestedReplyContext(
            recentTurns: agentContextStore.session.turns.filter { $0.id != turn.id },
            contextItems: agentContextStore.session.contextItems
        )
        do {
            let replies = try await replyGenerator.generateReplies(for: turn, context: context)
            guard !Task.isCancelled else { return }

            var updatedTurn = turn
            // Capped here regardless of what the generator returned —
            // G2's display constraint is enforced at this one choke
            // point, not trusted to every possible generator.
            updatedTurn.suggestedReplies = Array(replies.prefix(3))
            agentContextStore.updateTurn(updatedTurn)

            guard agentContextStore.session.latestTurn?.id == updatedTurn.id else { return }
            // No replies to add — the translation already on screen is
            // already correct, so there's nothing to redisplay.
            guard !updatedTurn.suggestedReplies.isEmpty else { return }
            do {
                try await glassesTransport.displayPages(GlassesPresentationLayer.pages(for: updatedTurn))
            } catch {
                DiagnosticTrace.log("LIVE_TRACE", "displayPages (suggested replies) failed: \(error)")
            }
        } catch {
            DiagnosticTrace.log("LIVE_TRACE", "suggested-reply generation failed: \(error)")
        }
    }
}
