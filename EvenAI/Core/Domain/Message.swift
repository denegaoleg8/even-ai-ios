import Foundation

/// Domain-level message model. Mirrors the `message` object in the Even AI
/// API specification.
struct Message: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var chatID: Chat.ID
    var role: MessageRole
    var content: String
    var createdAt: Date
    var status: MessageStatus

    init(
        id: UUID = UUID(),
        chatID: Chat.ID,
        role: MessageRole,
        content: String,
        createdAt: Date = .now,
        status: MessageStatus = .complete
    ) {
        self.id = id
        self.chatID = chatID
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.status = status
    }
}
