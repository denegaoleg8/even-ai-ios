import Foundation
import Observation

/// Ambient G2-microphone translation — app-level, not owned by any screen.
/// G2's own mic stays enabled continuously once started; finalized foreign-
/// language phrases are translated to Ukrainian and shown directly on G2
/// via `GlassesTransport.displayPages(_:)` (Milestone 6) — the translation
/// alone at first, then automatically updated with
/// `GlassesPresentationLayer`-formatted suggested replies once generation
/// completes (see `processTurn(_:text:languageCode:turnStartTime:)`).
/// Nothing here ever touches `ChatMessageSending`/`ChatServicing` for the
/// phone's own Chat feature — recognized/translated phrases are only ever
/// exposed as read-only observable state (`lastRecognizedPhrase`/
/// `lastTranslation`) for `ChatView` to display; the separate "Glasses
/// Chat" persistence path is its own, explicit `chatService`/
/// `glassesChatProvider` wiring below.
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
///
/// ## Per-turn concurrency (the fix for "Live Translation hangs on one
/// phrase and never continues")
///
/// Root cause, confirmed by tracing the exact code path: `consume(_:)`'s
/// loop used to `await handle(final:)` directly, and `handle(final:)` ran
/// the ENTIRE pipeline — language resolution, translation (bounded by a
/// timeout, but the timeout only made the *caller* stop waiting; see
/// `AppleLanguageTranslator`'s own fix for why that alone wasn't enough),
/// turn creation, and G2 display (no timeout at all) — synchronously,
/// before returning. As long as `handle(final:)` hadn't returned, the loop
/// could never read the next element from `finals`, no matter how many new
/// final transcripts STT had already produced and buffered in the
/// background. A slow translation, or a G2 display call that hangs (a real
/// possibility given the BLE/SDK reconcile behavior this app has already
/// had to harden against), didn't just delay that one phrase — it wedged
/// the entire session, silently, for the rest of its lifetime.
///
/// The fix: `consume(_:)` only ever awaits a fast, synchronous-feeling
/// "prepare" phase per final (`prepareAndDispatch(final:)` — empty/dedupe
/// checks, language resolution, and appending a *draft* turn, none of
/// which touch translation, display, chat persistence, or reply
/// generation). Everything slow is handed off to an independent, per-turn
/// `Task` (`processTurn(_:text:languageCode:turnStartTime:)`), tracked
/// only so `stop()` can cancel it — never awaited by the loop. A turn's
/// `id` is assigned at the moment it's prepared (before any async work),
/// giving every trace line for that turn a stable identity from the very
/// first checkpoint, and letting `agentContextStore.session.turns` stay in
/// true chronological (spoken) order even though translations can now
/// complete out of order under real concurrency — which is also what makes
/// the existing "is this still the latest turn" staleness guard (already
/// used for suggested replies, now also used for the translation display
/// itself) meaningful: `latestTurn` always means "most recently *spoken*,"
/// never "most recently finished processing."
@MainActor
@Observable
final class LiveTranslationService {
    enum State: Sendable, Equatable {
        case idle
        case listening
        case error(String)
    }

