import Foundation
import SwiftData

/// SwiftData-backed mirror of `Chat`. This is the persistence layer's
/// source of truth — `MockChatService` reads and writes these directly and
/// maps to/from the `Chat` domain struct via `toDomain()`.
@Model
final class ChatEntity {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var lastMessagePreview: String?

    @Relationship(deleteRule: .cascade, inverse: \MessageEntity.chat)
    var messages: [MessageEntity] = []

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastMessagePreview: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastMessagePreview = lastMessagePreview
    }
}

extension ChatEntity {
    func toDomain() -> Chat {
        Chat(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastMessagePreview: lastMessagePreview
        )
    }
}
