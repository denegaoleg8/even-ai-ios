import Foundation

/// Real backend-backed implementation of `ChatServicing`, talking to the
/// Even AI chat API over HTTPS (REST) and SSE (streaming replies). Drop-in
/// replacement for `MockChatService` — `AppContainer.live` is the only
/// place that needs to know which one is in use.
actor NetworkChatService: ChatServicing {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = BackendConfiguration.baseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func fetchChats() async throws -> [Chat] {
        let data = try await get("chats")
        return try JSONDecoder.evenAI.decode(ChatsResponseDTO.self, from: data).chats.map { $0.toDomain() }
    }

    func fetchChat(id: Chat.ID) async throws -> Chat {
        let data = try await get("chats/\(id.uuidString)")
        return try JSONDecoder.evenAI.decode(ChatDTO.self, from: data).toDomain()
    }

    func createChat(title: String) async throws -> Chat {
        let body = try JSONEncoder.evenAI.encode(["title": title])
        let data = try await post("chats", body: body)
        return try JSONDecoder.evenAI.decode(ChatDTO.self, from: data).toDomain()
    }

    func renameChat(id: Chat.ID, title: String) async throws -> Chat {
        let body = try JSONEncoder.evenAI.encode(["title": title])
        let data = try await patch("chats/\(id.uuidString)", body: body)
        return try JSONDecoder.evenAI.decode(ChatDTO.self, from: data).toDomain()
    }

    func deleteChat(id: Chat.ID) async throws {
        try await delete("chats/\(id.uuidString)")
    }

    func fetchMessages(chatID: Chat.ID) async throws -> [Message] {
        let data = try await get("chats/\(chatID.uuidString)/messages")
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

    private func performStream(
        chatID: Chat.ID,
        content: String,
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws {
        var request = URLRequest(url: baseURL.appending(path: "chat/stream"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder.evenAI.encode(["chatId": chatID.uuidString, "content": content])

        let (bytes, response) = try await session.bytes(for: request)
        try Self.validate(response)

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

    // MARK: - REST helpers

    private func get(_ path: String) async throws -> Data {
        try await send(path: path, method: "GET", body: nil)
    }

    private func post(_ path: String, body: Data) async throws -> Data {
        try await send(path: path, method: "POST", body: body)
    }

    private func patch(_ path: String, body: Data) async throws -> Data {
        try await send(path: path, method: "PATCH", body: body)
    }

    @discardableResult
    private func delete(_ path: String) async throws -> Data {
        try await send(path: path, method: "DELETE", body: nil)
    }

    private func send(path: String, method: String, body: Data?) async throws -> Data {
        var mutableRequest = URLRequest(url: baseURL.appending(path: path))
        mutableRequest.httpMethod = method
        if let body {
            mutableRequest.httpBody = body
            mutableRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let request = mutableRequest

        let (data, response) = try await withRetry {
            try await session.data(for: request)
        }
        try Self.validate(response)
        return data
    }

    private func withRetry<T: Sendable>(
        attempts: Int = 2,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: Error = NetworkChatServiceError.invalidResponse
        for attempt in 0..<attempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                if attempt < attempts - 1 {
                    try? await Task.sleep(for: .milliseconds(300 * (attempt + 1)))
                }
            }
        }
        throw lastError
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw NetworkChatServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NetworkChatServiceError.http(status: http.statusCode)
        }
    }
}

enum NetworkChatServiceError: Error, Sendable, LocalizedError {
    case invalidResponse
    case http(status: Int)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The server returned an unexpected response."
        case .http(let status): "The server returned an error (HTTP \(status))."
        case .server(let message): message
        }
    }
}
