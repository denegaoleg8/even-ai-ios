import Foundation

/// **Phase 3 — Personal AI → G2 Integration.**
///
/// A `SuggestedReplyGenerating` **decorator** that folds the *local* Personal
/// AI context into the reply-generation request, then delegates to a wrapped
/// base generator. It is the single, narrow seam through which Personal AI
/// influences G2 suggested replies — nothing above it
/// (`AIConversationEngine`, translation, transcription, the G2 transport)
/// changes, and nothing about it is a hard dependency:
///
/// - Personal AI is an **optional advisory layer**. Any failure — no relevant
///   memory, memory disabled, a slow/hung context build past the enrichment
///   budget, an account switch mid-build — falls through to
///   `base.generateReplies(for:context:)` with the **un-enriched** context, so
///   the existing local reply behaviour is byte-for-byte preserved.
/// - **Caller cancellation is distinct from a Personal AI failure.** A
///   `CancellationError` (a newer utterance superseded this turn) is
///   re-thrown, never turned into a stale "successful" result.
/// - **Single-pass:** `base.generateReplies` is invoked **exactly once** per
///   call (zero times only if the caller cancelled). No base-then-enriched
///   double generation, no publish/replace, no flicker.
/// - It owns **only** enrichment. Not transcription, translation, the
///   microphone, glasses rendering, the G2 transport, persistence, cloud
///   sync, authentication, or memory extraction.
struct PersonalAIContextEnrichingSuggestedReplyGenerator: SuggestedReplyGenerating {

    private let base: any SuggestedReplyGenerating
    private let contextBuilder: any PersonalAIContextBuilding
    /// The Personal AI owner identity *right now* — read fresh, snapshotted at
    /// the start of a call and re-checked before use, so an account switch
    /// during an in-flight build discards that build's enrichment.
    private let ownerID: @Sendable () -> String?
    /// The current AI Conversation presentation profile — read from the same
    /// persisted key `AIConversationEngine` owns, so this type never references
    /// the engine.
    private let conversationProfile: @Sendable () -> ConversationProfile
    private let config: PersonalAIReplyEnrichmentConfig

    init(
        base: any SuggestedReplyGenerating,
        contextBuilder: any PersonalAIContextBuilding,
        ownerID: @escaping @Sendable () -> String?,
        conversationProfile: @escaping @Sendable () -> ConversationProfile,
        config: PersonalAIReplyEnrichmentConfig = .default
    ) {
        self.base = base
        self.contextBuilder = contextBuilder
        self.ownerID = ownerID
        self.conversationProfile = conversationProfile
        self.config = config
    }

    func generateReplies(for turn: ConversationTurn, context: SuggestedReplyContext) async throws -> [SuggestedReply] {
        // Caller already cancelled → this whole turn is obsolete. Never a base call.
        try Task.checkCancellation()

        let ownerAtStart = ownerID()

        let block: String?
        do {
            block = try await enrichmentBlock(for: turn, base: context, ownerAtStart: ownerAtStart)
        } catch is CancellationError {
            // A newer utterance superseded this turn. Surface it — the engine
            // treats it as "cancelled", NOT as "no replies" and NOT as a
            // publishable result.
            DiagnosticTrace.log("PERSONAL_AI_ENRICH", "cancelled turnID=\(turn.id)")
            throw CancellationError()
        } catch {
            // Any other enrichment failure (timeout, unexpected) → plain replies.
            DiagnosticTrace.log("PERSONAL_AI_ENRICH", "fallback turnID=\(turn.id) reason=\(type(of: error))")
            return try await base.generateReplies(for: turn, context: context)
        }

        guard let block else {
            return try await base.generateReplies(for: turn, context: context)
        }

        var enriched = context
        enriched.personalAIContext = block
        DiagnosticTrace.log("PERSONAL_AI_ENRICH", "applied turnID=\(turn.id) blockTokens≈\(block.count / 4)")
        return try await base.generateReplies(for: turn, context: enriched)
    }

