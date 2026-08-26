import Foundation

/// Milestone 4 placeholder: always returns no replies. Exists so
/// `AIConversationEngine` has a concrete `SuggestedReplyGenerating` to
/// default to (and `EvenAIApp` to wire the real app with) before any
/// actual AI provider is chosen — see `SuggestedReplyGenerating`'s doc
/// comment. Replacing this with a real, backend-calling implementation
/// is exactly the next milestone's job; nothing about
/// `AIConversationEngine`'s integration needs to change to do that,
/// only which concrete type is constructed here.
struct NoOpSuggestedReplyGenerator: SuggestedReplyGenerating {
    func generateReplies(for turn: ConversationTurn, context: SuggestedReplyContext) async throws -> [SuggestedReply] {
        []
    }
}
