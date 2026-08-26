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
///
/// ## Streaming translation (major performance pass)
///
/// Waiting for a full utterance to finalize (silence-debounced, ~1.3s of
/// dead air on the STT side alone) before translation even started made
/// "perceptually immediate" translation structurally impossible — the
/// product goal is translated text appearing while the speaker is still
/// talking, refined once the final arrives, not created by it.
/// `ContinuousTranscribing` now yields `.partial(_:)` updates for the
/// utterance currently being spoken as well as the terminal `.final(_:)`
/// — `handlePartial(_:)` reacts to those: it updates
/// `currentPartialTranscript` immediately (free — local state, no I/O),
/// then debounces (`partialDebounceInterval`, 150ms) before actually
/// translating and redisplaying, so a burst of rapidly-growing partials
/// collapses into one G2/network round trip instead of one per partial.
/// `.final(_:)` always wins immediately — any in-flight partial debounce
/// for the same utterance is cancelled the moment a final for it arrives
/// (see `consume(_:)`), and `prepareAndDispatch(final:)` reuses that
/// utterance's already-claimed display-ordering slot
/// (`utteranceSequence`) so the final's own display participates in
/// EXACTLY the same newest-wins ordering a partial's would have — a
/// stale, late-settling partial for an old utterance can never overwrite
/// either a newer utterance's partial OR that same utterance's own final.
/// Partials are never persisted: no `ConversationTurn` is created, and
/// nothing reaches Glasses Chat, until `.final(_:)` arrives — see
/// `prepareAndDispatch(final:)`, unchanged in that respect.
///
/// Priority order, enforced structurally, not by convention: (1) keep
/// listening — `handlePartial(_:)` is synchronous and `consume(_:)`'s
/// loop never awaits translation/display/replies for ANY utterance,
/// partial or final; (2) show translation immediately — the debounced
/// partial path exists for exactly this; (3) persist the final turn —
/// `processTurn(...)`'s translation/display/Chat-append steps, unchanged;
/// (4) generate replies asynchronously — `generateSuggestedReplies(...)`
/// only ever starts after (3), in its own untracked-by-priority `Task`,
/// and can never delay, block, or take priority over (1)-(3).
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
        /// A partial (still-growing) transcript/translation for the
        /// utterance currently being spoken is on screen — see the
        /// "Streaming translation" section of this class's doc comment.
        /// Never backed by a persisted `ConversationTurn`.
        case streaming(utteranceID: UUID)
        case translated(turnID: ConversationTurn.ID)
        case withReplies(turnID: ConversationTurn.ID, replyCount: Int)
    }

    /// What G2's display is currently doing, relative to the live
    /// conversation — replaces a bare `followLive: Bool` because two very
    /// different things used to collapse into one "not following live"
    /// state. Deliberately SEMANTIC, not positional: each case carries
    /// the actual conversation identity it refers to, never a raw G2
    /// page index.
    ///
    /// - `.browsingReplies(turnID:replyIndex:)`: the user is cycling
    ///   reply pages for the CURRENT/latest turn — temporary, assistive
    ///   UI, not a deliberate look back through history. New speech must
    ///   reclaim this automatically (see
    ///   `reclaimLiveDisplayIfBrowsingReplies(reason:)`) — no double-tap
    ///   should be required.
    /// - `.browsingHistory(anchorTurnID:)`: the user swiped past the
    ///   replies into the one bounded look-back window (the previous
    ///   turn's context, keyed by that turn's own id — see
    ///   `renderHistoryViewport(anchorTurnID:)`). This IS a deliberate
    ///   look at history; new speech must NOT yank the display back — it
    ///   keeps capturing/persisting/showing a "↓ LIVE" indicator until
    ///   the user returns manually.
    ///
    /// ## The race this eliminates
    ///
    /// A prior revision inferred which of the two a raw `pageChanged
    /// (index:)` event meant by comparing it against
    /// `lastDisplayedHistoryPageIndex` — bookkeeping captured at the
    /// moment a page set was last SENT. Under rapid speech, a turn's own
    /// reply-generation stage can lose the "newest turn already
    /// displayed" staleness race (by design — see `processTurn`'s doc
    /// comment) and simply never run, so the trailing history page for
    /// THAT specific send could be silently missing even though the
    /// underlying conversation history (`agentContextStore.session
    /// .turns`) already had everything needed to render it. A user
    /// swiping toward history at exactly that instant would be
    /// misclassified as `.browsingReplies`, purely because of what had
    /// or hadn't finished RENDERING — not because of anything about
    /// their actual intent.
    ///
    /// The fix: `applyPageIndexNavigation(_:)` never trusts "what got
    /// sent." It reclassifies fresh, every time, directly from
    /// `agentContextStore.session` — the logical, always-consistent
    /// source of truth — at the exact moment the navigation event
    /// arrives, and `renderHistoryViewport(anchorTurnID:)` then renders
    /// the correct content on demand, regardless of whatever
    /// (potentially stale/incomplete) content happened to already be on
    /// that G2 page slot. Page generation follows `DisplayMode`; it is
    /// never the other way around.
    enum DisplayMode: Sendable, Equatable {
        case followLive
        case browsingHistory(anchorTurnID: ConversationTurn.ID)
        case browsingReplies(turnID: ConversationTurn.ID, replyIndex: Int)
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
    /// Required streaming-translation state (major performance pass) —
    /// `finalTranscript`/`finalTranslation` are simply the authoritative
    /// names for `lastRecognizedPhrase`/`lastTranslation` above (kept as
    /// computed aliases rather than a second copy of the same data, so
    /// there's no way for the two to diverge).
    var finalTranscript: String? { lastRecognizedPhrase }
    var finalTranslation: String? { lastTranslation }
    /// The utterance currently being spoken's still-growing recognized
    /// text — `nil` whenever no utterance is in progress (between
    /// utterances, or right after one finalizes). Updated on every
    /// `.partial(_:)` update; never itself debounced (cheap, local, no
    /// I/O) — only the G2 display/translation call that *reacts* to it is
    /// debounced (see `handlePartial(_:)`).
    private(set) var currentPartialTranscript: String?
    /// The current best-effort Ukrainian translation of
    /// `currentPartialTranscript`, once the debounced translate call for
    /// it resolves — `nil` until then, or whenever no language is known
    /// yet for this utterance (Auto mode, not yet locked; see
    /// `resolveLanguageForNewUtterance()`). Never persisted anywhere;
    /// wiped the moment the utterance's own final transcript arrives.
    private(set) var currentPartialTranslation: String?
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
    /// Which physical microphone Live Translation captures from — see
    /// `AudioSource`'s own doc comment. `private(set)`, changed only
    /// through `setAudioSource(_:)`. Loaded from `defaults` at
    /// construction, same pattern as `sourceLanguageMode`.
    private(set) var audioSource: AudioSource
    /// See `ConversationMode`'s own doc comment. `private(set)`, changed
    /// only through `setConversationMode(_:)`. Loaded from `defaults` at
    /// construction, same pattern as `sourceLanguageMode`/`audioSource`.
    private(set) var conversationMode: ConversationMode
    /// The user's STT provider preference — see `TranscriptionProviderMode`'s
    /// own doc comment. `private(set)`, changed only through
    /// `setTranscriptionProviderMode(_:)`. Loaded from `defaults` at
    /// construction, same pattern as `sourceLanguageMode`/`audioSource`/
    /// `conversationMode`. Read live by `TranscriptionProviderRouter` (via
    /// the `mode:` closure `EvenAIApp` wires it up with) every time a
    /// session starts — this property is the single source of truth the
    /// router consults, so persisting it here (not duplicating it inside
    /// the router) keeps exactly one place able to change it.
    private(set) var transcriptionProviderMode: TranscriptionProviderMode
    /// Which STT provider actually transcribed the current/most recent
    /// session — `nil` before the first `start()`. Read by the Live
    /// Translation UI for the "clear provider labeling" requirement (on-
    /// device vs. cloud). Set once `start()`'s `transcriber
    /// .startTranscribing(pcmUpdates:)` call returns successfully, by
    /// reading `(transcriber as? TranscriptionProviderRouter)?.lastActiveProvider`
    /// — `nil` for any transcriber that isn't a `TranscriptionProviderRouter`
    /// (e.g. a test's own fake), which simply means this label is unknown,
    /// not that anything is wrong.
    private(set) var lastActiveTranscriptionProvider: ActiveTranscriptionProvider?
    /// Conversation Mode: see `DisplayMode`'s own doc comment.
    /// Listening/translation/history recording are NEVER gated on this —
    /// only the act of actually pushing a new display update to G2 is
    /// (see `displayPartial`/`processTurn`/`generateSuggestedReplies`'s
    /// own "while not following live, skip the send" guards). Reset to
    /// `.followLive` in `start()` — a new session always begins on the
    /// live page. Updated from `GlassesNavigationEvent`s via
    /// `navigationObserverTask`, and automatically reclaimed from
    /// `.browsingReplies` (never `.browsingHistory`) the moment new
    /// speech starts — see `reclaimLiveDisplayIfBrowsingReplies(reason:)`.
    private(set) var displayMode: DisplayMode = .followLive
    /// Back-compat convenience some call sites/tests read directly —
    /// `true` iff `displayMode == .followLive`. Both `.browsingHistory`
    /// and `.browsingReplies` mean "don't push a new display update right
    /// now," which is all the three-way `displayPartial`/`processTurn`/
    /// `generateSuggestedReplies` guards ever needed to know.
    var followLive: Bool { displayMode == .followLive }
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
    /// "Glasses Chat" — persists each finalized, translated turn as a real,
    /// local-first message via `GlassesChatProvider.appendTurn(originalText:translation:)`
    /// (see that type's own doc comment: SwiftData-backed, no network call,
    /// never blocked by Railway being offline). Optional, defaulted to
    /// `nil`, so every existing construction call site (tests included)
    /// keeps compiling unchanged, matching `agentContextStore`/
    /// `replyGenerator`'s own pattern; `EvenAIApp` passes the real instance
    /// explicitly. `nil` means "don't persist to Chat" — never attempted,
    /// never logged as a failure, since there's nothing wrong with a
    /// caller (e.g. a test) that simply isn't exercising this feature.
    private let glassesChatProvider: GlassesChatProvider?

    private var consumeTask: Task<Void, Never>?
    private var connectionObserverTask: Task<Void, Never>?
    /// Subscribes to `glassesTransport.navigationEvents()` — drives
    /// `followLive`. Started in `start()`, cancelled in `stop()`: G2
    /// navigation is only meaningful while a session is actually live.
    private var navigationObserverTask: Task<Void, Never>?
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
    /// Identifies the utterance currently in progress (partials received,
    /// no final yet) — `nil` between utterances. Not a `ConversationTurn`
    /// id and never becomes one; purely a correlation token so a
    /// debounced partial-translation response can tell "am I still
    /// talking about the utterance that scheduled me, or has it already
    /// finalized / been superseded" — see `handlePartial(_:)`/
    /// `settlePartial(...)`.
    private var utteranceID: UUID?
    /// The global display-ordering slot claimed for the utterance
    /// currently in progress — assigned from the SAME `turnSequenceCounter`
    /// finals use, the moment the utterance's first partial arrives (not
    /// when it finalizes). This is what lets a newer utterance's partial
    /// correctly pre-empt an older utterance's still-in-flight FINAL
    /// display (and vice versa never happening): both partials and finals
    /// share one ordering, checked against the same
    /// `highestDisplayedTurnSequence`. Reused, not reassigned, when this
    /// same utterance's final is dispatched in `prepareAndDispatch(final:)`.
    private var utteranceSequence: Int?
    /// The language resolved for the utterance currently in progress —
    /// see `resolveLanguageForNewUtterance()`. `nil` means either no
    /// utterance is in progress, or Auto mode hasn't locked onto a
    /// language yet (in which case partials for this utterance show
    /// source text only, no translation, until the final runs full
    /// detection).
    private var utteranceLanguageCode: String?
    /// Decides WHEN a growing partial is worth actually translating — see
    /// `AdaptiveStreamingTranslationBuffer`'s own doc comment for the full
    /// design (punctuation / pause / max-latency-budget chunk boundaries)
    /// and the "word-by-word" bug it replaces. Reset (via
    /// `beginUtterance`/`endUtterance`) in lockstep with `utteranceID`.
    private var streamingBuffer = AdaptiveStreamingTranslationBuffer()
    /// Runs for the lifetime of one utterance — periodically calls
    /// `streamingBuffer.tick(now:)` so a genuine pause or the max-latency
    /// budget can fire a chunk even when no NEW partial has arrived (see
    /// `runUtteranceTicker()`). Cancelled the moment the utterance's
    /// final arrives, or on `stop()`.
    private var utteranceTickTask: Task<Void, Never>?
    /// The currently in-flight streaming-chunk translate call, if any —
    /// cancelled (never left to keep running unobserved) the instant a
    /// NEWER chunk becomes ready, so at most one streaming translation
    /// request is ever outstanding per utterance ("backpressure favors
    /// recency, never queue obsolete requests" — see
    /// `settleStreamingChunk(...)`'s doc comment).
    private var streamingTranslateTask: Task<Void, Never>?
    /// The revision (from `AdaptiveStreamingTranslationBuffer.Decision
    /// .ready(text:revision:)`) most recently dispatched for translation
    /// — the authoritative staleness key `settleStreamingChunk(...)`
    /// checks, both before and after its network round trip. NOT
    /// redundant with `streamingTranslateTask?.cancel()`: cancelling a
    /// `Task` only marks it cancelled — it does not retroactively un-
    /// happen a `Task.sleep`/network call that had already finished
    /// (e.g. a translator's own artificial delay elapsing) microseconds
    /// before the cancellation lands. A chunk's result is only ever
    /// trusted if its own `revision` still equals this value when
    /// checked, closing that exact race.
    private var latestDispatchedStreamingRevision = 0
    /// How often `utteranceTickTask` re-evaluates `streamingBuffer` while
    /// an utterance is in progress and no new partial has arrived — fine-
    /// grained enough to catch a stability/max-latency boundary promptly
    /// (worst case, `tickInterval` of extra latency) without doing
    /// meaningful work more often than that; each tick that doesn't
    /// result in `.ready` is a few cheap, in-memory comparisons, no I/O.
    private static let tickInterval: Duration = .milliseconds(100)
    /// The user's explicit on/off intent, distinct from `state` — guards
    /// `observeConnection()` so a disconnect/reconnect cycle before the
    /// user has ever started Live Translation doesn't do anything.
    private var isEnabledIntent = false
    /// G2's most recently observed connection state — updated by
    /// `observeConnection()`'s subscription UNCONDITIONALLY (started at
    /// construction time, in `init`, independent of `isEnabledIntent`),
    /// so it's always current, never a stale snapshot, when `start()`
    /// reads it for `LIVE_START_G2_STATE`.
    private var lastKnownGlassesConnectionState: GlassesTransportState = .disconnected
    /// Session-lifetime reliability counters — see
    /// `ConversationSessionMetrics`'s own doc comment for why this is a
    /// plain, directly-testable value type rather than loose private
    /// vars: `DiagnosticTrace` only ever renders a snapshot of it
    /// (`CONVERSATION_SESSION_METRICS`), tests read it directly via
    /// `currentSessionMetrics()`. Reset in `start()`.
    private(set) var sessionMetrics = ConversationSessionMetrics()
    /// Wall-clock time `start()` last began listening — `duration=` in
    /// `CONVERSATION_SESSION_METRICS`. `nil` before the first `start()`.
    private var sessionStartedAt: Date?

    // MARK: - Audio-path reliability instrumentation (Section 10/17 audit)
    //
    // The SDK hands over raw PCM `Data` with no per-chunk sequence number
    // or embedded capture timestamp (confirmed by reading
    // `MentraGlassesTransport`'s `didReceiveMicPcm` delegate callback —
    // there is nothing else in the payload to key off of). That makes an
    // EXACT dropped-chunk count structurally impossible to derive from
    // this client alone; what `recordAudioChunk(_:)` writes into
    // `sessionMetrics` is a SUSPECTED estimate, derived from client-
    // observed wall-clock arrival gaps against a self-adapting expected-
    // interval baseline. This is deliberately reported as "suspected,"
    // never presented as exact. The two fields below are pure timing
    // SCRATCH STATE used to derive those counters — not reportable
    // metrics themselves, which is why they live here rather than in
    // `ConversationSessionMetrics`.
    private var audioFirstByteAt: Date?
    private var lastAudioChunkAt: Date?
    /// Exponential moving average of "normal" (non-anomalous) inter-
    /// chunk gaps, in milliseconds — the adaptive baseline
    /// `recordAudioChunk(_:)` compares each new gap against. `nil` until
    /// the second chunk of the session arrives (nothing to compare the
    /// first gap to).
    private var audioExpectedIntervalMs: Double?

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
    private static let audioSourceDefaultsKey = "com.evenai.liveTranslation.audioSource"
    private static let conversationModeDefaultsKey = "com.evenai.liveTranslation.conversationMode"
    private static let transcriptionProviderModeDefaultsKey = "com.evenai.liveTranslation.transcriptionProviderMode"

    init(
        glassesTransport: GlassesTransport,
        transcriber: ContinuousTranscribing,
        translator: LanguageTranslating,
        agentContextStore: AgentContextStore = AgentContextStore(),
        replyGenerator: SuggestedReplyGenerating = NoOpSuggestedReplyGenerator(),
        translationTimeout: Duration = .seconds(8),
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
        if let saved = defaults.string(forKey: Self.audioSourceDefaultsKey),
           let savedSource = AudioSource(rawValue: saved) {
            self.audioSource = savedSource
        } else {
            self.audioSource = .g2Mic
        }
        if let saved = defaults.string(forKey: Self.conversationModeDefaultsKey),
           let savedMode = ConversationMode(rawValue: saved) {
            self.conversationMode = savedMode
        } else {
            self.conversationMode = .standard
        }
        if let saved = defaults.string(forKey: Self.transcriptionProviderModeDefaultsKey),
           let savedMode = TranscriptionProviderMode(rawValue: saved) {
            self.transcriptionProviderMode = savedMode
        } else {
            self.transcriptionProviderMode = .auto
        }
        observeConnection()
    }

    /// The one way `conversationMode` ever changes — persists
    /// immediately (survives app relaunch). Takes effect on the NEXT
    /// reply (mid-turn is not retroactively affected — a reply already
    /// displayed doesn't un-display itself), which is an acceptable,
    /// simple semantic for a preset switch a user makes deliberately
    /// between conversations, not mid-sentence.
    func setConversationMode(_ mode: ConversationMode) {
        guard mode != conversationMode else { return }
        conversationMode = mode
        defaults.set(mode.rawValue, forKey: Self.conversationModeDefaultsKey)
        DiagnosticTrace.log("CONVERSATION_MODE_SELECTED", "mode=\(mode.rawValue)")
    }

    /// The one way `audioSource` ever changes — persists immediately
    /// (survives app relaunch) and, if a session is already listening,
    /// pushes the new preference to the transport right away so it takes
    /// effect on the mic that's already active (no restart required —
    /// matches the explicit-language-selection fix's own "must propagate
    /// immediately" requirement).
    func setAudioSource(_ source: AudioSource) {
        guard source != audioSource else { return }
        audioSource = source
        defaults.set(source.rawValue, forKey: Self.audioSourceDefaultsKey)
        // `MentraGlassesTransport.setPreferredAudioSource(_:)` itself
        // applies this live if the mic is already on — safe/no-op
        // otherwise (see its own doc comment).
        Task { [glassesTransport] in
            await glassesTransport.setPreferredAudioSource(source)
        }
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
        // Confirms the SERVICE actually received and applied the change —
        // see `resolvedSourceLanguageCode`'s doc comment for why this,
        // not `sourceLanguageMode` alone, is what actually mattered for
        // the physical "select EN/DE/PL but the app keeps asking again"
        // bug: `sourceLanguageMode` itself was ALWAYS updated correctly
        // and instantly by this method — the break was one level deeper,
        // in the real on-device `TranslationSession`'s own `source`
        // configuration never being told about this change at all (see
        // `RootView.syncTranslationConfiguration()`).
        DiagnosticTrace.log("LANGUAGE_MODE_SERVICE_UPDATED", "mode=\(mode.rawValue)")
        // Same "must propagate immediately, no restart required" fix as
        // the real `TranslationSession`'s own reconfiguration
        // (`RootView.syncTranslationConfiguration()`) — if `transcriber`
        // is a `TranscriptionProviderRouter`, an already-listening
        // on-device session's `SFSpeechRecognizer` locale switches right
        // now, not on the next `start()`. A no-op for any other
        // `ContinuousTranscribing` (cloud-only sessions have no per-call
        // locale to reconfigure; a test's own fake simply doesn't
        // implement this).
        (transcriber as? TranscriptionProviderRouter)?.applyCurrentLocale()
    }

    /// The one way `transcriptionProviderMode` ever changes — persists
    /// immediately (survives app relaunch). Takes effect on the NEXT
    /// `start()` — switching provider mid-session isn't attempted (unlike
    /// `sourceLanguageMode`'s live locale switch above): tearing down a
    /// live cloud WebSocket or on-device recognizer and rebuilding the
    /// other provider mid-utterance would risk losing in-flight audio, and
    /// a user changing this setting is a deliberate, infrequent choice —
    /// not something that needs to interrupt an active conversation to
    /// honor immediately. See `TranscriptionProviderMode`'s own doc
    /// comment for what each case means and `TranscriptionProviderRouter`
    /// for how `EvenAIApp` wires this property's live value in.
    func setTranscriptionProviderMode(_ mode: TranscriptionProviderMode) {
        guard mode != transcriptionProviderMode else { return }
        transcriptionProviderMode = mode
        defaults.set(mode.rawValue, forKey: Self.transcriptionProviderModeDefaultsKey)
        DiagnosticTrace.log("STT_PROVIDER_MODE_SELECTED", "mode=\(mode.rawValue)")
    }

    /// THE single authoritative resolved source language for the current
    /// moment — explicit mode returns its fixed code immediately; Auto
    /// mode returns whatever it's currently locked to (`nil` before the
    /// first lock this session). Priority is structural, not a runtime
    /// check: explicit mode's own state (`sourceLanguageMode
    /// .explicitLanguageCode`) is consulted FIRST and, if present,
    /// `autoLockedLanguage` is never even read — an explicit selection
    /// can never be overridden by a stale Auto lock from before the
    /// switch (also cleared outright by `setSourceLanguageMode(_:)`).
    ///
    /// This is what `RootView` observes to keep the real
    /// `TranslationSession`'s own `Configuration.source` in sync — see
    /// that type's doc comment for the actual root cause this exists to
    /// fix: `AppleLanguageTranslator.translateToUkrainian(_:from:)`'s
    /// `sourceLanguageCode` parameter has no effect on Apple's
    /// `Translation` framework at all (there is no per-call source
    /// override in that framework's API — confirmed against the
    /// `Translation.framework` interface: `TranslationSession.Request`
    /// carries only `sourceText`/`clientIdentifier`, and `translate(_:)`
    /// always uses the session's own fixed `Configuration.source`/
    /// `sourceLanguage`). Every one of THIS class's own language-
    /// resolution call sites (`resolveLanguageForNewUtterance()`,
    /// `resolveSourceLanguage(for:)`) already correctly skip detection in
    /// explicit mode — the missing piece was that the REAL underlying
    /// `TranslationSession` was still configured with `source: nil`
    /// (auto-detect) regardless, so Apple's own framework kept running
    /// its own, entirely separate internal detection on every call and
    /// could still fail/prompt ("Не вдалось визначити мову...") no
    /// matter what the user picked in this app's own UI. Without a
    /// concrete `source` on the session itself, there was no way to make
    /// explicit mode "never run detection" at the actual translation-API
    /// level — only at this class's own (already-correct, but
    /// insufficient on its own) decision layer.
    var resolvedSourceLanguageCode: String? {
        sourceLanguageMode.explicitLanguageCode ?? autoLockedLanguage
    }

    /// Enables the G2 microphone and starts the continuous transcribe →
    /// detect → translate → display loop. Safe to call again while already
    /// `.listening` (no-op).
    func start() async {
        guard state != .listening else { return }
        DiagnosticTrace.log("LIVE_START_REQUESTED", "audioSource=\(audioSource.rawValue) conversationMode=\(conversationMode.rawValue)")
        isEnabledIntent = true
        lastRecognizedPhrase = nil
        // "Reset the Auto language lock when a new Live Translation
        // session begins" — a lock from a previous session (possibly a
        // different speaker/language entirely) must never carry over.
        autoLockedLanguage = nil
        turnSequenceCounter = 0
        highestDisplayedTurnSequence = 0
        currentTurnDisplayState = .none
        displayMode = .followLive
        sessionMetrics = ConversationSessionMetrics()
        sessionStartedAt = Date()
        audioFirstByteAt = nil
        lastAudioChunkAt = nil
        audioExpectedIntervalMs = nil
        resetUtteranceState()
        observeNavigation()

        // `ready` mirrors `connected` here — this protocol exposes
        // connection state as a stream of `GlassesTransportState`, with
        // no separate, richer "ready" concept beneath it; reporting a
        // fabricated distinction would be worse than reporting the one
        // real signal available twice, honestly labeled.
        let isG2Connected = lastKnownGlassesConnectionState == .connected
        DiagnosticTrace.log("LIVE_START_G2_STATE", "connected=\(isG2Connected) ready=\(isG2Connected) rawState=\(lastKnownGlassesConnectionState)")

        DiagnosticTrace.log("LIVE_START_AUDIO_SOURCE", "source=\(audioSource.rawValue)")
        await glassesTransport.setPreferredAudioSource(audioSource)
        DiagnosticTrace.log("LIVE_START_MIC_ENABLE_BEGIN", "audioSource=\(audioSource.rawValue)")
        do {
            try await glassesTransport.setMicrophoneEnabled(true)
            DiagnosticTrace.log("LIVE_START_MIC_ENABLE_OK", "audioSource=\(audioSource.rawValue)")
        } catch {
            DiagnosticTrace.log("LIVE_START_MIC_ENABLE_FAILED", "audioSource=\(audioSource.rawValue) errorType=\(type(of: error)) errorMessage=\(error)")
            // The audio-source SELECTION (not the underlying transport)
            // is what determines whether this is genuinely a G2 problem
            // or a phone-microphone one — `setMicrophoneEnabled`'s own
            // failure doesn't distinguish the two on its own.
            let classified: LiveTranslationStartError = audioSource == .g2Mic
                ? .glassesUnavailable(underlying: "\(error)")
                : .microphoneUnavailable(underlying: "\(error)")
            DiagnosticTrace.log("LIVE_START_FAILED", "stage=\(classified.stage) errorType=\(type(of: error)) errorMessage=\(error)")
            state = .error(classified.userFacingMessage)
            await terminateSession(reason: "startFailed(\(classified.stage))", fatal: true, source: "start", error: error)
            return
        }
        do {
            let pcmUpdates = await glassesTransport.microphonePCMUpdates()
            let updates = try await transcriber.startTranscribing(pcmUpdates: instrumentedPCMStream(pcmUpdates))
            state = .listening
            lastActiveTranscriptionProvider = (transcriber as? TranscriptionProviderRouter)?.lastActiveProvider
            DiagnosticTrace.log(
                "LIVE_START_SESSION_STARTED",
                "audioSource=\(audioSource.rawValue) sttProvider=\(lastActiveTranscriptionProvider?.rawValue ?? "unknown")"
            )
            consumeTask = Task { [weak self] in
                await self?.consume(updates)
            }
        } catch {
            // TEMPORARY — Milestone 8b physical-device diagnosis. Remove
            // once root-caused. See DiagnosticTrace.swift.
            DiagnosticTrace.log("8B_TRACE", "STOP reason=transcriber.startTranscribing() threw synchronously: \(error)")
            let classified = LiveTranslationStartError.classifyTranscriberStartFailure(error)
            DiagnosticTrace.log("LIVE_START_FAILED", "stage=\(classified.stage) errorType=\(type(of: error)) errorMessage=\(error)")
            state = .error(classified.userFacingMessage)
            await terminateSession(reason: "startFailed(\(classified.stage))", fatal: true, source: "start", error: error)
        }
    }

    /// Stops transcription and disables the G2 microphone — the ONE
    /// explicit, user/UI-initiated way to end a Live Translation session.
    /// Safe to call from any state, including if `start()` never
    /// succeeded. Never sets `.error` — an explicit stop is not a
    /// failure. See `terminateSession(reason:fatal:source:error:)` for
    /// the shared teardown every ending path (this one included) funnels
    /// through exactly once.
    func stop() async {
        DiagnosticTrace.log("SESSION_STOP_REQUESTED", "source=explicit")
        await terminateSession(reason: "userRequested", fatal: false, source: "explicitStop", error: nil)
    }

    /// The ONE teardown path every way a Live Translation session can
    /// end funnels through — explicit user stop, G2 disconnect, a
    /// start()-time failure, or an unrecoverable STT stream failure —
    /// so `LIVE_SESSION_TERMINATED` is always logged exactly once, with
    /// the one true reason, never duplicated and never silently skipped.
    ///
    /// `fatal` is purely a LOGGING/diagnostic distinction here — it does
    /// NOT gate whether teardown happens (teardown is unconditional and
    /// identical either way). The caller is responsible for setting
    /// `state = .error(...)` BEFORE calling this, for any path where
    /// that's appropriate; this function's own `if state == .listening
    /// { state = .idle }` is a no-op once `state` is already `.error`,
    /// exactly mirroring the previous single `stop()`'s own established
    /// "only clears a .listening state" comment.
    ///
    /// Deliberately never called for a translation/display/reply/
    /// provisional-partial failure — those are isolated per-turn
    /// failures with their own local catch blocks (see `processTurn`/
    /// `generateSuggestedReplies`/`settleStreamingChunk`/`displayPartial`),
    /// none of which touch `state` or call this function; only a
    /// genuinely fatal audio/STT/session-level failure reaches here.
    private func terminateSession(reason: String, fatal: Bool, source: String, error: Error?) async {
        let wasListening = state == .listening
        let reconnects = await transcriber.reconnectCount
        DiagnosticTrace.log(
            "LIVE_SESSION_TERMINATED",
            "reason=\(reason) "
                + "fatal=\(fatal) "
                + "source=\(source) "
                + "errorType=\(error.map { String(describing: type(of: $0)) } ?? "nil") "
                + "errorMessage=\(error.map { "\($0)" } ?? "nil") "
                + "sttConnected=\(wasListening) "
                + "audioSource=\(audioSource.rawValue) "
                + "conversationMode=\(conversationMode.rawValue) "
                + "lastTurnID=\(agentContextStore.session.latestTurn?.id.uuidString ?? "nil") "
                + "finalTranscriptCount=\(sessionMetrics.finalTranscriptCount) "
                + "sttReconnectCount=\(reconnects)"
        )
        await logSessionMetrics()
        isEnabledIntent = false
        DiagnosticTrace.log("SESSION_CANCEL_REQUESTED", "reason=\(reason)")
        consumeTask?.cancel()
        consumeTask = nil
        navigationObserverTask?.cancel()
        navigationObserverTask = nil
        // Cancel every still-running per-turn pipeline/reply task — a
        // completion after this point must never call `displayPages`
        // again (the transport itself would likely reject it once
        // disconnected/mic-disabled anyway, but this avoids ever
        // attempting it, and avoids leaving orphaned tasks running).
        turnTasks.forEach { $0.cancel() }
        turnTasks.removeAll()
        resetUtteranceState()
        await transcriber.stopTranscribing()
        try? await glassesTransport.setMicrophoneEnabled(false)
        // Only clears a `.listening` state — an `.error` set immediately
        // before this call (a fatal-path caller) must stay visible to
        // the user, not be silently overwritten back to `.idle`.
        if state == .listening {
            state = .idle
        }
    }

    /// One concise, diagnostic-only summary line at the end of a session
    /// — Section 3's "session health summary" ask. A no-op (logs nothing)
    /// if the session never actually reached `.listening`, so a `stop()`
    /// called on an already-idle/never-started service doesn't spam a
    /// meaningless all-zero line. `finalTurnsPersisted` reuses
    /// `agentContextStore.session.turns.count` directly rather than a
    /// separate counter: a turn only ever stays in `session.turns` if its
    /// translation actually succeeded (a failed/timed-out/cancelled
    /// translation removes its draft turn — see `processTurn`'s catch
    /// blocks), so the current count already IS "how many turns were
    /// actually persisted this session."
    private func logSessionMetrics() async {
        guard state == .listening else { return }
        let duration = sessionStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let metrics = await currentSessionMetrics()
        DiagnosticTrace.log(
            "CONVERSATION_SESSION_METRICS",
            "duration=\(String(format: "%.1f", duration))s "
                + "audioChunks=\(metrics.audioChunkCount) "
                + "audioBytes=\(metrics.audioByteCount) "
                + "audioGapCount=\(metrics.audioGapCount) "
                + "maxAudioGapMs=\(metrics.audioMaxGapMs) "
                + "audioSuspectedDroppedChunks=\(metrics.audioSuspectedDroppedChunks) "
                + "sttReconnects=\(metrics.sttReconnectCount) "
                + "finalTranscripts=\(metrics.finalTranscriptCount) "
                + "finalTurnsPersisted=\(metrics.finalTurnsPersistedCount) "
                + "translationFailures=\(metrics.translationFailureCount) "
                + "displayFailures=\(metrics.displayFailureCount) "
                + "avgFirstUsefulTranslationMs=\(metrics.avgFirstUsefulTranslationMs) "
                + "medianFirstUsefulTranslationMs=\(metrics.medianFirstUsefulTranslationMs) "
                + "sampleCount=\(metrics.firstUsefulTranslationSamplesMs.count) "
                + "mode=\(sourceLanguageMode.rawValue) "
                + "audioSource=\(audioSource.rawValue)"
        )
    }

    /// A fresh snapshot of this session's reliability counters, right
    /// now — Section 6 testability: tests call this directly rather than
    /// needing to intercept `DiagnosticTrace`'s console output. Fills in
    /// the two fields `sessionMetrics` alone can't hold on its own
    /// (`sttReconnectCount`, an `async` property on the transcriber;
    /// `finalTurnsPersistedCount`, read live from `agentContextStore` —
    /// see `ConversationSessionMetrics`'s own doc comments for why).
    func currentSessionMetrics() async -> ConversationSessionMetrics {
        var snapshot = sessionMetrics
        snapshot.sttReconnectCount = await transcriber.reconnectCount
        snapshot.finalTurnsPersistedCount = agentContextStore.session.turns.count
        return snapshot
    }

    /// Wraps the raw PCM stream from `glassesTransport
    /// .microphonePCMUpdates()` with a passive side-channel that counts
    /// and times chunks as they pass through, purely for
    /// `CONVERSATION_SESSION_METRICS`/audio-reliability diagnostics
    /// (Section 10/17's audio-path audit) — never drops, reorders,
    /// delays, or otherwise touches a single byte on the way to
    /// `transcriber.startTranscribing(pcmUpdates:)`. Never logs raw audio
    /// content, only counts/sizes/timings.
    private func instrumentedPCMStream(_ source: AsyncStream<Data>) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let forwardingTask = Task { [weak self] in
                for await chunk in source {
                    await self?.recordAudioChunk(chunk)
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in forwardingTask.cancel() }
        }
    }

    /// One PCM chunk's worth of audio-reliability bookkeeping — see the
    /// "Audio-path reliability instrumentation" properties' own doc
    /// comments for the exact fields this updates, and for why a dropped/
    /// suspected chunk count can only ever be an estimate given what the
    /// SDK actually provides. The expected-interval baseline only folds
    /// in "normal" (non-anomalous) gaps, specifically so a real dropout
    /// can never drag the baseline up and hide itself from detection.
    private func recordAudioChunk(_ data: Data) {
        let now = Date()
        sessionMetrics.audioChunkCount += 1
        sessionMetrics.audioByteCount += data.count
        if audioFirstByteAt == nil {
            audioFirstByteAt = now
            DiagnosticTrace.log("AUDIO_FIRST_BYTE_TS", "value=\(now.timeIntervalSince1970)")
        }
        defer { lastAudioChunkAt = now }
        guard let last = lastAudioChunkAt else { return }
        let gapMs = now.timeIntervalSince(last) * 1000
        guard let expected = audioExpectedIntervalMs else {
            audioExpectedIntervalMs = gapMs
            return
        }
        let anomalyThresholdMs = max(expected * 3, 150)
        guard gapMs > anomalyThresholdMs else {
            audioExpectedIntervalMs = expected * 0.9 + gapMs * 0.1
            return
        }
        sessionMetrics.audioGapCount += 1
        sessionMetrics.audioMaxGapMs = max(sessionMetrics.audioMaxGapMs, Int(gapMs))
        // How many expected-interval-sized chunks COULD have fit in this
        // gap beyond the one chunk we actually got — a suspected-drop
        // estimate, not an exact count (see this section's own doc
        // comment).
        let suspected = max(0, Int((gapMs / expected).rounded(.down)) - 1)
        sessionMetrics.audioSuspectedDroppedChunks += suspected
        DiagnosticTrace.log(
            "AUDIO_GAP_DETECTED",
            "gapMs=\(Int(gapMs)) expectedIntervalMs=\(Int(expected)) suspectedDroppedChunks=\(suspected)"
        )
    }

    /// New speech (whether it first arrives as a growing partial, or —
    /// for a transcriber that emits no partials — directly as a final)
    /// must immediately reclaim the live display from reply-browsing:
    /// replies are temporary, assistive UI for the turn that just
    /// finished, not a deliberate look back through history, so they
    /// must never be allowed to block the NEXT turn from showing up. A
    /// deliberate look back through OLDER finalized turns
    /// (`.browsingHistory`) is left completely alone — see `DisplayMode`'s
    /// own doc comment for why the two need different treatment. A no-op
    /// (and safe to call from multiple call sites) when not currently
    /// `.browsingReplies`.
    private func reclaimLiveDisplayIfBrowsingReplies(reason: String) {
        guard case .browsingReplies = displayMode else { return }
        displayMode = .followLive
        DiagnosticTrace.log("DISPLAY_MODE_CHANGED", "mode=followLive reason=\(reason)")
    }

    private func observeConnection() {
        connectionObserverTask = Task { [weak self] in
            guard let self else { return }
            let updates = await self.glassesTransport.connectionStateUpdates()
            for await connectionState in updates {
                // Tracked UNCONDITIONALLY — not gated on `isEnabledIntent`
                // — so `LIVE_START_G2_STATE` always reflects G2's true,
                // current connection state at the moment of a `start()`
                // attempt, never a stale snapshot left over from before
                // this subscription's very first update, or from a prior
                // session's last-known state.
                self.lastKnownGlassesConnectionState = connectionState
                guard self.isEnabledIntent else { continue }
                switch connectionState {
                case .disconnected, .failed(_):
                    await self.terminateSession(reason: "glassesDisconnected", fatal: true, source: "connectionObserver", error: nil)
                case .connected, .connecting, .scanning:
                    break
                }
            }
        }
    }

    /// Conversation Mode: tracks G2 touchpad navigation to drive
    /// `followLive` — see `GlassesNavigationEvent`/`followLive`'s own doc
    /// comments. Started fresh in `start()` (matching `observeConnection()`'s
    /// own per-session-start pattern would be redundant re-subscribing on
    /// every `start()` call across the object's lifetime, but that's
    /// harmless — `navigationEvents()` is a plain broadcast stream, not a
    /// single-shot resource), cancelled in `stop()`.
    private func observeNavigation() {
        navigationObserverTask = Task { [weak self] in
            guard let self else { return }
            let events = await self.glassesTransport.navigationEvents()
            for await event in events {
                await self.handleNavigation(event)
            }
        }
    }

    private func handleNavigation(_ event: GlassesNavigationEvent) async {
        switch event {
        case .pageChanged(let index):
            await applyPageIndexNavigation(index)
        case .returnToLiveRequested:
            await returnToLive(reason: "returnToLiveRequested")
        }
    }

    /// Translates a raw G2 page index into a semantic `DisplayMode`
    /// transition — see `DisplayMode`'s own doc comment for the exact
    /// rapid-speech race this design eliminates versus a prior revision
    /// that inferred intent from what had actually been RENDERED.
    ///
    /// Page 0 is always `.followLive`, by convention — every page set
    /// this class ever sends puts live content there. Any other index is
    /// classified using ONLY `agentContextStore.session` — the logical,
    /// always-consistent source of truth — read FRESH at the exact
    /// moment this runs, never a cached record of what a past
    /// `displayPages(...)` call happened to include: the live/anchor
    /// turn is `agentContextStore.session.latestTurn`; if `index` falls
    /// within that turn's CURRENT reply count (which only ever grows,
    /// never shrinks, within one turn's lifecycle — capped at 3, see
    /// `generateSuggestedReplies`), it's a reply page for that specific
    /// turn+index; anything beyond that is history, anchored to the turn
    /// immediately before it. Entering `.browsingHistory` immediately
    /// renders the correct viewport on demand
    /// (`renderHistoryViewport(anchorTurnID:)`) rather than trusting
    /// whatever (possibly stale or entirely missing) content that G2
    /// page slot already happened to hold.
    private func applyPageIndexNavigation(_ index: Int) async {
        guard index != 0 else {
            guard displayMode != .followLive else { return }
            displayMode = .followLive
            DiagnosticTrace.log("DISPLAY_MODE_CHANGED", "mode=followLive reason=pageChanged index=0")
            await redisplayLiveContent()
            return
        }
        guard let liveTurn = agentContextStore.session.latestTurn else { return }
        // `GlassesPresentationLayer.pages(for:)` produces exactly one
        // page PER reply — page `k` is the header plus
        // `suggestedReplies[k]` (page 0 always shows `suggestedReplies[0]`
        // merged with the live header when a reply exists, which is
        // still `.followLive` by the page-0 convention above — it only
        // becomes a genuinely browsable, DISTINCT `.browsingReplies` page
        // starting at index 1, showing `suggestedReplies[index]`). So an
        // index strictly less than the current reply count is a reply
        // page; anything at or beyond it is history.
        let replyCount = liveTurn.suggestedReplies.count
        if index < replyCount {
            let newMode = DisplayMode.browsingReplies(turnID: liveTurn.id, replyIndex: index)
            guard newMode != displayMode else { return }
            displayMode = newMode
            DiagnosticTrace.log(
                "DISPLAY_MODE_CHANGED",
                "mode=browsingReplies turnID=\(liveTurn.id) replyIndex=\(index) reason=pageChanged index=\(index)"
            )
            // No re-render: G2 already navigated itself to a reply page
            // that was genuinely sent — this only updates what THIS
            // class understands that page to mean.
            return
        }
        guard let anchor = previousTurn(before: liveTurn.id) else {
            // Nothing exists before the live turn yet — there is no
            // history to browse to. Hardware shouldn't be able to
            // produce this index in that case (nothing was ever sent
            // there to swipe onto), but staying put is the safe,
            // defensive response if it somehow does.
            return
        }
        let newMode = DisplayMode.browsingHistory(anchorTurnID: anchor.id)
        if newMode != displayMode {
            displayMode = newMode
            DiagnosticTrace.log(
                "DISPLAY_MODE_CHANGED",
                "mode=browsingHistory anchorTurnID=\(anchor.id) reason=pageChanged index=\(index)"
            )
        }
        // Always re-render on entry/re-entry, even if `newMode ==
        // displayMode` already (e.g. two swipes landing on different
        // raw indices that both resolve to the same anchor) — this is
        // exactly what "do not wait for a special history page to be
        // appended; render the best available historical viewport"
        // means: never trust what's already on screen, always push the
        // logically-correct content the instant history is requested.
        await renderHistoryViewport(anchorTurnID: anchor.id)
    }

    /// Renders a single dedicated page for `anchorTurnID`'s content,
    /// straight from `agentContextStore.session` — the on-demand
    /// counterpart to `redisplayLiveContent()`, used the moment
    /// `.browsingHistory` is entered/re-entered. Deliberately
    /// independent of whatever page set the LIVE turn most recently
    /// sent: this always looks up `anchorTurnID` fresh and builds its
    /// page directly, so it can never be blocked by — or racing against
    /// — the live turn's own translation/reply pipeline. A no-op if the
    /// anchor turn has no usable translation yet (matches
    /// `GlassesPresentationLayer`'s existing "no translation, no page"
    /// rule elsewhere).
    private func renderHistoryViewport(anchorTurnID: ConversationTurn.ID) async {
        guard let anchor = agentContextStore.session.turns.first(where: { $0.id == anchorTurnID }) else { return }
        guard let page = GlassesPresentationLayer.historyViewportPage(for: anchor) else { return }
        do {
            try await glassesTransport.displayPages([page])
            DiagnosticTrace.log("REAL_TURN_TRACE", "HISTORY_VIEWPORT_RENDERED anchorTurnID=\(anchorTurnID)")
        } catch {
            sessionMetrics.displayFailureCount += 1
            DiagnosticTrace.log("LIVE_TRACE", "renderHistoryViewport failed: \(error)")
        }
    }

    /// Jumps G2's display straight back to the live turn and re-enables
    /// `followLive` — the shared implementation behind both G2's own
    /// double-tap gesture (`GlassesNavigationEvent.returnToLiveRequested`)
    /// and an equivalent "↓ LIVE" control the iPhone-side UI can offer
    /// (`LiveTranslationView`). Safe to call even when already following
    /// live (redisplays the freshest content regardless — a harmless,
    /// idempotent refresh).
    func returnToLive() async {
        await returnToLive(reason: "manualReturnToLive")
    }

    private func returnToLive(reason: String) async {
        DiagnosticTrace.log("DISPLAY_MODE_CHANGED", "mode=followLive reason=\(reason)")
        displayMode = .followLive
        await redisplayLiveContent()
    }

    /// Rebuilds and resends the freshest available content for G2's live
    /// page — called whenever `followLive` transitions back to `true`
    /// (the user returned to the live page, by swiping back to it or by
    /// double-tapping), since any turns that arrived while they were away
    /// were recorded in history but deliberately never pushed to the
    /// display (see the "while not following live, skip the send" guards
    /// in `displayPartial`/`processTurn`/`generateSuggestedReplies`). A
    /// no-op if nothing has ever been translated yet this session.
    private func redisplayLiveContent() async {
        guard let latestTurn = agentContextStore.session.latestTurn else { return }
        let previousTurn = agentContextStore.session.turns.dropLast().last
        let pages = GlassesPresentationLayer.conversationPages(for: latestTurn, previousTurn: previousTurn)
        guard !pages.isEmpty else { return }
        do {
            try await glassesTransport.displayPages(pages)
            DiagnosticTrace.log("REAL_TURN_TRACE", "REDISPLAY_LIVE_CONTENT turnID=\(latestTurn.id) pageCount=\(pages.count)")
        } catch {
            sessionMetrics.displayFailureCount += 1
            DiagnosticTrace.log("LIVE_TRACE", "redisplayLiveContent failed: \(error)")
        }
    }

    /// The turn immediately preceding `turnID` in true chronological
    /// (spoken/appended) order, if any — the "one bounded page of look-
    /// back context" `GlassesPresentationLayer.conversationPages(for:previousTurn:)`
    /// uses. Looked up by id/index rather than assuming `turnID` is
    /// `session.turns.last` — under real concurrency a newer turn may
    /// already have been appended by the time this runs.
    private func previousTurn(before turnID: ConversationTurn.ID) -> ConversationTurn? {
        let turns = agentContextStore.session.turns
        guard let index = turns.firstIndex(where: { $0.id == turnID }), index > 0 else { return nil }
        return turns[index - 1]
    }

    private func consume(_ updates: AsyncThrowingStream<TranscriptionUpdate, Error>) async {
        // Tracks whether at least one update was ever genuinely received
        // this session — the closest thing to "confirmed handshake" this
        // class can observe (see the catch block below): `state` itself
        // becomes `.listening` optimistically, the moment `transcriber
        // .startTranscribing(pcmUpdates:)` RETURNS (before the real STT
        // handshake is necessarily confirmed — `OpenAIRealtimeTranscriber
        // .startTranscribing`/`URLSessionRealtimeTranscriptionSocket
        // .connect()` return as soon as the connection task is resumed,
        // not once it's confirmed live), so a handshake failure that
        // happens moments later, asynchronously, would otherwise surface
        // ONLY as the generic "stopped unexpectedly" message — exactly
        // the same misleading-classification bug `LiveTranslationStartError`
        // exists to fix, just arriving a few hundred milliseconds later
        // than the synchronous `start()`-time failures it already
        // covers. If the very first thing this loop ever sees is a
        // thrown error — no update, partial or final, ever arrived —
        // that's still fundamentally a STARTUP failure from the user's
        // perspective, and gets the same truthful classification.
        var hasReceivedAnyUpdateThisSession = false
        do {
            for try await update in updates {
                hasReceivedAnyUpdateThisSession = true
                // Proves the loop is still pulling from `updates` — this is
                // the ONE place in the whole pipeline where "continuous
                // listening" is either true or it isn't: if this line
                // never logs again after replies for a previous turn
                // displayed, the STT stream itself stalled (or its
                // upstream producer did), not anything in this class's own
                // per-turn task graph — see this class's own doc comment
                // for why neither `handlePartial(_:)` nor
                // `prepareAndDispatch`/`processTurn` can be the cause of
                // that (nothing here awaits any of them).
                DiagnosticTrace.log("NEXT_TRANSCRIPT_ACCEPTED", "sessionState=\(state)")
                switch update {
                case .partial(let text):
                    // Synchronous/cheap — schedules a debounced task and
                    // returns immediately; never blocks this loop from
                    // reading the next update. See `handlePartial(_:)`.
                    handlePartial(text)
                case .final(let text):
                    // TEMPORARY — upstream-path diagnostic. Remove once
                    // root-caused. See DiagnosticTrace.swift.
                    DiagnosticTrace.log("UPSTREAM_TRACE", "TRANSCRIPT_RECEIVED text=\"\(text.prefix(60))\"")
                    // A final always supersedes any still-pending
                    // streaming (partial) work for the same utterance —
                    // translation has absolute priority, and a partial's
                    // job is done the moment the authoritative text
                    // exists. `prepareAndDispatch(final:)` calls
                    // `resetUtteranceState()` immediately, which cancels
                    // both the ticker and any in-flight streaming
                    // translate call.
                    await prepareAndDispatch(final: text)
                }
            }
            // The stream ended without throwing. Ordinarily this means
            // `terminateSession(...)` already asked
            // `transcriber.stopTranscribing()` to end it cleanly
            // (`isEnabledIntent` already `false` by the time that
            // happens — see `terminateSession`'s own ordering) — the
            // fully expected, benign case. `isEnabledIntent` still being
            // `true` here means the stream ended entirely on its own,
            // with no error AND no stop having been requested — worth
            // making visible (a `ContinuousTranscribing` implementation
            // is never supposed to do this unprompted), but deliberately
            // NOT routed through `terminateSession(...)` again: the
            // stream is already gone, so there is nothing left to cancel
            // or tear down — a second full teardown here would just
            // double-call `stopTranscribing()`/`setMicrophoneEnabled
            // (false)` for no reason. A plain, clean transition to
            // `.idle` (identical to the expected case) is the correct,
            // non-duplicated response; the trace line is what makes the
            // anomaly visible for diagnosis.
            if Task.isCancelled {
                DiagnosticTrace.log("TRANSCRIBER_TASK_CANCELLED", "state=\(state) isEnabledIntent=\(isEnabledIntent)")
            } else {
                DiagnosticTrace.log("TRANSCRIBER_STREAM_ENDED", "state=\(state) isEnabledIntent=\(isEnabledIntent)")
            }
            if state == .listening {
                if isEnabledIntent {
                    DiagnosticTrace.log("UNEXPECTED_SESSION_END", "reason=streamEndedWithoutErrorOrStopRequest")
                }
                state = .idle
            }
        } catch {
            // This is the exact catch that used to unconditionally
            // produce the physical-device symptom ("Live Translation
            // stopped unexpectedly. Try again.") on the FIRST STT
            // hiccup that couldn't be resolved within
            // `OpenAIRealtimeTranscriber`'s (now bounded-with-backoff,
            // previously single-attempt) reconnect budget — by the time
            // this actually throws, that budget is already exhausted,
            // so this really is a fatal, unrecoverable STT failure, not
            // a single blip.
            DiagnosticTrace.log("TRANSCRIBER_STREAM_ERROR", "error=\(error) everReceivedAnUpdate=\(hasReceivedAnyUpdateThisSession)")
            if hasReceivedAnyUpdateThisSession {
                DiagnosticTrace.log("8B_TRACE", "STOP reason=finals stream threw, surfacing as 'stopped unexpectedly': \(error)")
                state = .error("Live Translation stopped unexpectedly. Try again.")
                await terminateSession(reason: "sttStreamFailed", fatal: true, source: "consume", error: error)
            } else {
                // The handshake was never genuinely confirmed — this is a
                // STARTUP failure that simply surfaced a little later
                // than `start()`'s own synchronous catch blocks, so it
                // gets the exact same truthful classification they do,
                // not the generic "stopped unexpectedly" message.
                let classified = LiveTranslationStartError.classifyTranscriberStartFailure(error)
                DiagnosticTrace.log("LIVE_START_FAILED", "stage=\(classified.stage) errorType=\(type(of: error)) errorMessage=\(error)")
                state = .error(classified.userFacingMessage)
                await terminateSession(reason: "startFailed(\(classified.stage),handshakeNeverConfirmed)", fatal: true, source: "consume", error: error)
            }
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

        // The final always ends whatever utterance was streaming partials
        // — reuse its already-claimed display-ordering slot (if any) so
        // the eventual translation display participates in the SAME
        // newest-wins ordering as any partial that already showed on
        // screen (see `utteranceSequence`'s doc comment), then clear all
        // partial-streaming state so the NEXT utterance starts fresh.
        let reusedSequence = utteranceSequence
        resetUtteranceState()

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
        // Belt-and-suspenders for a transcriber that emits `.final(_:)`
        // with no preceding `.partial(_:)` (`handlePartial(_:)`'s own
        // hook covers the normal streaming case) — genuinely new,
        // non-duplicate speech must reclaim the live display from reply-
        // browsing here too.
        reclaimLiveDisplayIfBrowsingReplies(reason: "newSpeechFinal")

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
        sessionMetrics.finalTranscriptCount += 1
        DiagnosticTrace.log("FINAL_TRANSCRIPT_COUNT", "value=\(sessionMetrics.finalTranscriptCount)")
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

        let sequence: Int
        if let reusedSequence {
            sequence = reusedSequence
        } else {
            // No partial ever streamed for this utterance (a transcriber
            // that doesn't emit partials, or the very first final of a
            // session) — claim a fresh slot exactly as before.
            turnSequenceCounter += 1
            sequence = turnSequenceCounter
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.processTurn(turn, text: text, languageCode: languageCode, turnStartTime: turnStartTime, sequence: sequence)
        }
        turnTasks.append(task)
    }

    /// Clears every piece of state associated with the utterance currently
    /// streaming partials — called both when that utterance's own final
    /// arrives (it's done, the next one starts fresh) and on `stop()`
    /// (nothing should survive a stopped session). See `utteranceID`'s and
    /// `partialDebounceTask`'s own doc comments for why each field exists.
    private func resetUtteranceState() {
        utteranceTickTask?.cancel()
        utteranceTickTask = nil
        streamingTranslateTask?.cancel()
        streamingTranslateTask = nil
        latestDispatchedStreamingRevision = 0
        streamingBuffer.endUtterance()
        utteranceID = nil
        utteranceSequence = nil
        utteranceLanguageCode = nil
        currentPartialTranscript = nil
        currentPartialTranslation = nil
    }

    /// Language for a JUST-STARTED utterance's partials — deliberately
    /// never runs real detection (`translator.detectedLanguageCode`):
    /// a growing partial's first few words carry too little/unreliable
    /// signal, and detection itself has real latency that would undercut
    /// the entire point of streaming translation. Explicit modes resolve
    /// instantly, as always; Auto mode reuses whatever this session has
    /// already locked onto (`nil` if not locked yet — that utterance's
    /// partials simply show source text only, with no translation, until
    /// its OWN final runs the full `resolveSourceLanguage(for:)` path,
    /// which can lock the session for every utterance after it).
    private func resolveLanguageForNewUtterance() -> String? {
        if let explicitCode = sourceLanguageMode.explicitLanguageCode {
            DiagnosticTrace.log("PARTIAL_LANGUAGE_RESOLVED", "mode=explicit source=\(explicitCode)")
            return explicitCode
        }
        DiagnosticTrace.log("PARTIAL_LANGUAGE_RESOLVED", "mode=auto source=\(autoLockedLanguage ?? "nil")")
        return autoLockedLanguage
    }

    /// Handles one `.partial(_:)` update — see this class's own doc
    /// comment ("Streaming translation") and `AdaptiveStreamingTranslationBuffer`'s
    /// own doc comment for the full design. Entirely synchronous and
    /// cheap: updates `currentPartialTranscript` immediately (local
    /// state, no I/O), feeds the text into `streamingBuffer`, and only if
    /// THAT decides a chunk is ready right now does any translate/display
    /// work get dispatched — most partials, especially during fast
    /// continuous speech, simply update local state and return. Never
    /// awaited by `consume(_:)`'s loop.
    private func handlePartial(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != currentPartialTranscript else { return }

        let now = Date()
        if utteranceID == nil {
            // New speech starting: if the user was browsing reply pages
            // for the previous turn, reclaim the live display right now
            // — see this method's own reasoning in
            // `reclaimLiveDisplayIfBrowsingReplies(reason:)`'s doc
            // comment. A deliberate look back through history
            // (`.browsingHistory`) is untouched.
            reclaimLiveDisplayIfBrowsingReplies(reason: "newSpeechPartial")
            let newUtteranceID = UUID()
            utteranceID = newUtteranceID
            sessionMetrics.utteranceCount += 1
            DiagnosticTrace.log("UTTERANCE_COUNT", "value=\(sessionMetrics.utteranceCount)")
            turnSequenceCounter += 1
            utteranceSequence = turnSequenceCounter
            utteranceLanguageCode = resolveLanguageForNewUtterance()
            currentPartialTranslation = nil
            streamingBuffer.beginUtterance(id: newUtteranceID, now: now)
            utteranceTickTask = Task { [weak self] in
                await self?.runUtteranceTicker(utteranceID: newUtteranceID)
            }
            DiagnosticTrace.log(
                "UTTERANCE_STARTED",
                "id=\(newUtteranceID.uuidString) language=\(utteranceLanguageCode ?? "unresolved")"
            )
        }
        currentPartialTranscript = text
        DiagnosticTrace.log("PARTIAL_TRANSCRIPT_RECEIVED", "text=\"\(text.prefix(60))\"")
        DiagnosticTrace.log("STREAM_BUFFER_UPDATE", "text=\"\(text.prefix(60))\" length=\(text.count)")

        let decision = streamingBuffer.receivePartial(text, now: now)
        handleStreamingDecision(decision, arrivedAt: now)
    }

    /// Runs for the lifetime of one utterance, re-evaluating
    /// `streamingBuffer` every `tickInterval` — the only way a genuine
    /// pause or the max-latency budget can fire a chunk when no NEW
    /// partial has arrived (see `AdaptiveStreamingTranslationBuffer
    /// .tick(now:)`'s doc comment). Exits the moment `utteranceID`
    /// no longer matches (the utterance finalized or was superseded) —
    /// also cancelled directly by `resetUtteranceState()`, this exit
    /// condition is the belt-and-suspenders backstop.
    private func runUtteranceTicker(utteranceID: UUID) async {
        while !Task.isCancelled, self.utteranceID == utteranceID {
            try? await Task.sleep(for: Self.tickInterval)
            guard !Task.isCancelled, self.utteranceID == utteranceID else { return }
            let decision = streamingBuffer.tick(now: Date())
            handleStreamingDecision(decision, arrivedAt: Date())
        }
    }

    /// The one place a `.ready` decision from `streamingBuffer` turns
    /// into actual work — synchronous itself (dispatches a `Task`, never
    /// awaits translation here), so it's safe to call from both
    /// `handlePartial(_:)` (immediate reaction to a new partial) and
    /// `runUtteranceTicker()` (periodic reaction to elapsed time) without
    /// either one blocking. `.wait` is a no-op — most calls, especially
    /// during fast continuous speech, land here.
    private func handleStreamingDecision(_ decision: AdaptiveStreamingTranslationBuffer.Decision, arrivedAt: Date) {
        guard case .ready(let text, let revision) = decision else { return }
        guard let utteranceID, let utteranceSequence else { return }
        DiagnosticTrace.log("STREAM_CHUNK_READY", "utteranceID=\(utteranceID.uuidString) revision=\(revision) text=\"\(text.prefix(60))\"")

        // Backpressure favors recency: at most one streaming translate
        // call outstanding per utterance. A newer chunk becoming ready
        // cancels whatever the previous chunk's call was doing — it is
        // never left to keep running unobserved, and it is never queued
        // behind this one either.
        streamingTranslateTask?.cancel()
        latestDispatchedStreamingRevision = revision
        let languageCode = utteranceLanguageCode
        streamingTranslateTask = Task { [weak self] in
            await self?.settleStreamingChunk(
                text: text,
                languageCode: languageCode,
                utteranceID: utteranceID,
                utteranceSequence: utteranceSequence,
                revision: revision,
                chunkReadyAt: arrivedAt
            )
        }
    }

    /// Translates one ready chunk and updates G2 in place — but only
    /// after confirming, BOTH before and after the network round trip,
    /// that nothing newer (a later chunk of the SAME utterance, or that
    /// utterance's own final) has already superseded it. `revision`
    /// (from `AdaptiveStreamingTranslationBuffer`) compared against
    /// `latestDispatchedStreamingRevision` is the authoritative staleness
    /// key within one utterance; `utteranceID` is the authoritative key
    /// across utterances — together they're what
    /// `STREAM_RESULT_DISCARDED_STALE` traces. This is deliberately NOT
    /// `Task.isCancelled` alone: cancelling `streamingTranslateTask` only
    /// marks it cancelled going forward — it can't retroactively un-
    /// happen a translate call whose own delay/network round trip had
    /// already finished microseconds before the newer chunk's
    /// cancellation landed (confirmed by a real test failure during
    /// development: an older, artificially-slow chunk's result still
    /// arrived and was accepted, because the newer chunk hadn't been
    /// dispatched — and hadn't cancelled anything — yet). The revision
    /// comparison has no such timing gap: it's a plain, synchronous
    /// equality check against whatever the LATEST dispatch actually was,
    /// at the exact moment each guard runs.
    private func settleStreamingChunk(
        text: String,
        languageCode: String?,
        utteranceID: UUID,
        utteranceSequence: Int,
        revision: Int,
        chunkReadyAt: Date
    ) async {
        guard self.utteranceID == utteranceID, revision == latestDispatchedStreamingRevision else {
            DiagnosticTrace.log("STREAM_RESULT_DISCARDED_STALE", "reason=supersededBeforeStart utteranceID=\(utteranceID.uuidString) revision=\(revision)")
            return
        }

        guard let languageCode, languageCode != Self.ukrainianLanguageCode else {
            // No language known yet for this utterance (Auto, unlocked)
            // or Ukrainian speech — show the source chunk alone; there is
            // nothing to translate.
            await displayPartial(source: text, translation: nil, utteranceID: utteranceID, utteranceSequence: utteranceSequence)
            return
        }

        let requestStart = Date()
        DiagnosticTrace.log(
            "STREAM_TRANSLATION_REQUEST",
            "utteranceID=\(utteranceID.uuidString) revision=\(revision) language=\(languageCode) text=\"\(text.prefix(60))\""
        )
        DiagnosticTrace.log(
            "LATENCY_TRACE",
            "PARTIAL_TO_TRANSLATION_REQUEST_MS value=\(Int(requestStart.timeIntervalSince(chunkReadyAt) * 1000))"
        )
        var translated: String?
        do {
            translated = try await translateWithTimeout(text, from: languageCode)
            DiagnosticTrace.log(
                "STREAM_TRANSLATION_RESULT",
                "utteranceID=\(utteranceID.uuidString) revision=\(revision) text=\"\(translated?.prefix(60) ?? "nil")\""
            )
        } catch {
            // A failed/timed-out chunk translation is not worth
            // surfacing as an error — this chunk simply shows source-
            // only; the next chunk (or the eventual, always-retried
            // final) tries again. A streaming chunk never blocks on or
            // retries its own failure.
            translated = nil
            DiagnosticTrace.log("LIVE_TRACE", "streaming chunk translation failed/timed out for \"\(text.prefix(60))\": \(error)")
        }
        let translationDoneAt = Date()
        DiagnosticTrace.log(
            "LATENCY_TRACE",
            "PARTIAL_TRANSLATION_LATENCY_MS value=\(Int(translationDoneAt.timeIntervalSince(requestStart) * 1000))"
        )

        guard self.utteranceID == utteranceID, revision == latestDispatchedStreamingRevision else {
            DiagnosticTrace.log("STREAM_RESULT_DISCARDED_STALE", "reason=supersededDuringTranslation utteranceID=\(utteranceID.uuidString) revision=\(revision)")
            return
        }

        currentPartialTranslation = translated
        await displayPartial(source: text, translation: translated, utteranceID: utteranceID, utteranceSequence: utteranceSequence)
        DiagnosticTrace.log(
            "LATENCY_TRACE",
            "PARTIAL_TO_G2_MS value=\(Int(Date().timeIntervalSince(chunkReadyAt) * 1000))"
        )
    }

    /// Updates G2 in place with a provisional (source-only, or source +
    /// partial translation) page — never a `ConversationTurn`, never
    /// persisted anywhere, never sent to Glasses Chat (see this class's
    /// own doc comment on that requirement). Gated by the SAME
    /// sequence-based "has anything newer already displayed" guard the
    /// final-turn pipeline uses (`highestDisplayedTurnSequence`), so a
    /// late-settling partial for an utterance that's already been
    /// superseded — by a newer utterance's own partials, or by its final
    /// — can never clobber what's already on screen.
    private func displayPartial(source: String, translation: String?, utteranceID: UUID, utteranceSequence: Int) async {
        guard utteranceSequence >= highestDisplayedTurnSequence else {
            DiagnosticTrace.log("PARTIAL_DISPLAY_SKIPPED", "reason=staleUtterance(newerAlreadyDisplayed)")
            return
        }
        highestDisplayedTurnSequence = utteranceSequence
        // Conversation Mode: the user has manually navigated G2 away
        // from the live page to review history — never yank it back or
        // overwrite what they're reading with a provisional update.
        // History/state bookkeeping above is untouched; only the actual
        // send to G2 is skipped. `redisplayLiveContent()` catches the
        // display up once they return.
        guard followLive else {
            DiagnosticTrace.log("FOLLOW_LIVE_DISPLAY_SKIPPED", "stage=partial utteranceID=\(utteranceID.uuidString)")
            return
        }
        let page = GlassesPresentationLayer.streamingPage(source: source, translation: translation)
        do {
            try await glassesTransport.displayPages([page])
            currentTurnDisplayState = .streaming(utteranceID: utteranceID)
        } catch {
            sessionMetrics.displayFailureCount += 1
            DiagnosticTrace.log("LIVE_TRACE", "displayPages (partial) failed: \(error)")
        }
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
            sessionMetrics.translationFailureCount += 1
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
            sessionMetrics.translationFailureCount += 1
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

        // "Glasses Chat" — persists this turn as a real, LOCAL-FIRST Chat
        // message (see `GlassesChatProvider.appendTurn(originalText:translation:)`
        // — SwiftData-backed, no network call, never blocked by Railway
        // being offline), entirely independent of G2 display: never
        // awaited by this pipeline, never allowed to delay or fail the
        // display below, and deliberately NOT tracked in `turnTasks` (so
        // it isn't cancelled by `stop()` either) — an already-translated
        // turn should still make it into history even if the user stops
        // Live Translation a moment later. `glassesChatProvider` being
        // `nil` (no production wiring, e.g. in a test) means this is
        // simply never attempted — not a failure.
        if let glassesChatProvider {
            Task {
                do {
                    DiagnosticTrace.log("GLASSES_CHAT_TRACE", "APPEND_START turnID=\(turnID)")
                    let chat = try await glassesChatProvider.findOrCreateGlassesChat()
                    _ = try await glassesChatProvider.appendTurn(originalText: text, translation: displayText)
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
        // Header-only pages, plus one bounded page of look-back context
        // (the turn immediately before this one, if any) — see
        // `GlassesPresentationLayer.conversationPages(for:previousTurn:)`'s
        // doc comment for the conversation-timeline design this is part
        // of. `translatedTurn.suggestedReplies` is still empty at this
        // point, so page 0 is just the Source+Ukrainian header.
        let translationPages = GlassesPresentationLayer.conversationPages(
            for: translatedTurn,
            previousTurn: previousTurn(before: turnID)
        )
        DiagnosticTrace.log("REAL_TURN_TRACE", "PAGES stage=translationOnly turnID=\(turnID) count=\(translationPages.count)")
        DiagnosticTrace.log("POST_STT_TRACE", "PRESENTATION_PAGES_CREATED count=\(translationPages.count)")
        DiagnosticTrace.log("DISPLAY_START", "id=\(turnID)")
        let displayCallStart = Date()
        DiagnosticTrace.log("LATENCY_TRACE", "DISPLAY_CALL_START id=\(turnID)")
        // Conversation Mode: never overwrite what the user is manually
        // reviewing — see `displayPartial`'s identical guard.
        guard followLive else {
            DiagnosticTrace.log("FOLLOW_LIVE_DISPLAY_SKIPPED", "stage=translationOnly turnID=\(turnID)")
            DiagnosticTrace.log("TURN_PIPELINE_RELEASED", "id=\(turnID) reason=followLiveDisabled")
            return
        }
        do {
            DiagnosticTrace.log("REAL_TURN_TRACE", "DISPLAY_REQUEST stage=translationOnly turnID=\(turnID)")
            DiagnosticTrace.log("POST_STT_TRACE", "DISPLAY_REQUEST turnID=\(turnID)")
            try await glassesTransport.displayPages(translationPages)
            currentTurnDisplayState = .translated(turnID: turnID)
            DiagnosticTrace.log("REAL_TURN_TRACE", "DISPLAY_DONE stage=translationOnly turnID=\(turnID)")
            DiagnosticTrace.log("DISPLAY_END", "id=\(turnID)")
            DiagnosticTrace.log("TURN_TRANSLATION_DISPLAYED", "turnID=\(turnID)")
            // The final always wins over any provisional streaming chunk
            // — by this point `resetUtteranceState()` (called at the top
            // of `prepareAndDispatch(final:)`) has already cancelled any
            // in-flight streaming translate/ticker work for this
            // utterance, so this is the authoritative, terminal display
            // for it.
            DiagnosticTrace.log("STREAM_FINAL_COMMIT", "turnID=\(turnID) text=\"\(displayText.prefix(60))\"")
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
            let endToEndMs = Int(now.timeIntervalSince(turnStartTime) * 1000)
            DiagnosticTrace.log("LATENCY_TRACE", "END_TO_END_TRANSLATION_MS id=\(turnID) value=\(endToEndMs)")
            sessionMetrics.recordFirstUsefulTranslationSample(endToEndMs)
        } catch {
            // Same reasoning as the translation catch above — displaying
            // this has no other visibility.
            sessionMetrics.displayFailureCount += 1
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
        let result = await computeSourceLanguage(for: text)
        // Single, unavoidable exit point for the trace the product asked
        // for — every one of `computeSourceLanguage(for:)`'s several
        // return statements funnels through here, so this can't be
        // accidentally skipped by a future return added to that function.
        let mode = sourceLanguageMode.explicitLanguageCode != nil ? "explicit" : "auto"
        DiagnosticTrace.log("FINAL_LANGUAGE_RESOLVED", "mode=\(mode) source=\(result ?? "nil")")
        return result
    }

    private func computeSourceLanguage(for text: String) async -> String? {
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
        let replyPages = GlassesPresentationLayer.conversationPages(
            for: updatedTurn,
            previousTurn: previousTurn(before: turnID)
        )
        DiagnosticTrace.log("REAL_TURN_TRACE", "PAGES stage=withReplies turnID=\(turnID) count=\(replyPages.count)")
        DiagnosticTrace.log("SUGGESTED_REPLIES_PAGES_CREATED", "id=\(turnID) count=\(replyPages.count)")
        let replyDisplayStart = Date()
        // Meeting Mode: replies are lower priority — generated and
        // recorded (already done above) exactly as in Standard mode, but
        // never auto-displayed on G2, keeping the screen dedicated to
        // the conversation transcript. Fully visible in Glasses Chat on
        // the phone either way.
        guard conversationMode != .meeting else {
            DiagnosticTrace.log("MEETING_MODE_REPLY_DISPLAY_SUPPRESSED", "turnID=\(turnID)")
            DiagnosticTrace.log("TURN_PIPELINE_RELEASED", "id=\(turnID) reason=meetingModeRepliesSuppressed")
            return
        }
        // Conversation Mode: never overwrite what the user is manually
        // reviewing. The reply is still recorded in history above
        // (`agentContextStore.updateTurn(updatedTurn)`) — only the G2
        // send is skipped.
        guard followLive else {
            DiagnosticTrace.log("FOLLOW_LIVE_DISPLAY_SKIPPED", "stage=withReplies turnID=\(turnID)")
            DiagnosticTrace.log("TURN_PIPELINE_RELEASED", "id=\(turnID) reason=followLiveDisabled")
            return
        }
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
            sessionMetrics.displayFailureCount += 1
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
