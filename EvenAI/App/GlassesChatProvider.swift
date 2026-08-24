import Foundation
import Observation

/// Finds or lazily creates the one persistent "Glasses Chat" conversation
/// that every G2/Live Translation interaction appends to — a stable,
/// reusable `Chat` rather than a fresh one per Live Translation session.
///
/// Built entirely on top of the existing `ChatServicing` protocol: no new
/// backend endpoint for chat *identity*, no SwiftData schema change, no
/// `SchemaMigrationPlan` (there is no migration infrastructure in this app
/// at all today — see `PersistenceController`). Identity is a `Chat.ID`
/// (`UUID`) persisted locally via `UserDefaults`, not the chat's title —
/// the title (`Self.displayTitle`, "Glasses Chat") is purely cosmetic,
/// exactly the anti-pattern this was told explicitly to avoid
/// (`MockChatService.seedWelcomeChat`'s "Welcome to Even AI" is identified
/// only by being the first/only chat, with zero collision protection —
/// deliberately not repeated here).
///
/// Self-healing by construction, not by special-casing: chats are scoped
/// per-account server-side (a chat belonging to a different account 404s
/// exactly like one that doesn't exist), and `CachingChatService.invalidate()`
/// wipes the entire local cache on logout/account-switch/merge. Both cases
/// look identical from here — "the persisted id doesn't resolve anymore" —
/// and both recover the same way: create a fresh chat and persist its id.
/// This never produces more than one *reachable* Glasses Chat for the
/// current account at a time; an old one from a previous account still
/// exists (correctly — it belongs to that account, not deleted), it's
/// simply no longer the one this provider points at.
/// `@Observable`, injected app-wide via `.environment(_:)` — mirrors
/// `AgentContextStore`'s own pattern (an `App`-level type, read directly
/// via `@Environment(GlassesChatProvider.self)` by any consuming view,
/// e.g. `ChatListView`'s "Glasses Chat" entry — not threaded through
/// `RootView`'s constructor the way `Infrastructure`-level swappable
/// services like `ChatServicing` are). No UI currently reads a published
/// property here; `@Observable` costs nothing and keeps the injection
/// mechanism consistent with every other app-level service.
@MainActor
@Observable
final class GlassesChatProvider {
    static let displayTitle = "Glasses Chat"
    private static let userDefaultsKey = "com.evenai.glassesChatID"

    private let chatService: ChatServicing
    private let defaults: UserDefaults
    /// Resolved once per app run (or per `invalidateCache()` call) and
    /// reused — `findOrCreateGlassesChat()` is called once per Live
    /// Translation turn, and re-verifying against the network before every
    /// single message send would add needless latency to that path.
    private var cachedChat: Chat?
    /// Serializes concurrent callers so two turns finalizing close
    /// together, before the chat has ever been resolved, can never both
    /// call `createChat` and produce two live chats.
    private var inFlight: Task<Chat, Error>?

    init(chatService: ChatServicing, defaults: UserDefaults = .standard) {
        self.chatService = chatService
        self.defaults = defaults
    }

    func findOrCreateGlassesChat() async throws -> Chat {
        if let cachedChat {
            return cachedChat
        }
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await resolve() }
        inFlight = task
        do {
            let chat = try await task.value
            inFlight = nil
            cachedChat = chat
            return chat
        } catch {
            inFlight = nil
            throw error
        }
    }

    /// Call after anything that could have invalidated the persisted id's
    /// meaning for the *current* session (e.g. `AuthState` signing out) —
    /// not required for correctness (a stale id just self-heals on the
    /// next `findOrCreateGlassesChat()` call via the 404 path below), but
    /// avoids one guaranteed-failing network round trip immediately after
    /// an account change.
    func invalidateCache() {
        cachedChat = nil
    }

    private func resolve() async throws -> Chat {
        if let persistedID = persistedChatID() {
            do {
                let chat = try await chatService.fetchChat(id: persistedID)
                DiagnosticTrace.log("GLASSES_CHAT_TRACE", "REUSED id=\(chat.id)")
                return chat
            } catch {
                DiagnosticTrace.log("GLASSES_CHAT_TRACE", "PERSISTED_ID_STALE id=\(persistedID) error=\(error) — creating a new chat")
            }
        }
        let chat = try await chatService.createChat(title: Self.displayTitle)
        persist(chatID: chat.id)
        DiagnosticTrace.log("GLASSES_CHAT_TRACE", "CREATED id=\(chat.id)")
        return chat
    }

    private func persistedChatID() -> UUID? {
        guard let string = defaults.string(forKey: Self.userDefaultsKey) else { return nil }
        return UUID(uuidString: string)
    }

    private func persist(chatID: UUID) {
        defaults.set(chatID.uuidString, forKey: Self.userDefaultsKey)
    }
}
