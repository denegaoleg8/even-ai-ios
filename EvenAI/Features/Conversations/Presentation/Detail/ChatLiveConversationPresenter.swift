import Foundation

/// Pure extraction of what `ChatView`'s read-only live-conversation
/// section shows, from the shared `AgentContextSession` — kept separate
/// from the View itself so "which turn is current, which are older, and
/// in what order" is unit-testable without any SwiftUI hosting. `ChatView`
/// calls this and nothing else to decide what to render; there is no
/// second, independent computation of this anywhere.
enum ChatLiveConversationPresenter {
    /// `latest` is the most recent turn in the session, if any — shown
    /// prominently. `older` is every earlier turn from the same session,
    /// **newest-first** (the reverse of `AgentContextSession.turns`'
    /// own oldest-to-newest storage order), since that's the order a
    /// reader wants to scan them in Chat. `latest == nil` (and `older`
    /// empty) whenever the session has no turns yet.
    static func present(_ session: AgentContextSession) -> (latest: ConversationTurn?, older: [ConversationTurn]) {
        guard let latest = session.turns.last else { return (nil, []) }
        return (latest, Array(session.turns.dropLast().reversed()))
    }
}
