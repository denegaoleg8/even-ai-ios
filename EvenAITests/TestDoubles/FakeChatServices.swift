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