    /// Explicit model of what's currently on G2 for the active turn —
    /// orthogonal to `state` (session listening on/off): the session can
    /// stay `.listening` through every one of these transitions, and none
    /// of them ever stop or restart STT. `.none` before any turn has ever
    /// displayed anything (or after a turn's translation fails/times out
    /// and is removed, leaving nothing on screen); `.translated` the
    /// moment a turn's Source+Ukrainian header is shown, with no reply
    /// section yet — a legitimate, stable display state on its own (see
    /// `GlassesPresentationLayer`'s doc comment: "Source + Translation, no
    /// reply section yet" is allowed, not a placeholder needing a spinner);
    /// `.withReplies` once that same turn's reply section has been added
    /// below the still-visible header. A new turn's `.translated` update
    /// always replaces whatever this held before — see `processTurn`'s
    /// staleness guard for what actually decides whether a given turn is
    /// allowed to make that transition.
    enum TurnDisplayState: Sendable, Equatable {
        case none
        case translated(turnID: ConversationTurn.ID)
        case withReplies(turnID: ConversationTurn.ID, replyCount: Int)
    }

    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            DiagnosticTrace.log("SESSION_LISTENING_STATE", "state=\(state)")
        }
    }
    /// See `TurnDisplayState`'s own doc comment. `private(set)` — the only
    /// writes happen at the exact two points G2's display actually
    /// changes (end of `processTurn`'s display block, end of
    /// `generateSuggestedReplies`'s display block), both gated by the same
    /// sequence-based staleness guard that decides whether the underlying
    /// `displayPages` call itself was even attempted.
    private(set) var currentTurnDisplayState: TurnDisplayState = .none
    /// The most recent recognized (source-language) phrase — read-only
    /// live information `ChatView` displays alongside `lastTranslation`.
    private(set) var lastRecognizedPhrase: String?
    /// The most recent Ukrainian translation actually sent to G2.
    private(set) var lastTranslation: String?
    /// The most recent raw final transcript accepted past the empty
    /// check, and when — used only for the short, time-bounded
    /// duplicate-suppression window in `prepareAndDispatch(final:)`. See
    /// that method's doc comment for why this must be time-bounded, not
    /// permanent.
    private var lastFinalReceived: (text: String, at: Date)?
    /// The user's explicit source-language choice — `.auto`, or one of the
    /// primary supported source languages. `private(set)`, changed only
    /// through `setSourceLanguageMode(_:)` (never a raw property setter),
    /// so persistence and the Auto-lock reset always happen together, never
    /// separately. Loaded from `defaults` at construction; see `init`.
    private(set) var sourceLanguageMode: SourceLanguageMode
    /// Auto mode's session-scoped language lock — see
    /// `resolveSourceLanguage(for:)`'s doc comment for the full hysteresis
    /// behavior this drives. `nil` means "not yet locked this session";
    /// reset in `start()`, exactly matching "reset the Auto language lock
    /// when a new Live Translation session begins."
    private var autoLockedLanguage: String?
    private let defaults: UserDefaults

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
    /// Milestone: "Glasses Chat" — persists each finalized, translated turn
    /// as a real message in the one persistent glasses conversation (see
    /// `GlassesChatProvider`). Both optional, defaulted to `nil`, so every
    /// existing construction call site (tests included) keeps compiling
    /// unchanged, matching `agentContextStore`/`replyGenerator`'s own
    /// pattern; `EvenAIApp` passes the real instances explicitly. `nil`
    /// means "don't persist to Chat" — never attempted, never logged as a
    /// failure, since there's nothing wrong with a caller (e.g. a test)
    /// that simply isn't exercising this feature.
    private let chatService: ChatServicing?
    private let glassesChatProvider: GlassesChatProvider?

    private var consumeTask: Task<Void, Never>?
    private var connectionObserverTask: Task<Void, Never>?
    /// One entry per in-flight per-turn pipeline task (translation →
    /// display) AND per-turn reply-generation task — tracked only so
    /// `stop()` can cancel every still-running piece of work, satisfying
    /// "disconnect/stop does not leave stale display state." Cleared
    /// wholesale on `stop()`; not individually removed on completion,
    /// since a Live Translation session realistically never accumulates
    /// more than a handful of these before it ends (same accepted pattern
    /// this file already used for the pre-decoupling reply-task list).
    private var turnTasks: [Task<Void, Never>] = []
    /// Monotonically increasing per-turn sequence number, assigned in
    /// `prepareAndDispatch(final:)` (true arrival order) — the basis for
    /// `processTurn(_:text:languageCode:turnStartTime:sequence:)`'s
    /// translation-display staleness guard. See that guard's own doc
    /// comment for why comparing against `agentContextStore.session
    /// .latestTurn` (i.e. "has a newer turn been *spoken*") is the wrong
    /// check — the right one is "has a newer turn already *displayed*."
    /// Both counters reset in `start()`, matching the Auto-lock reset:
    /// a new session's sequence numbers start fresh.
    private var turnSequenceCounter = 0
    private var highestDisplayedTurnSequence = 0
    /// The user's explicit on/off intent, distinct from `state` — guards
    /// `observeConnection()` so a disconnect/reconnect cycle before the
    /// user has ever started Live Translation doesn't do anything.
    private var isEnabledIntent = false

    private static let ukrainianLanguageCode = "uk"
    /// The primary supported source languages — everything requirement #1
    /// / #3 is scoped to. Auto mode only ever *locks* onto one of these
    /// (never onto some other confidently-detected language — a stray
    /// Spanish/French utterance still translates for that one turn, but
    /// doesn't start a session-wide lock); explicit mode is restricted to
    /// exactly these three by `SourceLanguageMode` itself.
    private static let primarySourceLanguages: Set<String> = ["en", "de", "pl"]
    /// See `lastFinalReceived`/`prepareAndDispatch(final:)`'s doc comment.
    /// Real STT double-emission of the same final arrives within (well
    /// under) this window; a deliberate new utterance of the same short
    /// word does not — the user has to pause, speak again, and a new
    /// backend VAD utterance/commit cycle has to run, which alone takes
    /// well over a second. Overridable only by tests (see `init`), which
    /// need a much shorter bound to stay fast.
    private let duplicateSuppressionWindow: TimeInterval
    /// Bounds `translator.translateToUkrainian(_:from:)` for one turn's
    /// pipeline task — see `translateWithTimeout(_:from:)`'s doc comment.
    /// Independent of `AppleLanguageTranslator`'s own internal per-call
    /// timeout (a different, deeper fix — see that type) — this one
    /// protects against a stuck call from *any* `LanguageTranslating`
    /// implementation, not just that specific one. Overridable only by
    /// tests (see `init`), which need a much shorter bound to stay fast.
    private let translationTimeout: Duration
    /// Bounds `replyGenerator.generateReplies(for:context:)` for one
    /// turn's reply-generation task — same reasoning as
    /// `translationTimeout`, for the same class of failure (a stuck
    /// network call must degrade to "no replies for this turn," never an
    /// unbounded hang). Reply generation is already fully decoupled from
    /// every other turn's processing even without this, but an unbounded
    /// wait still leaves a zombie task running for the rest of the
    /// process's lifetime, and this repo's own convention (see
    /// `translationTimeout`) is to bound every awaited external call.
    private let repliesTimeout: Duration

    /// Persisted `sourceLanguageMode` storage key — `UserDefaults`, same
    /// pattern as `GlassesChatProvider`'s reserved-chat-id persistence,
    /// not SwiftData (this is a lightweight per-device UI preference, not
    /// synced/shared conversation data).
    private static let sourceLanguageModeDefaultsKey = "com.evenai.liveTranslation.sourceLanguageMode"

    init(
        glassesTransport: GlassesTransport,
        transcriber: ContinuousTranscribing,
        translator: LanguageTranslating,
        agentContextStore: AgentContextStore = AgentContextStore(),
        replyGenerator: SuggestedReplyGenerating = NoOpSuggestedReplyGenerator(),
        translationTimeout: Duration = .seconds(8),
        chatService: ChatServicing? = nil,
        glassesChatProvider: GlassesChatProvider? = nil,
        duplicateSuppressionWindow: TimeInterval = 2,
        defaults: UserDefaults = .standard,
        repliesTimeout: Duration = .seconds(15)
    ) {
        self.glassesTransport = glassesTransport
        self.transcriber = transcriber
        self.translator = translator
        self.agentContextStore = agentContextStore
        self.replyGenerator = replyGenerator
        self.translationTimeout = translationTimeout
        self.chatService = chatService
        self.glassesChatProvider = glassesChatProvider
        self.duplicateSuppressionWindow = duplicateSuppressionWindow
        self.defaults = defaults
        self.repliesTimeout = repliesTimeout
        if let saved = defaults.string(forKey: Self.sourceLanguageModeDefaultsKey),
           let savedMode = SourceLanguageMode(rawValue: saved) {
            self.sourceLanguageMode = savedMode
        } else {
            self.sourceLanguageMode = .auto
        }
        observeConnection()
    }

    /// The one way `sourceLanguageMode` ever changes — persists the choice
    /// immediately (survives app relaunch) and resets the Auto lock,
    /// so switching e.g. Auto → EN → Auto mid-session never resumes with a
    /// stale lock from before the explicit switch.
    func setSourceLanguageMode(_ mode: SourceLanguageMode) {
        guard mode != sourceLanguageMode else { return }
        sourceLanguageMode = mode
        defaults.set(mode.rawValue, forKey: Self.sourceLanguageModeDefaultsKey)
        autoLockedLanguage = nil
        DiagnosticTrace.log("LANGUAGE_MODE", "selected=\(mode.rawValue)")
    }

    /// Enables the G2 microphone and starts the continuous transcribe →
    /// detect → translate → display loop. Safe to call again while already
    /// `.listening` (no-op).
    func start() async {
        guard state != .listening else { return }
        isEnabledIntent = true
        lastRecognizedPhrase = nil
        // "Reset the Auto language lock when a new Live Translation
        // session begins" — a lock from a previous session (possibly a
        // different speaker/language entirely) must never carry over.
        autoLockedLanguage = nil
        turnSequenceCounter = 0
        highestDisplayedTurnSequence = 0
        currentTurnDisplayState = .none

        do {
            try await glassesTransport.setMicrophoneEnabled(true)
            let pcmUpdates = await glassesTransport.microphonePCMUpdates()
            let finals = try await transcriber.startTranscribing(pcmUpdates: pcmUpdates)
            state = .listening
            consumeTask = Task { [weak self] in
                await self?.consume(finals)
            }
        } catch {
            // TEMPORARY — Milestone 8b physical-device diagnosis. Remove
            // once root-caused. See DiagnosticTrace.swift.
            DiagnosticTrace.log("8B_TRACE", "STOP reason=transcriber.startTranscribing() threw synchronously: \(error)")
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
        // Cancel every still-running per-turn pipeline/reply task — a
        // completion after this point must never call `displayPages`
        // again (the transport itself would likely reject it once
        // disconnected/mic-disabled anyway, but this avoids ever
        // attempting it, and avoids leaving orphaned tasks running).
        turnTasks.forEach { $0.cancel() }
        turnTasks.removeAll()
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
                // TEMPORARY — upstream-path diagnostic. Remove once
                // root-caused. See DiagnosticTrace.swift.
                DiagnosticTrace.log("UPSTREAM_TRACE", "TRANSCRIPT_RECEIVED text=\"\(final.prefix(60))\"")
                // Proves the loop is still pulling from `finals` — this is
                // the ONE place in the whole pipeline where "continuous
                // listening" is either true or it isn't: if this line
                // never logs again after replies for a previous turn
                // displayed, the STT stream itself stalled (or its
                // upstream producer did), not anything in this class's own
                // per-turn task graph — see this class's own doc comment
                // for why `prepareAndDispatch`/`processTurn` can't be the
                // cause of that (nothing here awaits either of them).
                DiagnosticTrace.log("NEXT_TRANSCRIPT_ACCEPTED", "text=\"\(final.prefix(60))\" sessionState=\(state)")
                await prepareAndDispatch(final: final)
            }
            if state == .listening { state = .idle }
        } catch {
            // TEMPORARY — this is the exact catch producing the physical-
            // device symptom ("Live Translation stopped unexpectedly. Try
            // again.") — logging the real underlying error here is the
            // whole point of this diagnostic pass. Remove once
            // root-caused. See DiagnosticTrace.swift.
            DiagnosticTrace.log("8B_TRACE", "STOP reason=finals stream threw, surfacing as 'stopped unexpectedly': \(error)")
            state = .error("Live Translation stopped unexpectedly. Try again.")
            await stop()
        }
    }

    /// The FAST half of the pipeline — the only part `consume(_:)`'s loop
    /// ever awaits directly. Empty/duplicate finals are dropped before
    /// ever reaching language resolution; uncertain detection and
    /// Ukrainian speech both produce no turn. Everything from here that
    /// could plausibly be slow (translation, G2 display, reply generation)
    /// is handed off to an independent per-turn `Task` in
    /// `processTurn(_:text:languageCode:turnStartTime:)` — see this
    /// class's own doc comment for why that split is what fixes "hangs on
    /// one phrase and never continues."
    private func prepareAndDispatch(final rawText: String) async {
        let turnStartTime = Date()
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        DiagnosticTrace.log("SHORT_UTTERANCE_TRACE", "RECEIVED raw=\"\(rawText)\" normalized=\"\(text)\"")

        guard !text.isEmpty else {
            DiagnosticTrace.log("SHORT_UTTERANCE_TRACE", "REJECTED reason=emptyAfterTrim")
            return
        }

        // Root cause of "hello often dropped, retrying never helps": this
        // dedup used to compare against `lastRecognizedPhrase` with no
        // time bound at all — so the FIRST time a short phrase failed
        // downstream, `lastRecognizedPhrase` had already been set to that
        // exact text, and every later, genuinely new attempt at saying the
        // SAME short word was silently treated as "just a duplicate of
        // last time" — forever, since nothing else ever reset it. A real
        // STT double-emission glitch (the actual thing this check exists
        // to catch) always arrives within a second or two of the
        // original; a deliberate new utterance of the same short word
        // minutes (or even seconds) later does not. Bounding the window
        // fixes the false-forever-rejection case while still catching
        // true rapid double-emission.
        let now = Date()
        if let last = lastFinalReceived, last.text.caseInsensitiveCompare(text) == .orderedSame,
           now.timeIntervalSince(last.at) < duplicateSuppressionWindow {
            DiagnosticTrace.log("SHORT_UTTERANCE_TRACE", "DEDUPE_REJECTED text=\"\(text)\" secondsSinceLast=\(now.timeIntervalSince(last.at))")
            return
        }
        DiagnosticTrace.log("SHORT_UTTERANCE_TRACE", "DEDUPE_PASSED text=\"\(text)\"")
        lastFinalReceived = (text, now)

        guard let languageCode = await resolveSourceLanguage(for: text) else {
            DiagnosticTrace.log("SHORT_UTTERANCE_TRACE", "REJECTED reason=languageUndetectable text=\"\(text)\"")
            return
        }
        lastRecognizedPhrase = text
        DiagnosticTrace.log("SHORT_UTTERANCE_TRACE", "LANGUAGE_ACCEPTED text=\"\(text)\" language=\(languageCode)")
        DiagnosticTrace.log("UPSTREAM_TRACE", "LANGUAGE_DETECTED language=\(languageCode)")
        guard languageCode != Self.ukrainianLanguageCode else {
            DiagnosticTrace.log("UPSTREAM_TRACE", "UKRAINIAN_IGNORED")
            DiagnosticTrace.log("SHORT_UTTERANCE_TRACE", "HANDOFF_REJECTED reason=ukrainian text=\"\(text)\"")
            return
        }
        DiagnosticTrace.log("UPSTREAM_TRACE", "FOREIGN_LANGUAGE_ACCEPTED language=\(languageCode)")
        DiagnosticTrace.log("SHORT_UTTERANCE_TRACE", "HANDOFF_ACCEPTED text=\"\(text)\" language=\(languageCode)")

        // Turn id assigned NOW, before any async work, and the turn
        // appended immediately with no translation yet (filled in later
        // via agentContextStore.updateTurn(_:) once the translation task
        // completes). This is what keeps agentContextStore.session.turns
        // in true chronological (spoken) order even though translations
        // can complete out of order under real concurrency, and gives
        // every trace line for this turn a stable id from the very first
        // checkpoint.
        let turn = ConversationTurn.liveConversationTurn(
            originalText: text,
            detectedLanguage: languageCode,
            ukrainianTranslation: nil
        )
        DiagnosticTrace.log("TURN_RECEIVED", "id=\(turn.id) text=\"\(text.prefix(60))\" language=\(languageCode)")
        DiagnosticTrace.log("FINAL_TRANSCRIPT_RECEIVED", "turnID=\(turn.id) text=\"\(text.prefix(60))\"")
        DiagnosticTrace.log("LATENCY_TRACE", "STT_FINAL id=\(turn.id) timestamp=\(turnStartTime.timeIntervalSince1970)")
        DiagnosticTrace.log("LATENCY_TRACE", "FINAL_TRANSCRIPT_TS id=\(turn.id) value=\(turnStartTime.timeIntervalSince1970)")
        DiagnosticTrace.log("REAL_TURN_TRACE", "TURN_CREATED id=\(turn.id) originalText=\"\(text.prefix(60))\"")
        DiagnosticTrace.log("UPSTREAM_TRACE", "TURN_CREATED id=\(turn.id)")
        DiagnosticTrace.log("POST_STT_TRACE", "TURN_CREATED id=\(turn.id)")
        agentContextStore.appendTurn(turn)
        // Confirms the listener/dispatch path itself is healthy at the
        // moment this turn was accepted — independent of whether this
        // turn's own translation/replies ever succeed. See
        // `NEXT_TRANSCRIPT_ACCEPTED` (in `consume(_:)`) for the
        // complementary proof that the STT stream itself keeps producing.
        DiagnosticTrace.log("LISTENER_STILL_ACTIVE", "turnID=\(turn.id) sessionState=\(state)")

        turnSequenceCounter += 1
        let sequence = turnSequenceCounter
        let task = Task { [weak self] in
            guard let self else { return }
            await self.processTurn(turn, text: text, languageCode: languageCode, turnStartTime: turnStartTime, sequence: sequence)
        }
        turnTasks.append(task)
    }

    /// The independent, per-turn pipeline: translation (bounded by
    /// `translationTimeout`) → G2 display (skipped if a newer turn has
    /// already superseded this one) → Glasses Chat persistence (best-
    /// effort, untracked, see below) → suggested-reply generation,
    /// started concurrently with display rather than after it (translation
    /// display must never wait on replies, and replies don't need display
    /// to have finished — they only need the translated turn itself).
    /// Never awaited by `consume(_:)`'s loop — a stuck or slow turn here
    /// can only ever block itself, never any later turn.
    private func processTurn(_ turn: ConversationTurn, text: String, languageCode: String, turnStartTime: Date, sequence: Int) async {
        let turnID = turn.id
        DiagnosticTrace.log("TURN_PROCESSING_STARTED", "turnID=\(turnID) sequence=\(sequence)")

        DiagnosticTrace.log("UPSTREAM_TRACE", "TRANSLATION_START text=\"\(text.prefix(60))\"")
        DiagnosticTrace.log("POST_STT_TRACE", "TRANSLATION_REQUEST_SENT language=\(languageCode)")
        DiagnosticTrace.log("TRANSLATION_TASK_START", "id=\(turnID)")
        let translationStart = Date()
        DiagnosticTrace.log("LATENCY_TRACE", "TRANSLATION_START id=\(turnID)")
        DiagnosticTrace.log("LATENCY_TRACE", "TRANSLATION_START_TS id=\(turnID) value=\(translationStart.timeIntervalSince1970)")
        DiagnosticTrace.log(
            "LATENCY_TRACE",
            "STT_TO_TRANSLATION_START_MS id=\(turnID) value=\(Int(translationStart.timeIntervalSince(turnStartTime) * 1000))"
        )

        let translated: String
        do {
            translated = try await translateWithTimeout(text, from: languageCode)
            let translationDoneAt = Date()
            let translationLatencyMs = Int(translationDoneAt.timeIntervalSince(translationStart) * 1000)
            DiagnosticTrace.log("LATENCY_TRACE", "TRANSLATION_END id=\(turnID)")
            DiagnosticTrace.log("LATENCY_TRACE", "TRANSLATION_DONE_TS id=\(turnID) value=\(translationDoneAt.timeIntervalSince1970)")
            DiagnosticTrace.log("LATENCY_TRACE", "TRANSLATION_LATENCY_MS id=\(turnID) value=\(translationLatencyMs)")
            DiagnosticTrace.log("TRANSLATION_TASK_END", "id=\(turnID)")
            DiagnosticTrace.log("POST_STT_TRACE", "TRANSLATION_RESPONSE_RECEIVED length=\(translated.count)")
            DiagnosticTrace.log("UPSTREAM_TRACE", "TRANSLATION_RESULT text=\"\(translated.prefix(60))\"")
        } catch is CancellationError {
            DiagnosticTrace.log("TRANSLATION_TASK_CANCELLED", "id=\(turnID)")
            // A cancelled turn's pipeline never ran (stop() cancels every
            // tracked task) — leaving its draft turn behind would show a
            // permanently-untranslated entry in history for a session the
            // user explicitly ended.
            agentContextStore.removeTurn(id: turnID)
            DiagnosticTrace.log("TURN_PIPELINE_RELEASED", "id=\(turnID) reason=translationCancelled")
            return
        } catch is TranslationTimeoutError {
            DiagnosticTrace.log("TRANSLATION_TASK_TIMEOUT", "id=\(turnID)")
            DiagnosticTrace.log("LIVE_TRACE", "translation timed out for \"\(text.prefix(60))\"")
            DiagnosticTrace.log("UPSTREAM_TRACE", "TRANSLATION_ERROR timeout")
            DiagnosticTrace.log("POST_STT_TRACE", "TRANSLATION_ERROR type=timeout")
            // A failed/timed-out translation leaves no trace in history or
            // on G2 — matches what a fully-synchronous "only append once
            // translation succeeds" pipeline would have done; the early
            // append (see prepareAndDispatch(final:)) exists for ordering
            // and staleness-tracking purposes, not to expose a permanently
            // blank translation to the user.
            agentContextStore.removeTurn(id: turnID)
            DiagnosticTrace.log("TURN_PIPELINE_RELEASED", "id=\(turnID) reason=translationTimeout")
            return
        } catch {
            // Deliberately still logged in full: a translation failure
            // has no other visibility anywhere in this class — `state`
            // stays `.listening` either way, since one failed phrase
            // shouldn't interrupt an otherwise-healthy session.
            DiagnosticTrace.log("LIVE_TRACE", "translation failed for \"\(text.prefix(60))\": \(error)")
            DiagnosticTrace.log("UPSTREAM_TRACE", "TRANSLATION_ERROR \(error)")
            DiagnosticTrace.log("POST_STT_TRACE", "TRANSLATION_ERROR type=\(type(of: error)) message=\(error)")
            agentContextStore.removeTurn(id: turnID)
            DiagnosticTrace.log("TURN_PIPELINE_RELEASED", "id=\(turnID) reason=translationFailed")
            return
        }

        let displayText = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayText.isEmpty else {
            agentContextStore.removeTurn(id: turnID)
            DiagnosticTrace.log("TURN_PIPELINE_RELEASED", "id=\(turnID) reason=emptyTranslation")
            return
        }

        lastTranslation = displayText
        DiagnosticTrace.log("REAL_TURN_TRACE", "TRANSLATION original=\"\(text.prefix(60))\" lang=\(languageCode) translation=\"\(displayText.prefix(60))\"")

        var translatedTurn = turn
        translatedTurn.ukrainianTranslation = displayText
        agentContextStore.updateTurn(translatedTurn)

        // "Glasses Chat" — persists this turn as a real Chat message,
        // entirely independent of G2 display: never awaited by this
        // pipeline, never allowed to delay or fail the display below, and
        // deliberately NOT tracked in `turnTasks` (so it isn't cancelled
        // by `stop()` either) — an already-translated turn should still
        // make it into history even if the user stops Live Translation a
        // moment later. `chatService`/`glassesChatProvider` being `nil`
        // (no production wiring, e.g. in a test) means this is simply
        // never attempted — not a failure.
        if let chatService, let glassesChatProvider {
            Task {
                do {
                    DiagnosticTrace.log("GLASSES_CHAT_TRACE", "APPEND_START turnID=\(turnID)")
                    let chat = try await glassesChatProvider.findOrCreateGlassesChat()
                    _ = try await chatService.appendMessage(
                        chatID: chat.id,
                        role: .user,
                        content: "\(text)\n→ \(displayText)"
                    )
                    DiagnosticTrace.log("GLASSES_CHAT_TRACE", "APPEND_DONE turnID=\(turnID) chatID=\(chat.id)")
                } catch {
                    DiagnosticTrace.log("GLASSES_CHAT_TRACE", "APPEND_FAILED turnID=\(turnID) error=\(error)")
                }
            }
        }

        // Newest-DISPLAYED-turn-wins: deliberately NOT a check against
        // `agentContextStore.session.latestTurn` ("has a newer turn been
        // *spoken*") — under real concurrency, several turns can all be
        // mid-translation at once (each appended the instant its final
        // transcript arrived, well before any of them finish translating),
        // so "a newer turn was spoken" is true almost immediately after
        // ANY rapid back-to-back utterances, even before that newer turn
        // has displayed anything itself. Gating on that would mean an
        // OLDER turn's perfectly legitimate translation gets silently
        // skipped just because a NEWER turn also happens to be in flight
        // — the user could end up seeing NEITHER, worse than the
        // original bug. The correct check is "has a newer turn *already
        // displayed*": `sequence` (assigned in true arrival order) is
        // compared against `highestDisplayedTurnSequence`, which only
        // advances once a turn actually reaches this point. A turn that
        // finishes translating before any newer one has displayed always
        // gets to display; a turn that finishes after a newer one already
        // has correctly defers to it. Claiming the slot synchronously
        // BEFORE awaiting the display call itself (not after it
        // succeeds) is what prevents two turns racing each other into
        // this block from both deciding they're the newest.
        guard sequence >= highestDisplayedTurnSequence else {
            DiagnosticTrace.log("REAL_TURN_TRACE", "DISPLAY_REQUEST skipped turnID=\(turnID) reason=staleTurn(newerTurnAlreadyDisplayed)")
            DiagnosticTrace.log("TURN_PIPELINE_RELEASED", "id=\(turnID) reason=staleBeforeDisplay")
            return
        }
        highestDisplayedTurnSequence = sequence

        // Suggested-reply generation starts now, concurrently with the G2
        // display call below — translation display must never wait on
        // replies, and replies don't need display to have finished, only
        // the translated turn itself. `sequence` is threaded through so
        // the reply stage's own staleness guard uses the exact same
        // "has anything newer already displayed" comparison as this one
        // (see `generateSuggestedReplies`'s doc comment for why that
        // consistency matters). Tracked in `turnTasks` so `stop()` can
        // cancel it.
        let replyTask = Task { [weak self] in
            guard let self else { return }
            await self.generateSuggestedReplies(for: translatedTurn, sequence: sequence, turnStartTime: turnStartTime)
        }
        turnTasks.append(replyTask)

        DiagnosticTrace.log("UPSTREAM_TRACE", "DISPLAY_CALLBACK text=\"\(displayText.prefix(60))\"")
        // Header-only pages — `translatedTurn.suggestedReplies` is still
        // empty at this point, so `GlassesPresentationLayer.pages(for:)`
        // naturally produces just the Source+Ukrainian header (see that
        // type's doc comment for the unified page format this now shares
        // with the reply-stage display call below).
        let translationPages = GlassesPresentationLayer.pages(for: translatedTurn)
        DiagnosticTrace.log("REAL_TURN_TRACE", "PAGES stage=translationOnly turnID=\(turnID) count=\(translationPages.count)")
        DiagnosticTrace.log("POST_STT_TRACE", "PRESENTATION_PAGES_CREATED count=\(translationPages.count)")
        DiagnosticTrace.log("DISPLAY_START", "id=\(turnID)")
        let displayCallStart = Date()
        DiagnosticTrace.log("LATENCY_TRACE", "DISPLAY_CALL_START id=\(turnID)")
        do {
            DiagnosticTrace.log("REAL_TURN_TRACE", "DISPLAY_REQUEST stage=translationOnly turnID=\(turnID)")
            DiagnosticTrace.log("POST_STT_TRACE", "DISPLAY_REQUEST turnID=\(turnID)")
            try await glassesTransport.displayPages(translationPages)
            currentTurnDisplayState = .translated(turnID: turnID)
            DiagnosticTrace.log("REAL_TURN_TRACE", "DISPLAY_DONE stage=translationOnly turnID=\(turnID)")
            DiagnosticTrace.log("DISPLAY_END", "id=\(turnID)")
            DiagnosticTrace.log("TURN_TRANSLATION_DISPLAYED", "turnID=\(turnID)")
            let now = Date()
            DiagnosticTrace.log("LATENCY_TRACE", "DISPLAY_CALL_END id=\(turnID)")
            DiagnosticTrace.log("LATENCY_TRACE", "TRANSLATION_DISPLAY_TS id=\(turnID) value=\(now.timeIntervalSince1970)")
            DiagnosticTrace.log(
                "LATENCY_TRACE",
                "TRANSLATION_TO_DISPLAY_MS id=\(turnID) value=\(Int(now.timeIntervalSince(translationStart) * 1000))"
            )
            DiagnosticTrace.log(
                "LATENCY_TRACE",
                "TRANSLATION_DISPLAY_LATENCY_MS id=\(turnID) value=\(Int(now.timeIntervalSince(displayCallStart) * 1000))"
            )
            DiagnosticTrace.log(
                "LATENCY_TRACE",
                "END_TO_END_TRANSLATION_MS id=\(turnID) value=\(Int(now.timeIntervalSince(turnStartTime) * 1000))"
            )
        } catch {
            // Same reasoning as the translation catch above — displaying
            // this has no other visibility.
            DiagnosticTrace.log("LIVE_TRACE", "displayPages failed for \"\(displayText.prefix(60))\": \(error)")
            DiagnosticTrace.log("REAL_TURN_TRACE", "DISPLAY_REQUEST failed stage=translationOnly turnID=\(turnID) error=\(error)")
        }
        DiagnosticTrace.log("TURN_PIPELINE_RELEASED", "id=\(turnID) reason=translationDisplayComplete")
    }

    /// Resolves the source language for one final transcript — the single
    /// choke point `prepareAndDispatch(final:)` calls instead of
    /// `translator.detectedLanguageCode(for:)` directly, so every mode
    /// (explicit and Auto, locked and unlocked) goes through one place.
    ///
    /// - Explicit (`.en`/`.de`/`.pl`): returns the selected code
    ///   immediately — no detection call at all, hence no detection
    ///   latency, and no chance of a short phrase being misdetected: the
    ///   user has told us what language this is.
    /// - Auto, not yet locked this session: runs real detection and, if it
    ///   confidently lands on one of the primary languages, locks the
    ///   session to it. A confident detection of some other language (or
    ///   Ukrainian) still translates that one turn normally but does not
    ///   start a lock — only detections of en/de/pl are treated as strong
    ///   enough evidence to anchor an entire session's language.
    /// - Auto, locked: text matching `CommonShortUtterances` (the same
    ///   curated "hello"/"yes"/"no"/"okay"-class table
    ///   `AppleLanguageTranslator` uses, measured against the real
    ///   recognizer to carry weak/misleading signal) always reuses the
    ///   lock, skipping detection entirely — both correctness (matches
    ///   the product requirement that these must never flip the
    ///   session's language) and latency (nothing to gain from running
    ///   detection on a word confirmed too weak to trust anyway).
    ///   Deliberately NOT a generic "is this text short" heuristic: e.g.
    ///   "Guten Tag" is only two words but a perfectly confident,
    ///   unambiguous detection (~0.97 confidence) that a locked session
    ///   legitimately needs to be able to switch to — only text that's
    ///   actually in the curated table counts as "ambiguous" here.
    ///
    ///   Anything else runs real detection, and — critically — a
    ///   *confident, non-nil* result is always trusted for what it
    ///   actually says, never silently forced back onto the lock: a
    ///   result of `nil` (undetectable) falls back to the lock (nothing
    ///   else to go on); a result equal to the lock is a no-op; a result
    ///   that's a *different primary* language (en/de/pl) switches the
    ///   session's lock; a result that's anything else — Ukrainian, or a
    ///   genuinely different language entirely — is returned as-is
    ///   without touching the lock at all. That last case is what keeps
    ///   Ukrainian speech correctly filtered downstream even mid-session.
    private func resolveSourceLanguage(for text: String) async -> String? {
        if let explicitCode = sourceLanguageMode.explicitLanguageCode {
            DiagnosticTrace.log("LANGUAGE_EXPLICIT_USED", "language=\(explicitCode) text=\"\(text.prefix(60))\"")
            return explicitCode
        }

        guard let locked = autoLockedLanguage else {
            let detected = await translator.detectedLanguageCode(for: text)
            DiagnosticTrace.log("LANGUAGE_AUTO_DETECTED", "detected=\(detected ?? "nil") text=\"\(text.prefix(60))\"")
            if let detected, Self.primarySourceLanguages.contains(detected) {
                autoLockedLanguage = detected
                DiagnosticTrace.log("LANGUAGE_AUTO_LOCKED", "language=\(detected) text=\"\(text.prefix(60))\"")
            }
            return detected
        }

        if CommonShortUtterances.isAmbiguous(text) {
            DiagnosticTrace.log("LANGUAGE_AUTO_REUSED", "language=\(locked) reason=ambiguousShortUtterance text=\"\(text.prefix(60))\"")
            return locked
        }

        let detected = await translator.detectedLanguageCode(for: text)
        DiagnosticTrace.log("LANGUAGE_AUTO_DETECTED", "detected=\(detected ?? "nil") text=\"\(text.prefix(60))\"")

        guard let detected else {
            DiagnosticTrace.log("LANGUAGE_AUTO_REUSED", "language=\(locked) reason=undetectable text=\"\(text.prefix(60))\"")
            return locked
        }
        if detected == locked {
            DiagnosticTrace.log("LANGUAGE_AUTO_REUSED", "language=\(locked) reason=sameLanguage text=\"\(text.prefix(60))\"")
            return locked
        }
        if Self.primarySourceLanguages.contains(detected) {
            autoLockedLanguage = detected
            DiagnosticTrace.log("LANGUAGE_AUTO_SWITCHED", "from=\(locked) to=\(detected) text=\"\(text.prefix(60))\"")
            return detected
        }
        // A confident detection of something other than a primary source
        // language (most commonly Ukrainian) — trust it for this turn,
        // leave the session's lock untouched.
        return detected
    }

    /// Best-effort — runs independently of every other turn's processing,
    /// concurrently with that same turn's own G2 display call (see
    /// `processTurn(_:text:languageCode:turnStartTime:)`). `turn` was
    /// already appended (and updated with its translation) in
    /// `agentContextStore` before this is ever called; a thrown error, a
    /// timeout, or cancellation here just leaves `suggestedReplies` empty,
    /// per the product requirement that a reply-generation failure must
    /// never hide the turn's own translation.
    ///
    /// `recentTurns` excludes `turn` by id (not by array position — this
    /// runs concurrently with later turns' own processing, so a later
    /// turn may already have been appended by the time this reads
    /// `agentContextStore.session.turns`) and is oldest-first, matching
    /// `SuggestedReplyContext`'s documented convention — the same ordering
    /// `agentContextStore.session.turns` is now guaranteed to hold at all
    /// times, since turns are appended in `prepareAndDispatch(final:)`,
    /// strictly in arrival order, independent of how fast any individual
    /// turn's translation completes.
    ///
    /// Automatically updates G2 with the suggested replies once generation
    /// completes — this used to require the user to swipe/press a button
    /// on the glasses to ever see them at all. `GlassesPresentationLayer
    /// .pages(for:)` (unified — see that type's doc comment) now produces
    /// one page per reply, each one carrying the SAME Source+Ukrainian
    /// header the initial translation-only display already showed, so
    /// this update adds a reply section below the header without ever
    /// making the translation itself disappear.
    ///
    /// Guards, right before updating G2's display, using the exact same
    /// sequence-based "has anything newer already displayed" comparison
    /// `processTurn(_:text:languageCode:turnStartTime:sequence:)` uses for
    /// the translation stage — deliberately NOT
    /// `agentContextStore.session.latestTurn?.id == turn.id` (what this
    /// used to compare against): that compares against "has a newer turn
    /// been *spoken*", which is too aggressive here for the same reason it
    /// was for translation display — a newer turn B can already be
    /// `latestTurn` while still mid-translation (or after B's own
    /// translation fails/times out and is removed), in which case turn A's
    /// perfectly good, already-generated replies would be silently
    /// discarded even though B never displayed anything at all, leaving
    /// the user looking at A's translation with no replies forever. The
    /// sequence comparison only defers to B once B has *actually
    /// displayed* something. The turn's own `suggestedReplies` are still
    /// recorded in `agentContextStore` either way (visible in Chat/
    /// history), only the G2 *display* update is skipped when stale.
    private func generateSuggestedReplies(for turn: ConversationTurn, sequence: Int, turnStartTime: Date) async {
        guard !Task.isCancelled else { return }
        let turnID = turn.id
        DiagnosticTrace.log("REPLIES_GENERATION_STARTED", "turnID=\(turnID)")

        DiagnosticTrace.log("POST_STT_TRACE", "SUGGESTED_REPLIES_START turnID=\(turnID)")
        DiagnosticTrace.log("SUGGESTED_REPLIES_START", "turnID=\(turnID)")
        DiagnosticTrace.log("REPLIES_TASK_START", "id=\(turnID)")
        let repliesStart = Date()
        DiagnosticTrace.log("LATENCY_TRACE", "REPLIES_START id=\(turnID)")
        DiagnosticTrace.log("LATENCY_TRACE", "REPLIES_REQUEST_START_TS id=\(turnID) value=\(repliesStart.timeIntervalSince1970)")
        // Bounded to the minimum history genuinely useful for reply
        // relevance (matches the backend's own MAX_RECENT_TURNS/
        // MAX_CONTEXT_ITEMS caps — see suggestedReplies/routes.js) —
        // trimmed further than "everything ever spoken" specifically to
        // keep the request small (and therefore fast): reply relevance
        // depends overwhelmingly on the last few turns, not the full
        // session history.
        let context = SuggestedReplyContext(
            recentTurns: Array(agentContextStore.session.turns.filter { $0.id != turnID }.suffix(6)),
            contextItems: agentContextStore.session.contextItems
        )
        let replies: [SuggestedReply]
        do {
            replies = try await generateRepliesWithTimeout(for: turn, context: context)
            let repliesDoneAt = Date()
            let repliesLatencyMs = Int(repliesDoneAt.timeIntervalSince(repliesStart) * 1000)
            DiagnosticTrace.log("LATENCY_TRACE", "REPLIES_END id=\(turnID)")
            DiagnosticTrace.log("LATENCY_TRACE", "REPLIES_RESPONSE_TS id=\(turnID) value=\(repliesDoneAt.timeIntervalSince1970)")
            DiagnosticTrace.log("LATENCY_TRACE", "REPLIES_LATENCY_MS id=\(turnID) value=\(repliesLatencyMs)")
            DiagnosticTrace.log("LATENCY_TRACE", "REPLIES_GENERATION_LATENCY_MS id=\(turnID) value=\(repliesLatencyMs)")
            DiagnosticTrace.log("REPLIES_TASK_END", "id=\(turnID)")
            DiagnosticTrace.log("REPLIES_GENERATION_FINISHED", "turnID=\(turnID) count=\(replies.count)")
        } catch is CancellationError {
            DiagnosticTrace.log("REPLIES_TASK_CANCELLED", "id=\(turnID)")
            DiagnosticTrace.log("REPLIES_GENERATION_FINISHED", "turnID=\(turnID) reason=cancelled")
            DiagnosticTrace.log("TURN_PIPELINE_RELEASED", "id=\(turnID) reason=repliesCancelled")
            return
        } catch is RepliesTimeoutError {
            DiagnosticTrace.log("REPLIES_TASK_TIMEOUT", "id=\(turnID)")
            DiagnosticTrace.log("LIVE_TRACE", "suggested-reply generation timed out for turnID=\(turnID)")
            DiagnosticTrace.log("REPLIES_GENERATION_FINISHED", "turnID=\(turnID) reason=timeout")
            DiagnosticTrace.log("TURN_PIPELINE_RELEASED", "id=\(turnID) reason=repliesTimeout")
            return
        } catch {
            DiagnosticTrace.log("LIVE_TRACE", "suggested-reply generation failed: \(error)")
            DiagnosticTrace.log("REAL_TURN_TRACE", "REPLIES failed turnID=\(turnID) error=\(error)")
            DiagnosticTrace.log("POST_STT_TRACE", "SUGGESTED_REPLIES_RESULT turnID=\(turnID) error type=\(type(of: error)) message=\(error)")
            DiagnosticTrace.log("SUGGESTED_REPLIES_RESULT", "turnID=\(turnID) error type=\(type(of: error)) message=\(error)")
            DiagnosticTrace.log("REPLIES_GENERATION_FINISHED", "turnID=\(turnID) reason=error")
            DiagnosticTrace.log("TURN_PIPELINE_RELEASED", "id=\(turnID) reason=repliesFailed")
            return
        }
        guard !Task.isCancelled else {
            DiagnosticTrace.log("REPLIES_TASK_CANCELLED", "id=\(turnID)")
            DiagnosticTrace.log("TURN_PIPELINE_RELEASED", "id=\(turnID) reason=repliesCancelledAfterCompletion")
            return
        }

        var updatedTurn = turn
        // Capped here regardless of what the generator returned — G2's
        // display constraint is enforced at this one choke point, not
        // trusted to every possible generator.
        updatedTurn.suggestedReplies = Array(replies.prefix(3))
        DiagnosticTrace.log("REAL_TURN_TRACE", "REPLIES turnID=\(turnID) rawCount=\(replies.count) cappedCount=\(updatedTurn.suggestedReplies.count)")
        DiagnosticTrace.log("POST_STT_TRACE", "SUGGESTED_REPLIES_RESULT turnID=\(turnID) count=\(updatedTurn.suggestedReplies.count)")
        DiagnosticTrace.log("SUGGESTED_REPLIES_RESULT", "id=\(turnID) count=\(updatedTurn.suggestedReplies.count)")
        agentContextStore.updateTurn(updatedTurn)

        guard sequence >= highestDisplayedTurnSequence else {
            DiagnosticTrace.log("REAL_TURN_TRACE", "DISPLAY_REQUEST skipped turnID=\(turnID) reason=staleTurn(newerTurnAlreadyDisplayed)")
            DiagnosticTrace.log("SUGGESTED_REPLIES_DISPLAY_ERROR", "turnID=\(turnID) reason=staleTurn(newerTurnAlreadyDisplayed) — a newer turn has already displayed, this update is intentionally discarded")
            DiagnosticTrace.log("TURN_PIPELINE_RELEASED", "id=\(turnID) reason=staleAfterReplies")
            return
        }
        // No replies to add — the translation already on screen is
        // already correct, so there's nothing to redisplay.
        guard !updatedTurn.suggestedReplies.isEmpty else {
            DiagnosticTrace.log("REAL_TURN_TRACE", "DISPLAY_REQUEST skipped turnID=\(turnID) reason=emptyReplies")
            DiagnosticTrace.log("SUGGESTED_REPLIES_EMPTY", "turnID=\(turnID)")
            DiagnosticTrace.log("TURN_PIPELINE_RELEASED", "id=\(turnID) reason=noRepliesToShow")
            return
        }
        let replyPages = GlassesPresentationLayer.pages(for: updatedTurn)
        DiagnosticTrace.log("REAL_TURN_TRACE", "PAGES stage=withReplies turnID=\(turnID) count=\(replyPages.count)")
        DiagnosticTrace.log("SUGGESTED_REPLIES_PAGES_CREATED", "id=\(turnID) count=\(replyPages.count)")
        let replyDisplayStart = Date()
        do {
            DiagnosticTrace.log("REAL_TURN_TRACE", "DISPLAY_REQUEST stage=withReplies turnID=\(turnID)")
            DiagnosticTrace.log("SUGGESTED_REPLIES_DISPLAY_REQUEST", "turnID=\(turnID)")
            DiagnosticTrace.log("SUGGESTED_REPLIES_AUTO_DISPLAY_START", "id=\(turnID)")
            try await glassesTransport.displayPages(replyPages)
            currentTurnDisplayState = .withReplies(turnID: turnID, replyCount: updatedTurn.suggestedReplies.count)
            let now = Date()
            DiagnosticTrace.log("REAL_TURN_TRACE", "DISPLAY_DONE stage=withReplies turnID=\(turnID)")
            DiagnosticTrace.log("SUGGESTED_REPLIES_DISPLAY_DONE", "turnID=\(turnID)")
            DiagnosticTrace.log("SUGGESTED_REPLIES_AUTO_DISPLAY_DONE", "id=\(turnID)")
            DiagnosticTrace.log("REPLIES_DISPLAYED", "turnID=\(turnID) replyCount=\(updatedTurn.suggestedReplies.count)")
            DiagnosticTrace.log("LATENCY_TRACE", "REPLIES_DISPLAY_TS id=\(turnID) value=\(now.timeIntervalSince1970)")
            DiagnosticTrace.log(
                "LATENCY_TRACE",
                "REPLIES_DISPLAY_LATENCY_MS id=\(turnID) value=\(Int(now.timeIntervalSince(replyDisplayStart) * 1000))"
            )
            DiagnosticTrace.log(
                "LATENCY_TRACE",
                "TOTAL_REPLIES_LATENCY_MS id=\(turnID) value=\(Int(now.timeIntervalSince(turnStartTime) * 1000))"
            )
        } catch {
            DiagnosticTrace.log("LIVE_TRACE", "displayPages (suggested replies) failed: \(error)")
            DiagnosticTrace.log("REAL_TURN_TRACE", "DISPLAY_REQUEST failed stage=withReplies turnID=\(turnID) error=\(error)")
            DiagnosticTrace.log("SUGGESTED_REPLIES_DISPLAY_ERROR", "turnID=\(turnID) error=\(error)")
        }
        DiagnosticTrace.log("TURN_PIPELINE_RELEASED", "id=\(turnID) reason=repliesComplete")
    }

    /// Bounds `translator.translateToUkrainian(_:from:)` for THIS caller —
    /// see this class's own doc comment (and `AppleLanguageTranslator`'s
    /// own, separate, deeper fix) for why a caller-side timeout alone
    /// isn't sufficient for `AppleLanguageTranslator` specifically, but is
    /// still the right general-purpose safety net here regardless of which
    /// `LanguageTranslating` implementation is wired in: a translation
    /// call that hangs (for whatever reason) degrades to "no translation
    /// for this turn" instead of leaving this turn's pipeline task running
    /// forever.
    private func translateWithTimeout(_ text: String, from languageCode: String) async throws -> String {
        // Captured by value (both `Sendable`) rather than `self`, so the
        // child tasks below have no actor-isolation ambiguity at all.
        let translator = self.translator
        let timeout = self.translationTimeout
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await translator.translateToUkrainian(text, from: languageCode) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TranslationTimeoutError()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Same pattern as `translateWithTimeout(_:from:)`, for reply
    /// generation — see `repliesTimeout`'s own doc comment.
    private func generateRepliesWithTimeout(for turn: ConversationTurn, context: SuggestedReplyContext) async throws -> [SuggestedReply] {
        let generator = self.replyGenerator
        let timeout = self.repliesTimeout
        return try await withThrowingTaskGroup(of: [SuggestedReply].self) { group in
            group.addTask { try await generator.generateReplies(for: turn, context: context) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RepliesTimeoutError()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    struct TranslationTimeoutError: Error, CustomStringConvertible, Equatable {
        var description: String { "translation timed out" }
    }

    struct RepliesTimeoutError: Error, CustomStringConvertible, Equatable {
        var description: String { "suggested-reply generation timed out" }
    }
}
