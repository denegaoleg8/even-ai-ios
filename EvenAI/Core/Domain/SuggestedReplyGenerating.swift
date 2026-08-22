import Foundation

/// Background material a `SuggestedReplyGenerating` implementation may
/// use to produce better replies — kept as its own type (not inlined as
/// loose parameters) so the protocol can grow what it passes without
/// changing its method signature.
///
/// `recentTurns` is oldest-first (mirrors `AgentContextSession.turns`'
/// own storage order — the natural chronological reading order for
/// feeding a transcript to a generator), which is the opposite of
/// `ChatLiveConversationPresenter`'s display-oriented newest-first
/// convention; callers should not assume these agree.
struct SuggestedReplyContext: Equatable, Sendable {
    var recentTurns: [ConversationTurn]
    /// Notes/pasted text/imported-file references — see `ContextItem`.
    var contextItems: [ContextItem]

    init(recentTurns: [ConversationTurn] = [], contextItems: [ContextItem] = []) {
        self.recentTurns = recentTurns
        self.contextItems = contextItems
    }
}

/// Abstraction over generating short suggested replies for a finalized,
/// foreign-language `ConversationTurn` — deliberately provider-agnostic.
/// No concrete AI provider (OpenAI/Azure/etc.) is named anywhere in this
/// protocol or in `SuggestedReplyContext`; a future concrete
/// implementation (in `Infrastructure`, per the Dependency Rule) is
/// whatever actually calls out to a chosen provider. This milestone ships
/// only the protocol plus `NoOpSuggestedReplyGenerator`, a placeholder
/// that always returns no replies — there is no real generator yet.
protocol SuggestedReplyGenerating: Sendable {
    /// Generates at most 3 short suggested replies for `turn` — in the
    /// language `turn` was spoken in, each with its own Ukrainian
    /// translation. Callers must never call this for a Ukrainian-sourced
    /// turn; this protocol does not re-check that itself, matching
    /// `ConversationTurn`'s own approach of keeping the "ignore Ukrainian"
    /// policy with whoever produces/acts on turns rather than duplicating
    /// the check at every layer.
    ///
    /// Throws on failure. Callers (see `LiveTranslationService`) must
    /// treat a thrown error as "no replies this time" — the turn's own
    /// translation must remain visible regardless, per the product
    /// requirement that a reply-generation failure never hides it.
    func generateReplies(for turn: ConversationTurn, context: SuggestedReplyContext) async throws -> [SuggestedReply]
}
