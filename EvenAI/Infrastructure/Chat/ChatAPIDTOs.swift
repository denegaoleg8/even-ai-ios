import Foundation

/// Wire-format DTOs for the Even AI chat API, kept separate from the
/// `Chat`/`Message` domain structs so JSON key casing (`chatId`, not
/// `chatID`) never leaks into the domain layer — the same separation
/// `ChatEntity`/`MessageEntity` already draw for SwiftData.

struct ChatDTO: Decodable {
    let id: UUID
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let lastMessagePreview: String?

    func toDomain() -> Chat {
        Chat(id: id, title: title, createdAt: createdAt, updatedAt: updatedAt, lastMessagePreview: lastMessagePreview)
    }
}

struct ChatsResponseDTO: Decodable {
    let chats: [ChatDTO]
}

struct MessageDTO: Decodable {
    let id: UUID
    let chatId: UUID
    let role: MessageRole
    let content: String
    let createdAt: Date
    let status: MessageStatus

    func toDomain() -> Message {
        Message(id: id, chatID: chatId, role: role, content: content, createdAt: createdAt, status: status)
    }
}

struct MessagesResponseDTO: Decodable {
    let messages: [MessageDTO]
}

struct StreamStartPayloadDTO: Decodable {
    let userMessage: MessageDTO
}

struct StreamDeltaPayloadDTO: Decodable {
    let content: String
}

struct StreamDonePayloadDTO: Decodable {
    let message: MessageDTO
}

struct StreamErrorPayloadDTO: Decodable {
    struct ErrorBody: Decodable {
        let code: String
        let message: String
    }
    let error: ErrorBody
}

extension JSONDecoder {
    /// Backend emits `Date.toISOString()`, which includes fractional
    /// seconds — the plain `.iso8601` strategy can't parse that, so this
    /// tries with fractional seconds first and falls back without.
    static let evenAI: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)

            // Built fresh per call rather than captured, since
            // ISO8601DateFormatter isn't Sendable and this closure runs
            // as `@Sendable` — no shared mutable state this way.
            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFractional.date(from: string) { return date }

            let withoutFractional = ISO8601DateFormatter()
            withoutFractional.formatOptions = [.withInternetDateTime]
            if let date = withoutFractional.date(from: string) { return date }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(string)")
        }
        return decoder
    }()
}

extension JSONEncoder {
    static let evenAI: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
