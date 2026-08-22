import Foundation

/// Where a `ConversationTurn` originated — lets the one shared timeline
/// (`AgentContextSession.turns`) mix live-conversation translations,
/// phone Chat activity, and manually-added context without losing which
/// is which. Distinct from `ContextItem`, which models raw context
/// material *before* (or without) it's ever promoted into a turn.
enum TurnSource: String, Codable, Hashable, Sendable {
    case liveConversation
    case phoneChat
    case userNote
    case importedContext
}
