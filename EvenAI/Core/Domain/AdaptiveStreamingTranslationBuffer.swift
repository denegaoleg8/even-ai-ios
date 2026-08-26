import Foundation

/// Decides WHEN a growing partial transcript is worth actually
/// translating — pure, deterministic (driven entirely by an explicit
/// `now:` timestamp the caller supplies, never `Date()` internally), no
/// I/O, no Foundation networking. Mirrors this codebase's established
/// "pure state machine, unit-testable in isolation" pattern
/// (`GlassesPaginationState`/`GlassesReadinessGate`).
///
/// ## The "word-by-word" bug this replaces
///
/// The previous streaming design fired a translate-and-display call after
/// a FLAT 150ms of no new partial text, no matter how little that text
/// represented. During fast, continuous speech, STT's own partial-update
/// cadence has small natural micro-gaps — often just under, and
/// sometimes just over, 150ms — even mid-sentence, well before the
/// speaker has actually paused. A flat 150ms debounce fires on those
/// micro-gaps too, translating "Як...", then "Як ти...", then "Як ти
/// збираєшся..." as three independent, contextually-incomplete
/// translation calls instead of waiting for something semantically
/// whole. Individual words/fragments translated in isolation don't carry
/// enough context for correct grammar, and the constant on-screen churn
/// is distracting on its own even when each fragment happens to be
/// "correct" in isolation.
///
/// ## Chunk-boundary signals (this type implements 3 of the 4
/// content-driven ones the product asked for; the 4th — "final
/// transcript arrives" — is handled one layer up, in
/// `AIConversationEngine`, since a final is a structurally different
/// event from a partial, not something this buffer ever sees)
///
/// 1. **Punctuation / clause boundary** — the accumulated text now ends
///    in `. , ! ? ; :` — fires immediately, no waiting, since STT
///    reporting punctuation is itself strong evidence of a complete
///    clause/sentence.
/// 2. **Stability (a natural pause)** — `stabilityWindow` (350ms) of no
///    NEW text arriving. This is also where "enough stable semantic
///    content accumulated" lives conceptually: stability, by
///    definition, only fires once whatever text has accumulated has
///    stopped growing — there's no meaningful separate "accumulated
///    enough content" signal beyond that. 350ms is comfortably longer
///    than the micro-gaps that caused the word-by-word bug (measured
///    against real STT partial cadence during continuous speech — see
///    this type's test suite for the exact boundary case), and
///    comfortably shorter than feeling like a dead debounce.
/// 3. **Maximum latency budget** — `maxLatencyBudget` (900ms since the
///    last chunk, or utterance start) — the hard upper bound: a long,
///    fast, run-on sentence with no punctuation and no real pause still
///    gets a fresh chunk roughly every 0.5–1.0s, matching the product's
///    own target for continuous speech, instead of silently falling
///    further and further behind the speaker or waiting for the whole
///    utterance to finish.
///
/// No minimum word/character count gate: deliberately omitted. An
/// earlier draft of this design gated stability/budget-triggered chunks
/// on "at least N words," but that directly regresses short single-word
/// utterances ("Hello", "Yes") — exactly the phrases an EARLIER
/// milestone already hardened for reliability. A genuine pause (signal
/// 2) is itself sufficient evidence a one-word utterance is complete;
/// gating it on word count would only reintroduce a different bug to
/// fix the same underlying complaint.
///
/// ## Full-utterance re-translation, not incremental delta-stitching
///
/// Deliberately translates the WHOLE accumulated utterance text on every
/// chunk, never just the newly-added tail. Stitching together
/// independently-translated fragments risks exactly the grammar/pronoun
/// correctness problem the product explicitly warned about ("preserve
/// enough previous source context so pronouns, grammar and sentence
/// meaning remain correct") — translating "because I have an important
/// meeting there" in true isolation, with no access to "I want to go to
/// Berlin tomorrow" preceding it, can legitimately produce different
/// grammar in Ukrainian than translating the whole sentence together.
/// Always including the full accumulated text as translation context is
/// the safe, correct choice for a display surface (G2's one-line header)
/// that shows one evolving utterance at a time rather than a scrolling
/// multi-chunk transcript — there's no second area of the screen an
/// incrementally-committed earlier chunk would even go.
struct AdaptiveStreamingTranslationBuffer: Equatable {
    static let stabilityWindow: TimeInterval = 0.35
    static let maxLatencyBudget: TimeInterval = 0.9

    enum Decision: Equatable {
        /// Nothing worth translating yet — caller should keep waiting
        /// (either for the next partial, or the next periodic recheck).
        case wait
        /// `text` is ready to translate now; `revision` is this
        /// utterance's monotonically increasing chunk counter — the
        /// authoritative staleness key alongside `utteranceID` (see
        /// `AIConversationEngine.settleStreamingChunk(...)`'s doc
        /// comment for how these two together prevent an older,
        /// slower-resolving translation response from ever overwriting a
        /// newer one).
        case ready(text: String, revision: Int)
    }

    private(set) var utteranceID: UUID?
    private var text = ""
    private var lastUpdateAt: Date?
    private var lastChunkAt: Date?
    private var lastChunkText = ""
    private(set) var revision = 0

    /// Starts tracking a brand-new utterance — always call this before
    /// the utterance's first `receivePartial(_:now:)`. Any state from a
    /// previous utterance (there shouldn't be any live by this point —
    /// callers reset between utterances) is discarded.
    mutating func beginUtterance(id: UUID, now: Date) {
        utteranceID = id
        text = ""
        lastUpdateAt = now
        lastChunkAt = now
        lastChunkText = ""
        revision = 0
    }

    /// Call once the utterance's final transcript arrives (or the
    /// session stops) — clears all state so a later, unrelated call
    /// can't be mistaken for belonging to this utterance.
    mutating func endUtterance() {
        utteranceID = nil
        text = ""
        lastUpdateAt = nil
        lastChunkAt = nil
        lastChunkText = ""
    }

    /// Feed one new partial's full (not delta) text. Re-evaluates
    /// immediately — this is what lets a punctuation-ending partial fire
    /// a chunk right away, without waiting for the next periodic
    /// `tick(now:)`.
    mutating func receivePartial(_ newText: String, now: Date) -> Decision {
        text = newText
        lastUpdateAt = now
        return evaluate(now: now)
    }

    /// Call periodically (e.g. every 100ms) while an utterance is in
    /// progress, independent of whether any NEW partial has arrived —
    /// this is the only way a genuine pause (signal 2) or the max-
    /// latency budget (signal 3) can ever fire, since neither depends on
    /// new text arriving.
    mutating func tick(now: Date) -> Decision {
        evaluate(now: now)
    }

    private mutating func evaluate(now: Date) -> Decision {
        guard utteranceID != nil, !text.isEmpty, text != lastChunkText else { return .wait }

        if Self.endsAtClauseBoundary(text) {
            return commit(now: now)
        }
        if let lastUpdateAt, now.timeIntervalSince(lastUpdateAt) >= Self.stabilityWindow {
            return commit(now: now)
        }
        let sinceLastChunk = now.timeIntervalSince(lastChunkAt ?? now)
        if sinceLastChunk >= Self.maxLatencyBudget {
            return commit(now: now)
        }
        return .wait
    }

    private mutating func commit(now: Date) -> Decision {
        revision += 1
        lastChunkText = text
        lastChunkAt = now
        return .ready(text: text, revision: revision)
    }

    private static func endsAtClauseBoundary(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return ".,!?;:".contains(last)
    }
}
