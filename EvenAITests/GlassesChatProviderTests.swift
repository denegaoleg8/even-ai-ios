import Testing
import Foundation
@testable import EvenAI

/// `GlassesChatProvider` finds or lazily creates the one persistent
/// "Glasses Chat" conversation — identity is a `Chat.ID` persisted in
/// `UserDefaults`, not the chat's title (see the type's own doc comment
/// for why title matching was explicitly avoided). A fresh, uniquely-named
/// `UserDefaults(suiteName:)` per test keeps these fully isolated from
/// both each other and the real app's defaults.
@MainActor
@Suite("GlassesChatProvider")
struct GlassesChatProviderTests {
    private func freshDefaults() -> UserDefaults {
        let suiteName = "GlassesChatProviderTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }

    @Test("no persisted id yet: creates exactly one chat, titled 'Glasses Chat'")
    func createsOnFirstUse() async throws {
        let service = RecordingChatService()
        let provider = GlassesChatProvider(chatService: service, defaults: freshDefaults())

        let chat = try await provider.findOrCreateGlassesChat()

        #expect(chat.title == GlassesChatProvider.displayTitle)
        #expect(await service.createChatCalls == [GlassesChatProvider.displayTitle])
        #expect(await service.fetchChatCalls.isEmpty) // nothing to fetch yet
    }

    @Test("a persisted id that still resolves is reused — no new chat is created")
    func reusesPersistedID() async throws {
        let existing = Chat(title: "Glasses Chat")
        let service = RecordingChatService(existingChats: [existing])
        let defaults = freshDefaults()
        defaults.set(existing.id.uuidString, forKey: "com.evenai.glassesChatID")
        let provider = GlassesChatProvider(chatService: service, defaults: defaults)

        let chat = try await provider.findOrCreateGlassesChat()

        #expect(chat.id == existing.id)
        #expect(await service.createChatCalls.isEmpty)
        #expect(await service.fetchChatCalls == [existing.id])
    }

    @Test("calling twice never creates a second chat — the second call reuses the in-memory cached result")
    func secondCallReusesCachedResult() async throws {
        let service = RecordingChatService()
        let provider = GlassesChatProvider(chatService: service, defaults: freshDefaults())

        let first = try await provider.findOrCreateGlassesChat()
        let second = try await provider.findOrCreateGlassesChat()

        #expect(first.id == second.id)
        #expect(await service.createChatCalls.count == 1)
    }

    @Test("two concurrent callers, before anything is cached, still create only one chat")
    func concurrentCallersCreateOnlyOneChat() async throws {
        let service = RecordingChatService(artificialDelay: .milliseconds(30))
        let provider = GlassesChatProvider(chatService: service, defaults: freshDefaults())

        async let first = provider.findOrCreateGlassesChat()
        async let second = provider.findOrCreateGlassesChat()
        let (chatA, chatB) = try await (first, second)

        #expect(chatA.id == chatB.id)
        #expect(await service.createChatCalls.count == 1)
    }

    @Test("a persisted id that no longer resolves (deleted, or a different account) self-heals by creating a fresh chat")
    func staleIDSelfHeals() async throws {
        let service = RecordingChatService() // no existing chats — any fetch 404s
        let defaults = freshDefaults()
        let staleID = UUID()
        defaults.set(staleID.uuidString, forKey: "com.evenai.glassesChatID")
        let provider = GlassesChatProvider(chatService: service, defaults: defaults)

        let chat = try await provider.findOrCreateGlassesChat()

        #expect(chat.id != staleID)
        #expect(await service.fetchChatCalls == [staleID])
        #expect(await service.createChatCalls == [GlassesChatProvider.displayTitle])
    }

    @Test("invalidateCache() forces the next call to re-resolve rather than reusing the in-memory result")
    func invalidateCacheForcesReResolution() async throws {
        let service = RecordingChatService()
        let provider = GlassesChatProvider(chatService: service, defaults: freshDefaults())

        let first = try await provider.findOrCreateGlassesChat()
        provider.invalidateCache()
        // The persisted id still resolves (freshDefaults wasn't cleared),
        // so this is a REUSE via fetchChat, not a second createChat call.
        let second = try await provider.findOrCreateGlassesChat()

        #expect(first.id == second.id)
        #expect(await service.createChatCalls.count == 1)
        #expect(await service.fetchChatCalls == [first.id])
    }
}

/// Records every `createChat`/`fetchChat` call, in order, and can seed
/// `fetchChat` with a known set of already-"existing" chats — everything
/// else throws, matching a real backend's 404-for-unknown-id behavior.
private actor RecordingChatService: ChatServicing {
    private(set) var createChatCalls: [String] = []
    private(set) var fetchChatCalls: [Chat.ID] = []
    private var chatsByID: [Chat.ID: Chat]
    private let artificialDelay: Duration

    struct NotFound: Error {}

    init(existingChats: [Chat] = [], artificialDelay: Duration = .zero) {
        chatsByID = Dictionary(uniqueKeysWithValues: existingChats.map { ($0.id, $0) })
        self.artificialDelay = artificialDelay
    }

    func fetchChats() async throws -> [Chat] { Array(chatsByID.values) }

    func fetchChat(id: Chat.ID) async throws -> Chat {
        fetchChatCalls.append(id)
        guard let chat = chatsByID[id] else { throw NotFound() }
        return chat
    }

    func createChat(title: String) async throws -> Chat {
        if artificialDelay > .zero { try? await Task.sleep(for: artificialDelay) }
        createChatCalls.append(title)
        let chat = Chat(title: title)
        chatsByID[chat.id] = chat
        return chat
    }

    func renameChat(id: Chat.ID, title: String) async throws -> Chat { Chat(id: id, title: title) }
    func deleteChat(id: Chat.ID) async throws { chatsByID[id] = nil }
    func fetchMessages(chatID: Chat.ID) async throws -> [Message] { [] }
    func appendMessage(chatID: Chat.ID, role: MessageRole, content: String) async throws -> Message {
        Message(chatID: chatID, role: role, content: content)
    }

    nonisolated func streamReply(chatID: Chat.ID, content: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
