import Foundation
import SwiftData

/// SwiftData-backed mirror of `Message`. See `ChatEntity`.
@Model
final class MessageEntity {
    @Attribute(.unique) var id: UUID
    var role: MessageRole
    var content: String
    var createdAt: Date
    var status: MessageStatus
    var chat: ChatEntity?

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        createdAt: Date = .now,
        status: MessageStatus = .complete,
        chat: ChatEntity? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.status = status
        self.chat = chat
    }
}

extension MessageEntity {
    func toDomain() -> Message {
        Message(
            id: id,
            chatID: chat?.id ?? UUID(),
            role: role,
            content: content,
            createdAt: createdAt,
            status: status
        )
    }
}
