import Foundation

/// The ONE shared conversation/session/context object both iPhone Chat
/// and the G2 Live Agent will eventually read and write — there is no
/// separate "G2 AI" and "phone AI", exactly one of these per ongoing
/// conversation. Pure domain state: no networking, no persistence, no
/// Speech/Azure/OpenAI/G2/SwiftUI dependency — whatever owns the real
/// session (a future service, not part of this milestone) is responsible
/// for constructing/mutating/persisting one of these; this type only
/// models the shape and the handful of pure operations every consumer
/// needs (appending a turn, looking up the latest one, adding context).
struct AgentContextSession: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    /// Ordered oldest-to-newest — `append(_:)` is the only supported way
    /// to add one, so that ordering is guaranteed by construction rather
    /// than by every caller's discipline.
    private(set) var turns: [ConversationTurn]
    /// Raw notes/pasted text/imported-file references — see
    /// `ContextItem`'s doc comment for why these are tracked separately
    /// from `turns` rather than folded into the same array.
    private(set) var contextItems: [ContextItem]
    var liveConversationState: LiveConversationState

    init(
        id: UUID = UUID(),
        turns: [ConversationTurn] = [],
        contextItems: [ContextItem] = [],
        liveConversationState: LiveConversationState = .inactive
    ) {
        self.id = id
        self.turns = turns
        self.contextItems = contextItems
        self.liveConversationState = liveConversationState
    }

    /// Appends a turn to the end of the timeline.
    mutating func append(_ turn: ConversationTurn) {
        turns.append(turn)
    }

    /// Replaces the turn with the same `id` as `turn`, if one exists —
    /// used to attach suggested replies once generation completes, since
    /// that happens asynchronously after the turn itself was already
    /// appended (so its translation is visible immediately, without
    /// waiting on reply generation). A no-op if no turn with that id
    /// exists any more.
    mutating func updateTurn(_ turn: ConversationTurn) {
        guard let index = turns.firstIndex(where: { $0.id == turn.id }) else { return }
        turns[index] = turn
    }

    /// Removes the turn with the given `id`, if one exists — used when a
    /// turn was appended as a draft (translation still pending) but that
    /// translation then failed/timed out/came back empty: the product
    /// requirement is that a failed translation leaves no trace in
    /// history or on G2, matching what a fully-synchronous "only append
    /// once translation succeeds" pipeline would have done. A no-op if no
    /// turn with that id exists any more (e.g. already removed, or the
    /// session was reset).
    mutating func removeTurn(id: ConversationTurn.ID) {
        turns.removeAll { $0.id == id }
    }

    /// Adds a piece of raw context material — never implicitly appended
    /// to `turns`.
    mutating func addContext(_ item: ContextItem) {
        contextItems.append(item)
    }

    /// The most recent turn, if any — what both G2 (via a future
    /// Presentation Layer) and Chat's live-state banner read to know
    /// "what's current." `nil` for a session with no turns yet, never a
    /// placeholder turn.
    var latestTurn: ConversationTurn? {
        turns.last
    }
}
