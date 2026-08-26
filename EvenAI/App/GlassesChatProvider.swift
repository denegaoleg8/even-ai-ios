import Foundation
import Observation

/// Finds or lazily creates the one persistent "Glasses Chat" conversation
/// that every G2/Live Translation interaction appends to — a stable,
/// reusable `Chat` rather than a fresh one per Live Translation session.
///
/// ## Local-first (architecture pass)
///
/// Originally built on top of `ChatServicing` (network-first — every
/// `findOrCreateGlassesChat()`/append went through Railway before
/// anything was persisted anywhere). A real production Railway outage
/// showed exactly why that was wrong for THIS feature specifically: with
/// the backend unreachable, `chatService.createChat(...)`/`appendMessage(...)`
/// simply threw, `ChatListView.openGlassesChat()` swallowed the error, and
/// Live Translation turns were never durably recorded anywhere — not even
/// to disk. Glasses Chat is now backed directly by `LocalGlassesChatStore`
/// (SwiftData, no network call anywhere in the read/write path) — the
/// device's own recording of G2 conversations must never depend on
/// Railway, a signed-in account, or connectivity at all. Optional
/// best-effort backend sync (so Glasses Chat history could also appear on
/// another signed-in device) is intentionally NOT implemented here — see
/// this app's local-first architecture report for why that's deferred,
/// separate work.
///
/// Identity is a `Chat.ID` (`UUID`) persisted locally via `UserDefaults`,
/// not the chat's title — the title (`Self.displayTitle`, "Glasses Chat")
/// is purely cosmetic, exactly the anti-pattern this was told explicitly
/// to avoid (`MockChatService.seedWelcomeChat`'s "Welcome to Even AI" is
/// identified only by being the first/only chat, with zero collision
/// protection — deliberately not repeated here).
///
/// Because the store is now purely local/per-device rather than
/// per-account/remote, Glasses Chat is deliberately device-scoped, not
/// account-scoped: it survives sign-out/sign-in/account-switch untouched
/// (unlike normal AI Chat's `CachingChatService`, which invalidates its
/// entire cache on those events) — the same G2 physically paired to this
/// phone is having the same conversations regardless of which account
/// happens to be signed in, which is exactly the local-first product
/// requirement ("must work even with no paid server subscription").
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

    private let localStore: LocalGlassesChatStore
    private let defaults: UserDefaults
    /// Resolved once per app run (or per `invalidateCache()` call) and
    /// reused — `findOrCreateGlassesChat()` is called once per Live
    /// Translation turn, and re-hitting SwiftData before every single
    /// message send would add needless overhead to that path.
    private var cachedChat: Chat?
    /// Serializes concurrent callers so two turns finalizing close
    /// together, before the chat has ever been resolved, can never both
    /// create two separate local chats.
    private var inFlight: Task<Chat, Never>?

    init(localStore: LocalGlassesChatStore = LocalGlassesChatStore(), defaults: UserDefaults = .standard) {
        self.localStore = localStore
        self.defaults = defaults
    }

    /// Always succeeds — a local SwiftData write failing is as unlikely
    /// offline as online, unlike the old network-first design this
    /// replaced. Kept `async throws` (rather than dropping `throws`
    /// entirely) purely to avoid a breaking signature change for every
    /// existing call site; nothing in the local-first implementation
    /// itself ever throws.
    func findOrCreateGlassesChat() async throws -> Chat {
        if let cachedChat {
            return cachedChat
        }
        if let inFlight {
            return await inFlight.value
        }
        let task = Task { await resolve() }
        inFlight = task
        let chat = await task.value
        inFlight = nil
        cachedChat = chat
        return chat
    }

    /// Persists one finalized Live Translation turn to Glasses Chat —
    /// resolves (find-or-create) the chat first, then appends. Local-only,
    /// same as `findOrCreateGlassesChat()`: never throws in practice, never
    /// touches the network, never blocked by Railway being offline.
    @discardableResult
    func appendTurn(originalText: String, translation: String) async throws -> Message? {
        let chat = try await findOrCreateGlassesChat()
        return await localStore.appendMessage(
            chatID: chat.id,
            role: .user,
            content: "\(originalText)\n→ \(translation)"
        )
    }

    /// Persists a finalized turn's suggested replies as a follow-up
    /// Glasses Chat message, local-first exactly like `appendTurn(originalText:translation:)`
    /// — no network, never blocked by Railway being offline. A separate
    /// message (appended immediately after the turn's own, since reply
    /// generation always finishes later — see `AIConversationEngine
    /// .generateSuggestedReplies`) rather than an edit to the original
    /// one: SwiftData writes here are simple inserts, never updates, and
    /// a chat log reading as an ordered sequence of atomic entries (turn,
    /// then its replies once ready) is both simpler to implement
    /// correctly and a more honest transcript than silently rewriting an
    /// earlier entry after the fact. `role: .assistant` — these are
    /// AI-generated suggestions, not something the other speaker said.
    /// A no-op (returns `nil`, no chat resolved/created) when `replies`
    /// is empty — nothing meaningful to persist.
    @discardableResult
    func appendReplies(originalText: String, replies: [SuggestedReply]) async throws -> Message? {
        guard !replies.isEmpty else { return nil }
        let chat = try await findOrCreateGlassesChat()
        let repliesText = replies
            .sorted { $0.ordering < $1.ordering }
            .enumerated()
            .map { index, reply in "\(index + 1). \(reply.originalLanguageText)\n   \(reply.ukrainianText)" }
            .joined(separator: "\n")
        return await localStore.appendMessage(
            chatID: chat.id,
            role: .assistant,
            content: "Suggested replies for: \"\(originalText)\"\n\(repliesText)"
        )
    }

    /// Call after anything that could have invalidated the in-memory
    /// resolution (not required for correctness — the persisted id and
    /// underlying local chat are untouched by account changes, see this
    /// type's own doc comment — but forces a fresh SwiftData lookup rather
    /// than trusting a possibly-stale in-memory reference).
    func invalidateCache() {
        cachedChat = nil
    }

    private func resolve() async -> Chat {
        let chat = await localStore.findOrCreateChat(id: persistedChatID(), title: Self.displayTitle)
        persist(chatID: chat.id)
        DiagnosticTrace.log("GLASSES_CHAT_TRACE", "RESOLVED id=\(chat.id) source=local")
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
