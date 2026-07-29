import Foundation

/// Real backend-backed implementation of `ChatServicing`, talking to the
/// Even AI chat API via the shared `AuthenticatedAPIClient` — no direct
/// `URLSession` use anywhere in this file (Phase 3.5): token attachment,
/// automatic refresh-on-401, retry, and offline/HTTP error classification
/// are all the client's job, not this service's. Drop-in replacement for
/// `MockChatService` — `AppContainer.live` is the only place that needs
/// to know which one is in use.
///
/// Authentication is invisible from here up: every method below just
/// calls `apiClient.get/post/patch/delete` and lets whatever it throws
/// propagate — `ChatViewModel`/`ChatListViewModel`'s existing generic
/// error handling (from Milestone 2) already treats "any thrown error"
/// as a graceful failure, so a session that transparently refreshed, or
/// even fell back to an anonymous one, looks identical to a request that
/// never needed to from this service's callers.
actor NetworkChatService: ChatServicing {
    private let apiClient: AuthenticatedAPIClient

    init(apiClient: AuthenticatedAPIClient) {
        self.apiClient = apiClient
    }

    func fetchChats() async throws -> [Chat] {
        let data = try await apiClient.get("chats")
        return try JSONDecoder.evenAI.decode(ChatsResponseDTO.self, from: data).chats.map { $0.toDomain() }
    }

    func fetchChat(id: Chat.ID) async throws -> Chat {
        let data = try await apiClient.get("chats/\(id.uuidString)")
        return try JSONDecoder.evenAI.decode(ChatDTO.self, from: data).toDomain()
    }

    func createChat(title: String) async throws -> Chat {
        let body = try JSONEncoder.evenAI.encode(["title": title])
        let data = try await apiClient.post("chats", body: body)
        return try JSONDecoder.evenAI.decode(ChatDTO.self, from: data).toDomain()
    }

    func renameChat(id: Chat.ID, title: String) async throws -> Chat {
        let body = try JSONEncoder.evenAI.encode(["title": title])
        let data = try await apiClient.patch("chats/\(id.uuidString)", body: body)
        return try JSONDecoder.evenAI.decode(ChatDTO.self, from: data).toDomain()
    }

    func deleteChat(id: Chat.ID) async throws {
        try await apiClient.delete("chats/\(id.uuidString)")
    }

    func fetchMessages(chatID: Chat.ID) async throws -> [Message] {
        let data = try await apiClient.get("chats/\(chatID.uuidString)/messages")
        return try JSONDecoder.evenAI.decode(MessagesResponseDTO.self, from: data).messages.map { $0.toDomain() }
    }

    nonisolated func streamReply(chatID: Chat.ID, content: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.performStream(chatID: chatID, content: content, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Streaming

    // Unchanged from Milestone 2 except for how the byte stream itself is
    // obtained (apiClient.streamBytes instead of session.bytes directly)
    // — the SSE line-parsing (event:/data: framing, heartbeat comments)
    // is a chat-specific concern that stays here, not something the
    // generic transport client should know about.
    private func performStream(
        chatID: Chat.ID,
        content: String,
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws {
        let body = try JSONEncoder.evenAI.encode(["chatId": chatID.uuidString, "content": content])
        let (bytes, _) = try await apiClient.streamBytes(path: "chat/stream", body: body)

        var eventName: String?
        var dataLines: [String] = []

        func flush() throws {
            guard let eventName, !dataLines.isEmpty else { return }
            try Self.handle(eventName: eventName, payload: dataLines.joined(separator: "\n"), continuation: continuation)
            dataLines.removeAll()
        }

        for try await line in bytes.lines {
            if line.isEmpty {
                try flush()
                eventName = nil
            } else if line.hasPrefix(":") {
                continue // comment / heartbeat
            } else if line.hasPrefix("event:") {
                eventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces))
            }
        }
        try flush()
    }

    private static func handle(
        eventName: String,
        payload: String,
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) throws {
        guard let payloadData = payload.data(using: .utf8) else { return }
        switch eventName {
        case "start":
            let decoded = try JSONDecoder.evenAI.decode(StreamStartPayloadDTO.self, from: payloadData)
            continuation.yield(.userMessageSaved(decoded.userMessage.toDomain()))
        case "delta":
            let decoded = try JSONDecoder.evenAI.decode(StreamDeltaPayloadDTO.self, from: payloadData)
            continuation.yield(.assistantDelta(decoded.content))
        case "done":
            let decoded = try JSONDecoder.evenAI.decode(StreamDonePayloadDTO.self, from: payloadData)
            continuation.yield(.assistantMessageSaved(decoded.message.toDomain()))
        case "error":
            let decoded = try? JSONDecoder.evenAI.decode(StreamErrorPayloadDTO.self, from: payloadData)
            throw NetworkChatServiceError.server(decoded?.error.message ?? "Unknown streaming error.")
        default:
            break
        }
    }
}

/// The one chat-specific error case left: a business-level failure
/// reported *inside* an already-open SSE stream (e.g. the backend's
/// upstream LLM call failed). Transport-level failures (offline, HTTP
/// status, session expiry) are `AuthenticatedAPIClientError` and
/// propagate directly — wrapping them here would just be redundant.
enum NetworkChatServiceError: Error, Sendable, LocalizedError {
    case server(String)

    var errorDescription: String? {
        switch self {
        case .server(let message): message
        }
    }
}
