import Foundation

/// Domain-level chat model. Mirrors the `chat` object in the Even AI API
/// specification. Intentionally a plain, `Sendable` value type — persistence
/// (SwiftData) and transport (networking) each map to and from this type
/// rather than exposing their own models to the rest of the app.
struct Chat: Identifiable, Codable, Hashable, Sendable {
    static let defaultTitle = "New Chat"

    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var lastMessagePreview: String?

    init(
        id: UUID = UUID(),
        title: String = Chat.defaultTitle,
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
