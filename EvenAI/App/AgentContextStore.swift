import Foundation
import Observation

/// The app-level owner of the ONE shared `AgentContextSession` — mirrors
/// `AppState`/`AuthState`/`LiveTranslationService`: stateful, observable,
/// app-lifetime state constructed once in `EvenAIApp` and shared *by
/// identity*, not just by value, with every consumer that needs to read
/// or extend it. `LiveTranslationService` is the first such consumer
/// (Milestone 2) — Chat mirroring and any other reader are later,
/// unscoped work.
///
/// `AgentContextSession` itself stays exactly what Milestone 1 made it: a
/// plain, pure, `Codable`/`Equatable` value type, independent of
/// Speech/Azure/OpenAI/G2/SwiftUI. This class is only the
/// ownership/mutation wrapper around that ONE value — not a second,
/// competing session store. Every mutation goes through a method here
/// (`appendTurn(_:)`), so there is exactly one choke point for "how does
/// a turn get added," matching how `AgentContextSession.append(_:)`
/// itself is the only way to add a turn to the value type underneath.
@MainActor
@Observable
final class AgentContextStore {
    private(set) var session: AgentContextSession

    init(session: AgentContextSession = AgentContextSession()) {
        self.session = session
    }

    /// Appends a turn to the shared session — the one mutation
    /// `LiveTranslationService` needs for Milestone 2.
    func appendTurn(_ turn: ConversationTurn) {
        session.append(turn)
    }

    /// Replaces an already-appended turn (matched by `id`) — Milestone
    /// 4's way of attaching suggested replies once generation completes,
    /// asynchronously after the turn's translation was already appended
    /// and shown.
    func updateTurn(_ turn: ConversationTurn) {
        session.updateTurn(turn)
    }

    /// Removes an already-appended turn — used when a turn was appended
    /// as a draft (translation still pending) but that translation then
    /// failed/timed out/came back empty. See
    /// `AgentContextSession.removeTurn(id:)`'s own doc comment.
    func removeTurn(id: ConversationTurn.ID) {
        session.removeTurn(id: id)
    }

    /// Adds a note/pasted-text/imported-file reference to the shared
    /// session — background material `SuggestedReplyGenerating`
    /// implementations can read via `SuggestedReplyContext.contextItems`.
    /// No phone-side UI writes through this yet; it exists so tests (and
    /// a future notes/context screen) have a real entry point rather than
    /// mutating `session` directly.
    func addContext(_ item: ContextItem) {
        session.addContext(item)
    }
}
