import Foundation

/// Abstraction over chat persistence/networking. `MockChatService` is a
/// SwiftData-backed placeholder that simulates streaming AI replies;
/// replaced by a real networked implementation once the backend
/// integration phase begins (see the Even AI API specification's
/// `/api/chats` and `/api/chat/stream` endpoints).
protocol ChatServicing: Sendable {
    func fetchChats() async throws -> [Chat]
    func fetchChat(id: Chat.ID) async throws -> Chat
    func createChat(title: String) async throws -> Chat
    func renameChat(id: Chat.ID, title: String) async throws -> Chat
    func deleteChat(id: Chat.ID) async throws
    func fetchMessages(chatID: Chat.ID) async throws -> [Message]
    func streamReply(chatID: Chat.ID, content: String) -> AsyncThrowingStream<ChatStreamEvent, Error>
}
