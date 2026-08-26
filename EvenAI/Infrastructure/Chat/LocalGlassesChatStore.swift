import Foundation
import SwiftData

/// Local-first persistence for "Glasses Chat" — the local-first
/// architecture pass's fix for the exact bug a real Railway outage
/// exposed: `GlassesChatProvider` used to resolve/create the Glasses Chat
/// through `ChatServicing` (`CachingChatService` wrapping
/// `NetworkChatService`), whose writes (`createChat`/`appendMessage`) are
/// network-first — `try await wrapped.createChat(...)` with no local
/// fallback at all. With Railway offline, `findOrCreateGlassesChat()`
/// threw, `ChatListView.openGlassesChat()` caught it and silently did
/// nothing, and every Live Translation turn's Chat-append `Task` in
/// `AIConversationEngine.processTurn` failed and was permanently lost —
/// not even written to disk, since the write-through cache only mirrors a
/// SUCCESSFUL network write.
///
/// This type writes directly to SwiftData — the SAME `ChatEntity`/
/// `MessageEntity` schema and `PersistenceController.shared` container
/// `CachingChatService` already uses for its read-cache, so any Glasses
/// Chat history written while Railway was still up (via the old path)
/// remains fully readable here; there is no migration, just a new,
/// always-local write path pointed at the same storage. No network call
/// exists anywhere in this type — Glasses Chat now structurally cannot be
/// blocked by Railway being offline, a missing auth token, or airplane
/// mode. Optional backend sync (mirroring locally-created turns to the
/// real backend once reachable, for cross-device history) is explicitly
/// NOT implemented here — see this app's local-first architecture report
/// for why that's a deliberately deferred, separate piece of work, not an
/// oversight.
actor LocalGlassesChatStore {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer = PersistenceController.shared) {
        self.modelContainer = modelContainer
    }

    /// Looks up `id` locally; if absent (no id yet, or a persisted id from
    /// a store that's since been cleared), creates a fresh local
    /// `ChatEntity` and returns it — this ALWAYS succeeds (barring a
    /// genuine on-disk SwiftData failure, exactly as unlikely offline as
    /// online), unlike the old network-first `createChat` path.
    func findOrCreateChat(id: Chat.ID?, title: String) -> Chat {
        let context = ModelContext(modelContainer)
        if let id, let existing = fetchChatEntity(id: id, context: context) {
            return existing.toDomain()
        }
        // `id` not found (either `nil` — never persisted one — or a STALE
        // id that no longer resolves to any local chat) — either way, a
        // fresh `UUID()` is generated here, never `id` itself: reusing a
        // stale id as the new chat's id would make this indistinguishable
        // from a genuine reuse to every caller, defeating the whole point
        // of "self-heals by creating a fresh chat."
        let entity = ChatEntity(id: UUID(), title: title)
        context.insert(entity)
        try? context.save()
        return entity.toDomain()
    }

    func fetchChat(id: Chat.ID) -> Chat? {
        fetchChatEntity(id: id, context: ModelContext(modelContainer))?.toDomain()
    }

    /// Appends one message to `chatID` and returns the persisted domain
    /// `Message` — `nil` only if `chatID` doesn't resolve to a local chat
    /// at all (shouldn't happen through `GlassesChatProvider`'s normal
    /// find-or-create flow, but this stays a safe no-op rather than a
    /// crash if it ever does, e.g. a chat deleted from Settings mid-turn).
    @discardableResult
    func appendMessage(chatID: Chat.ID, role: MessageRole, content: String) -> Message? {
        let context = ModelContext(modelContainer)
        guard let chatEntity = fetchChatEntity(id: chatID, context: context) else { return nil }
        let messageEntity = MessageEntity(role: role, content: content, chat: chatEntity)
        context.insert(messageEntity)
        chatEntity.messages.append(messageEntity)
        chatEntity.updatedAt = messageEntity.createdAt
        chatEntity.lastMessagePreview = content
        try? context.save()
        return messageEntity.toDomain()
    }

    func fetchMessages(chatID: Chat.ID) -> [Message] {
        let context = ModelContext(modelContainer)
        guard let chatEntity = fetchChatEntity(id: chatID, context: context) else { return [] }
        return chatEntity.messages.sorted { $0.createdAt < $1.createdAt }.map { $0.toDomain() }
    }

    private func fetchChatEntity(id: Chat.ID, context: ModelContext) -> ChatEntity? {
        var descriptor = FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
