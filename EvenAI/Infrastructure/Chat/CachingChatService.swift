import Foundation
import SwiftData

/// Decorator over any `ChatServicing` — Phase 3.9 — that adds a local
/// SwiftData cache on top, reusing the exact same `ChatEntity`/
/// `MessageEntity` schema `MockChatService` already established (see
/// `PersistenceController`), not a second parallel one.
///
/// **Reads** go to the wrapped service first (it's the source of truth —
/// server-side chat data changes independently of this device), and on
/// success the result is written into the cache. Only on a *failed*
/// network call does this fall back to whatever's cached, so the app
/// stays usable — degraded, not broken — the moment connectivity drops,
/// which is exactly the gap `ROADMAP.md`'s "known gaps" section flagged
/// ("No local offline cache for the production path"). A pure
/// cache-first read isn't the right shape here: unlike, say, a news
/// feed, silently showing a minute-old chat list/history over a
/// perfectly good connection would hide real changes (a message sent
/// from another device, a rename) behind stale local data.
///
/// **Writes** (create/rename/delete, plus each message a stream
/// produces) are write-through: applied to the wrapped service first,
/// and only mirrored into the cache once that succeeds — so the cache
/// never claims a write happened when it didn't.
///
/// Conforms to `ChatServicing` like any other implementation — nothing
/// above `AppContainer` needs to know this wraps anything at all.
actor CachingChatService: ChatServicing {
    private let wrapped: ChatServicing
    private let modelContainer: ModelContainer

    init(wrapping service: ChatServicing, modelContainer: ModelContainer = PersistenceController.shared) {
        self.wrapped = service
        self.modelContainer = modelContainer
    }

    // MARK: - Reads (network-first, cache fallback)

    func fetchChats() async throws -> [Chat] {
        do {
            let chats = try await wrapped.fetchChats()
            cacheChatList(chats)
            return chats
        } catch {
            let cached = cachedChatList()
            if !cached.isEmpty {
                AppLogger.chat.notice("fetchChats: network failed, serving \(cached.count, privacy: .public) cached chat(s)")
                return cached
            }
            throw error
        }
    }

    func fetchChat(id: Chat.ID) async throws -> Chat {
        do {
            let chat = try await wrapped.fetchChat(id: id)
            cacheChat(chat)
            return chat
        } catch {
            if let cached = cachedChat(id: id) {
                AppLogger.chat.notice("fetchChat: network failed, serving cached copy of \(id, privacy: .public)")
                return cached
            }
            throw error
        }
    }

    func fetchMessages(chatID: Chat.ID) async throws -> [Message] {
        do {
            let messages = try await wrapped.fetchMessages(chatID: chatID)
            cacheMessages(messages, chatID: chatID)
            return messages
        } catch {
            let cached = cachedMessages(chatID: chatID)
            if !cached.isEmpty {
                AppLogger.chat.notice("fetchMessages: network failed, serving \(cached.count, privacy: .public) cached message(s)")
                return cached
            }
            throw error
        }
    }

    // MARK: - Writes (write-through)

    func createChat(title: String) async throws -> Chat {
        let chat = try await wrapped.createChat(title: title)
        cacheChat(chat)
        return chat
    }

    func renameChat(id: Chat.ID, title: String) async throws -> Chat {
        let chat = try await wrapped.renameChat(id: id, title: title)
        cacheChat(chat)
        return chat
    }

    func deleteChat(id: Chat.ID) async throws {
        try await wrapped.deleteChat(id: id)
        removeCachedChat(id: id)
    }

    nonisolated func streamReply(chatID: Chat.ID, content: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in wrapped.streamReply(chatID: chatID, content: content) {
                        // Only the two "saved" events represent something
                        // durable — assistantDelta is transient UI state,
                        // never a cache write of its own (it would just
                        // mean re-caching the whole growing string on
                        // every token for no benefit: the final
                        // assistantMessageSaved already captures the
                        // complete message).
                        switch event {
                        case .userMessageSaved(let message), .assistantMessageSaved(let message):
                            await self.cacheMessageWriteThrough(message)
                        case .assistantDelta:
                            break
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Invalidation

    /// Wipes every cached chat and message. Called from `AuthState` at
    /// the four moments Phase 3.9 calls out: logout (this device's cache
    /// belonged to an identity that's no longer signed in), an explicit
    /// account switch (same reason), a merge (the *set* of chats this
    /// account owns just changed server-side, cached data no longer
    /// reflects reality), and a silent session-recovery fallback (the
    /// identity changed without any explicit call). Simple and correct
    /// beats partial invalidation here — this cache exists purely as an
    /// offline-fallback convenience, not a source of truth, so a full
    /// wipe just means the next successful fetch repopulates it, same as
    /// a cold start.
    func invalidate() {
        let context = ModelContext(modelContainer)
        do {
            // Individually, not context.delete(model:) — SwiftData's
            // batch-delete API bypasses normal relationship processing
            // and, empirically (confirmed by this cache's own tests),
            // throws "mandatory OTO nullify inverse" against this
            // schema's cascade relationship. Deleting each `ChatEntity`
            // one at a time lets `deleteRule: .cascade` (see
            // `ChatEntity.messages`) remove its messages the normal way
            // — the same mechanism `removeCachedChat`/`MockChatService`
            // already rely on for a single chat, just for all of them.
            for chat in try context.fetch(FetchDescriptor<ChatEntity>()) {
                context.delete(chat)
            }
            try context.save()
            AppLogger.chat.notice("Chat cache invalidated")
        } catch {
            AppLogger.chat.error("Failed to invalidate chat cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Cache reads

    private func cachedChatList() -> [Chat] {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<ChatEntity>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return (try? context.fetch(descriptor))?.map { $0.toDomain() } ?? []
    }

    private func cachedChat(id: Chat.ID) -> Chat? {
        fetchChatEntity(id: id, context: ModelContext(modelContainer))?.toDomain()
    }

    private func cachedMessages(chatID: Chat.ID) -> [Message] {
        let context = ModelContext(modelContainer)
        guard let entity = fetchChatEntity(id: chatID, context: context) else { return [] }
        return entity.messages.sorted { $0.createdAt < $1.createdAt }.map { $0.toDomain() }
    }

    // MARK: - Cache writes

    // One shared context and one save for the whole list — fetchChats()
    // returns every chat the account has at once, and caching each one
    // through its own cacheChat() call (its own ModelContext, its own
    // disk-flushing save()) would mean a chat list of any real size did
    // that many times over for no benefit, since they're all part of the
    // same logical "the list just came back from the network" update.
    private func cacheChatList(_ chats: [Chat]) {
        let context = ModelContext(modelContainer)
        for chat in chats {
            let entity = fetchChatEntity(id: chat.id, context: context) ?? {
                let new = ChatEntity(id: chat.id, title: chat.title, createdAt: chat.createdAt)
                context.insert(new)
                return new
            }()
            entity.title = chat.title
            entity.updatedAt = chat.updatedAt
            entity.lastMessagePreview = chat.lastMessagePreview
        }
        try? context.save()
    }

    private func cacheChat(_ chat: Chat) {
        let context = ModelContext(modelContainer)
        let entity = fetchChatEntity(id: chat.id, context: context) ?? {
            let new = ChatEntity(id: chat.id, title: chat.title, createdAt: chat.createdAt)
            context.insert(new)
            return new
        }()
        entity.title = chat.title
        entity.updatedAt = chat.updatedAt
        entity.lastMessagePreview = chat.lastMessagePreview
        try? context.save()
    }

    private func removeCachedChat(id: Chat.ID) {
        let context = ModelContext(modelContainer)
        guard let entity = fetchChatEntity(id: id, context: context) else { return }
        context.delete(entity)
        try? context.save()
    }

    private func cacheMessages(_ messages: [Message], chatID: Chat.ID) {
        let context = ModelContext(modelContainer)
        guard let chatEntity = fetchChatEntity(id: chatID, context: context) else { return }
        for message in messages {
            upsertMessage(message, chatEntity: chatEntity, context: context)
        }
        try? context.save()
    }

    private func cacheMessageWriteThrough(_ message: Message) {
        let context = ModelContext(modelContainer)
        guard let chatEntity = fetchChatEntity(id: message.chatID, context: context) else {
            // The chat itself was never cached (e.g. fetchChats() has
            // never succeeded on this device) — nothing meaningful to
            // attach this message to yet. The next successful
            // fetchChat(s)/fetchMessages() call will backfill it anyway.
            return
        }
        upsertMessage(message, chatEntity: chatEntity, context: context)
        chatEntity.updatedAt = message.createdAt
        chatEntity.lastMessagePreview = message.content
        try? context.save()
    }

    private func upsertMessage(_ message: Message, chatEntity: ChatEntity, context: ModelContext) {
        var descriptor = FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.id == message.id })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            existing.content = message.content
            existing.status = message.status
        } else {
            let entity = MessageEntity(
                id: message.id,
                role: message.role,
                content: message.content,
                createdAt: message.createdAt,
                status: message.status,
                chat: chatEntity
            )
            context.insert(entity)
            chatEntity.messages.append(entity)
        }
    }

    private func fetchChatEntity(id: Chat.ID, context: ModelContext) -> ChatEntity? {
        var descriptor = FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