    /// The rendered enrichment block, or `nil` when there is nothing usable
    /// (memory disabled, no personalisation, account switched mid-build).
    /// Throws `CancellationError` on caller cancellation and
    /// `EnrichmentTimedOut` when the build exceeds `config.enrichmentTimeout`.
    private func enrichmentBlock(
        for turn: ConversationTurn,
        base: SuggestedReplyContext,
        ownerAtStart: String?
    ) async throws -> String? {
        let request = PersonalAIContextRequest(
            surface: config.surface,
            userMessage: turn.originalText,
            recentConversation: base.recentTurns
                .suffix(config.maxRecentConversationLines)
                .map(\.originalText),
            conversationID: nil,
            tokenBudget: config.contextTokenBudget,
            now: Date()
        )

        let builder = contextBuilder
        let personal = try await Self.withEnrichmentTimeout(config.enrichmentTimeout) {
            await builder.buildContext(request)
        }

        // Re-validate BEFORE the result can influence anything.
        try Task.checkCancellation()
        guard ownerID() == ownerAtStart else {
            DiagnosticTrace.log("PERSONAL_AI_ENRICH", "discarded turnID=\(turn.id) reason=ownerChanged")
            return nil
        }
        guard !personal.memoryDisabled, personal.hasPersonalization else { return nil }

        let rendered = PersonalAIReplyContextRenderer.replyBlock(
            from: personal,
            profile: conversationProfile()
        )
        return rendered.isEmpty ? nil : rendered
    }

    struct EnrichmentTimedOut: Error {}

    /// Race `work` against `timeout`. On the caller's task being cancelled,
    /// `Task.sleep` throws `CancellationError` and that propagates unchanged
    /// (so cancellation is never misread as a timeout). On the timeout
    /// elapsing, throws `EnrichmentTimedOut`. Either way the work task is
    /// cancelled and its result — if any — discarded.
    static func withEnrichmentTimeout<T: Sendable>(
        _ timeout: Duration,
        _ work: @escaping @Sendable () async -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { await work() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw EnrichmentTimedOut()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw EnrichmentTimedOut() }
            return first
        }
    }
}

// MARK: - Tuning

/// **The one place** the Phase 3 Personal AI enrichment tuning values live.
/// Initial values are from `PHASE3_PERSONAL_AI_G2_PLAN.md`; they are *starting
/// points* to be adjusted from real-hardware measurement (Slice 5), and are
/// injectable so a test can pin behaviour without waiting real seconds.
/// No `700` / `4` literal appears anywhere else.
struct PersonalAIReplyEnrichmentConfig: Sendable, Equatable {

    /// Approximate token ceiling for the assembled Personal AI context block.
    /// Handed straight to `PersonalAIContextRequest.tokenBudget`; the existing
    /// `PersonalAIContextRenderer` does the priority-aware, lowest-first
    /// trimming. Smaller than Personal AI Chat's 1200 — a G2 reply prompt
    /// needs only what is relevant to the latest phrase.
    var contextTokenBudget: Int

    /// Hard bound on how long the context build (retrieval + assembly) may run
    /// before the decorator abandons it and delegates to the base generator.
    /// **Strictly inside** `AIConversationEngine.repliesTimeout` (15 s) — a
    /// slow retrieval can never extend the reply budget the engine already
    /// enforces, and never affects translation or listening.
    var enrichmentTimeout: Duration

    /// The retrieval surface — always `.g2Replies` for this path, so
    /// `.g2Replies`-scoped rules/memories apply and `.personalChat`-scoped ones
    /// do not.
    var surface: PersonalAISurface

    /// How many recent turns' text to pass as retrieval context. The engine
    /// already caps `recentTurns` to 6; trimmed here because reply relevance
    /// depends overwhelmingly on the latest phrase.
    var maxRecentConversationLines: Int

    static let `default` = PersonalAIReplyEnrichmentConfig(
        contextTokenBudget: 700,
        enrichmentTimeout: .seconds(4),
        surface: .g2Replies,
        maxRecentConversationLines: 4
    )
}

// MARK: - Rendering the enrichment block

/// Wraps `PersonalAIContext.systemPromptText` (already priority-ordered and
/// budgeted by `PersonalAIContextRenderer`) with short reply-framing guidance
/// and one profile line. Adds **no** memory content of its own — it only
/// frames what the builder produced.
enum PersonalAIReplyContextRenderer {

    static func replyBlock(from context: PersonalAIContext, profile: ConversationProfile) -> String {
        guard context.hasPersonalization, !context.memoryDisabled,
              !context.systemPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return "" }

        return [
            "Context about the person you are drafting replies for — use it so the replies sound like something they would actually say. Never mention that you know any of this.",
            context.systemPromptText,
            profileGuidance(for: profile),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    /// Phase 3 does not redesign `ConversationProfile`. `.auto` uses the
    /// conversation guidance (its more common resolution); a later slice may
    /// pass the engine's `effectiveDisplayProfile` if physical testing shows
    /// it matters.
    static func profileGuidance(for profile: ConversationProfile) -> String {
        switch profile {
        case .meeting:
            return "Setting: a meeting or group conversation. Prefer concise, professional replies and useful follow-up questions; keep every one short enough to read at a glance on a small display."
        case .conversation, .auto:
            return "Setting: a one-to-one conversation. Give 2–3 concise, natural replies in the speaker's language, personalised to the context above — no generic filler."
        }
    }
}
