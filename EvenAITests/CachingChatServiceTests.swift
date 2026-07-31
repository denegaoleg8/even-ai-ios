import Testing
import Foundation
import SwiftData
@testable import EvenAI

@Suite("CachingChatService")
struct CachingChatServiceTests {
    private func makeInMemoryContainer() -> ModelContainer {
        let schema = Schema([ChatEntity.self, MessageEntity.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: [configuration])
    }

    @Test("a successful fetchChats writes through to the cache, readable by a later offline instance")
    func fetchChatsCachesOnSuccess() async throws {
        let container = makeInMemoryContainer()
        let knownChat = Chat(title: "Cached chat")
        let online = CachingChatService(wrapping: StubChatService(chats: [knownChat]), modelContainer: container)

        let fetched = try await online.fetchChats()
        #expect(fetched.map(\.id) == [knownChat.id])

        // A second instance sharing the same store, wrapping a service
        // that always fails, proves the first call's write-through is
        // what makes this readable — not coincidence or shared state in
        // the double itself.
        let offline = CachingChatService(wrapping: FailingChatService(), modelContainer: container)
        let cached = try await offline.fetchChats()
        #expect(cached.map(\.id) == [knownChat.id])
    }

    @Test("fetchChats falls back to the cache when the network fails, instead of throwing")
    func fetchChatsFallsBackOnFailure() async throws {
        let container = makeInMemoryContainer()
        let knownChat = Chat(title: "Offline-visible chat")
        let online = CachingChatService(wrapping: StubChatService(chats: [knownChat]), modelContainer: container)
        _ = try await online.fetchChats()

        let offline = CachingChatService(wrapping: FailingChatService(), modelContainer: container)
        let result = try await offline.fetchChats()
        #expect(result.map(\.id) == [knownChat.id])
    }

    @Test("fetchChats still throws when the network fails and nothing is cached — never silently empty")
    func fetchChatsThrowsWithEmptyCache() async {
        let container = makeInMemoryContainer()
        let service = CachingChatService(wrapping: FailingChatService(), modelContainer: container)
        await #expect(throws: FailingChatService.Failure.self) {
            try await service.fetchChats()
        }
    }

    @Test("createChat writes through to the cache immediately, not just on the next fetchChats")
    func createChatCachesImmediately() async throws {
        let container = makeInMemoryContainer()
        let service = CachingChatService(wrapping: EmptyChatService(), modelContainer: container)
        let created = try await service.createChat(title: "New chat")

        let offline = CachingChatService(wrapping: FailingChatService(), modelContainer: container)
        let cached = try await offline.fetchChats()
        #expect(cached.map(\.id) == [created.id])
    }

    @Test("renameChat updates the cached title")
    func renameChatUpdatesCache() async throws {
        let container = makeInMemoryContainer()
        let chat = Chat(title: "Original")
        let service = CachingChatService(wrapping: StubChatService(chats: [chat]), modelContainer: container)
        _ = try await service.fetchChats()
        _ = try await service.renameChat(id: chat.id, title: "Renamed")

        let offline = CachingChatService(wrapping: FailingChatService(), modelContainer: container)
        let cached = try await offline.fetchChats()
        #expect(cached.first?.title == "Renamed")
    }

    @Test("deleteChat removes the cached copy too")
    func deleteChatRemovesFromCache() async throws {
        let container = makeInMemoryContainer()
        let chat = Chat(title: "Will be deleted")
        let service = CachingChatService(wrapping: StubChatService(chats: [chat]), modelContainer: container)
        _ = try await service.fetchChats()
        try await service.deleteChat(id: chat.id)

        // An empty cache plus a failed network means fetchChats() throws
        // rather than silently returning [] (see
        // fetchChatsThrowsWithEmptyCache) — so the *absence* of a
        // fallback here is exactly what proves the cache no longer has
        // this chat. If delete had failed to clear it, this would
        // succeed and return the stale entry instead of throwing.
        let offline = CachingChatService(wrapping: FailingChatService(), modelContainer: container)
        await #expect(throws: FailingChatService.Failure.self) {
            try await offline.fetchChats()
        }
    }

    @Test("fetchMessages falls back to cached messages when the network fails")
    func fetchMessagesFallsBackOnFailure() async throws {
        let container = makeInMemoryContainer()
        let chat = Chat(title: "Has messages")
        let message = Message(chatID: chat.id, role: .user, content: "hello")
        let online = CachingChatService(
            wrapping: StubChatService(chats: [chat], messages: [message]),
            modelContainer: container
        )
        _ = try await online.fetchChats()
        _ = try await online.fetchMessages(chatID: chat.id)

        let offline = CachingChatService(wrapping: FailingChatService(), modelContainer: container)
        let cachedMessages = try await offline.fetchMessages(chatID: chat.id)
        #expect(cachedMessages.map(\.id) == [message.id])
    }

    @Test("streamReply caches the saved user and assistant messages, never the transient deltas")
    func streamReplyCachesSavedMessagesOnly() async throws {
        let container = makeInMemoryContainer()
        let chat = Chat(title: "Streaming chat")
        let userMessage = Message(chatID: chat.id, role: .user, content: "hi")
        let assistantMessage = Message(chatID: chat.id, role: .assistant, content: "hello")
        let scripted = ScriptedStreamChatService(events: [
            .userMessageSaved(userMessage),
            .assistantDelta("hel"),
            .assistantDelta("lo"),
            .assistantMessageSaved(assistantMessage),
        ])
        let service = CachingChatService(wrapping: StubChatService(chats: [chat]), modelContainer: container)
        _ = try await service.fetchChats() // cache the chat itself first

        let streamingService = CachingChatService(wrapping: scripted, modelContainer: container)
        for try await _ in streamingService.streamReply(chatID: chat.id, content: "hi") {}

        let offline = CachingChatService(wrapping: FailingChatService(), modelContainer: container)
        let cachedMessages = try await offline.fetchMessages(chatID: chat.id)
        #expect(Set(cachedMessages.map(\.id)) == Set([userMessage.id, assistantMessage.id]))
        // Neither delta ever became its own message, and the assistant
        // message's cached content is the final text, not a fragment.
        #expect(cachedMessages.first { $0.id == assistantMessage.id }?.content == "hello")
    }

    @Test("invalidate wipes every cached chat and message")
    func invalidateClearsEverything() async throws {
        let container = makeInMemoryContainer()
        let chat = Chat(title: "Will be invalidated")
        let message = Message(chatID: chat.id, role: .user, content: "hi")
        let service = CachingChatService(
            wrapping: StubChatService(chats: [chat], messages: [message]),
            modelContainer: container
        )
        _ = try await service.fetchChats()
        _ = try await service.fetchMessages(chatID: chat.id)

        await service.invalidate()

        let offline = CachingChatService(wrapping: FailingChatService(), modelContainer: container)
        await #expect(throws: FailingChatService.Failure.self) {
            try await offline.fetchChats()
        }
    }
}
