import Foundation
@testable import EvenAI

/// Every call fails — simulates a completely unreachable backend.
actor FailingChatService: ChatServicing {
    struct Failure: Error, Sendable {}

    func fetchChats() async throws -> [Chat] { throw Failure() }
    func fetchChat(id: Chat.ID) async throws -> Chat { throw Failure() }
    func createChat(title: String) async throws -> Chat { throw Failure() }
    func renameChat(id: Chat.ID, title: String) async throws -> Chat { throw Failure() }
    func deleteChat(id: Chat.ID) async throws { throw Failure() }
    func fetchMessages(chatID: Chat.ID) async throws -> [Message] { throw Failure() }

    nonisolated func streamReply(chatID: Chat.ID, content: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: Failure())
        }
    }
}

/// Succeeds with genuinely empty results — the "no data yet" case, as
/// opposed to `FailingChatService`'s "couldn't reach the backend" case.
/// The two must be distinguishable by the view models.
actor EmptyChatService: ChatServicing {
    func fetchChats() async throws -> [Chat] { [] }
    func fetchChat(id: Chat.ID) async throws -> Chat { Chat(id: id) }
    func createChat(title: String) async throws -> Chat { Chat(title: title) }
    func renameChat(id: Chat.ID, title: String) async throws -> Chat { Chat(id: id, title: title) }
    func deleteChat(id: Chat.ID) async throws {}
    func fetchMessages(chatID: Chat.ID) async throws -> [Message] { [] }

    nonisolated func streamReply(chatID: Chat.ID, content: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

/// Everything succeeds except `deleteChat`, which always fails — used to
/// verify a failed delete doesn't remove the chat from local state.
actor DeleteFailingChatService: ChatServicing {
    struct Failure: Error, Sendable {}

    func fetchChats() async throws -> [Chat] { [] }
    func fetchChat(id: Chat.ID) async throws -> Chat { Chat(id: id) }
    func createChat(title: String) async throws -> Chat { Chat(title: title) }
    func renameChat(id: Chat.ID, title: String) async throws -> Chat { Chat(id: id, title: title) }
    func deleteChat(id: Chat.ID) async throws { throw Failure() }
    func fetchMessages(chatID: Chat.ID) async throws -> [Message] { [] }

    nonisolated func streamReply(chatID: Chat.ID, content: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Counts `createChat` calls and adds latency, so a test can verify a
/// reentrancy guard actually prevents two concurrent calls from both
/// succeeding.
actor CountingCreateChatService: ChatServicing {
    private(set) var createCallCount = 0

    func fetchChats() async throws -> [Chat] { [] }
    func fetchChat(id: Chat.ID) async throws -> Chat { Chat(id: id) }

    func createChat(title: String) async throws -> Chat {
        createCallCount += 1
        try? await Task.sleep(for: .milliseconds(50))
        return Chat(title: title)
    }

    func renameChat(id: Chat.ID, title: String) async throws -> Chat { Chat(id: id, title: title) }
    func deleteChat(id: Chat.ID) async throws {}
    func fetchMessages(chatID: Chat.ID) async throws -> [Message] { [] }

    nonisolated func streamReply(chatID: Chat.ID, content: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Returns a fixed, caller-supplied list of chats/messages — used by
/// `CachingChatServiceTests` to populate a cache with known content
/// before exercising fallback/write-through behavior.
actor StubChatService: ChatServicing {
    private let chats: [Chat]
    private let messages: [Message]

    init(chats: [Chat] = [], messages: [Message] = []) {
        self.chats = chats
        self.messages = messages
    }

    func fetchChats() async throws -> [Chat] { chats }

    func fetchChat(id: Chat.ID) async throws -> Chat {
        guard let chat = chats.first(where: { $0.id == id }) else { throw FailingChatService.Failure() }
        return chat
    }

    func createChat(title: String) async throws -> Chat { Chat(title: title) }
    func renameChat(id: Chat.ID, title: String) async throws -> Chat { Chat(id: id, title: title) }
    func deleteChat(id: Chat.ID) async throws {}
    func fetchMessages(chatID: Chat.ID) async throws -> [Message] { messages.filter { $0.chatID == chatID } }

    nonisolated func streamReply(chatID: Chat.ID, content: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Streams a caller-scripted sequence of events — lets a test control
/// exactly which `ChatStreamEvent`s `streamReply` produces, e.g. to
/// verify a decorator caches the "saved" events but not deltas.
actor ScriptedStreamChatService: ChatServicing {
    private let events: [ChatStreamEvent]

    init(events: [ChatStreamEvent]) {
        self.events = events
    }

    func fetchChats() async throws -> [Chat] { [] }
    func fetchChat(id: Chat.ID) async throws -> Chat { Chat(id: id) }
    func createChat(title: String) async throws -> Chat { Chat(title: title) }
    func renameChat(id: Chat.ID, title: String) async throws -> Chat { Chat(id: id, title: title) }
    func deleteChat(id: Chat.ID) async throws {}
    func fetchMessages(chatID: Chat.ID) async throws -> [Message] { [] }

    nonisolated func streamReply(chatID: Chat.ID, content: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// Streams a user message and one delta, then the connection drops before
/// the reply finishes — simulates a mid-stream network failure.
actor PartialStreamThenFailChatService: ChatServicing {
    struct Failure: Error, Sendable {}

    func fetchChats() async throws -> [Chat] { [] }
    func fetchChat(id: Chat.ID) async throws -> Chat { Chat(id: id) }
    func createChat(title: String) async throws -> Chat { Chat(title: title) }
    func renameChat(id: Chat.ID, title: String) async throws -> Chat { Chat(id: id, title: title) }
    func deleteChat(id: Chat.ID) async throws {}
    func fetchMessages(chatID: Chat.ID) async throws -> [Message] { [] }

    nonisolated func streamReply(chatID: Chat.ID, content: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let userMessage = Message(chatID: chatID, role: .user, content: content)
            continuation.yield(.userMessageSaved(userMessage))
            continuation.yield(.assistantDelta("Partial"))
            continuation.finish(throwing: Failure())
        }
    }
}
