import Foundation

/// Abstraction over chat persistence/networking. `NetworkChatService` is the
/// live implementation, talking to the real backend (see the Even AI API
/// specification's `/api/chats` and `/api/chat/stream` endpoints);
/// `MockChatService` is a SwiftData-backed placeholder that simulates
/// streaming AI replies, used by tests and previews.
protocol ChatServicing: Sendable {
    func fetchChats() async throws -> [Chat]
    func fetchChat(id: Chat.ID) async throws -> Chat
    func createChat(title: String) async throws -> Chat
    func renameChat(id: Chat.ID, title: String) async throws -> Chat
    func deleteChat(id: Chat.ID) async throws
    func fetchMessages(chatID: Chat.ID) async throws -> [Message]
    func streamReply(chatID: Chat.ID, content: String) -> AsyncThrowingStream<ChatStreamEvent, Error>
    /// Persists one message directly, with no AI reply triggered — unlike
    /// `streamReply(chatID:content:)`, which always provokes a completion.
    /// Added for "Glasses Chat" (Live Translation turns are real,
    /// persisted conversation entries, but a translated phrase must never
    /// itself cost a chat-completion call).
    func appendMessage(chatID: Chat.ID, role: MessageRole, content: String) async throws -> Message
}
