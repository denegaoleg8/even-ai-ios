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
        let data = try await apiClient.get("chats/\(id.lowercaseUUIDString)")
        return try JSONDecoder.evenAI.decode(ChatDTO.self, from: data).toDomain()
    }

    func createChat(title: String) async throws -> Chat {
        let body = try JSONEncoder.evenAI.encode(["title": title])
        let data = try await apiClient.post("chats", body: body)
        return try JSONDecoder.evenAI.decode(ChatDTO.self, from: data).toDomain()
    }

    func renameChat(id: Chat.ID, title: String) async throws -> Chat {
        let body = try JSONEncoder.evenAI.encode(["title": title])
        let data = try await apiClient.patch("chats/\(id.lowercaseUUIDString)", body: body)
        return try JSONDecoder.evenAI.decode(ChatDTO.self, from: data).toDomain()
    }

    func deleteChat(id: Chat.ID) async throws {
        try await apiClient.delete("chats/\(id.lowercaseUUIDString)")
    }

    func fetchMessages(chatID: Chat.ID) async throws -> [Message] {
        let data = try await apiClient.get("chats/\(chatID.lowercaseUUIDString)/messages")
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

    // Deliberately NOT `bytes.lines` (Foundation's `AsyncLineSequence`,
    // built on top of the same raw `AsyncBytes` iterated manually below).
    // Empirically confirmed — via a real `URLSession`/`AsyncBytes` round
    // trip, not just code inspection — that `.lines` unconditionally
    // drops every blank line, regardless of \n vs \r\n, single- or
    // multi-chunk delivery, or where the blank line sits in the stream.
    // SSE's entire event-framing model depends on a blank line marking
    // "this event is complete, the next one starts here": `flush()`
    // below only ever fired via the one unconditional call after the
    // loop, meaning every event in any multi-event stream silently
    // merged into one and was decoded — or failed to decode — as
    // whichever `event:` name happened to arrive last. Splitting lines
    // by hand over the raw byte sequence is what makes blank lines
    // observable at all.
    private func performStream(
        chatID: Chat.ID,
        content: String,
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws {
        let body = try JSONEncoder.evenAI.encode(["chatId": chatID.lowercaseUUIDString, "content": content])
        let (bytes, _) = try await apiClient.streamBytes(path: "chat/stream", body: body)

        var eventName: String?
        var dataLines: [String] = []

        func flush() throws {
            guard let eventName, !dataLines.isEmpty else { return }
            try Self.handle(eventName: eventName, payload: dataLines.joined(separator: "\n"), continuation: continuation)
            dataLines.removeAll()
        }

        func process(_ line: String) throws {
            if line.isEmpty {
                try flush()
                eventName = nil
            } else if line.hasPrefix(":") {
                return // comment / heartbeat
            } else if line.hasPrefix("event:") {
                eventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces))
            }
        }

        var lineBuffer: [UInt8] = []
        for try await byte in bytes {
            if byte == UInt8(ascii: "\n") {
                // A lone \r right before \n (CRLF line endings) would
                // otherwise become part of the line's content.
                if lineBuffer.last == UInt8(ascii: "\r") {
                    lineBuffer.removeLast()
                }
                try process(String(decoding: lineBuffer, as: UTF8.self))
                lineBuffer.removeAll(keepingCapacity: true)
            } else {
                lineBuffer.append(byte)
            }
        }
        if !lineBuffer.isEmpty {
            try process(String(decoding: lineBuffer, as: UTF8.self))
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
            let message = decoded?.error.message ?? "Unknown streaming error."
            AppLogger.chat.error("Streaming reply failed: \(message, privacy: .public)")
            throw NetworkChatServiceError.server(message)
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

private extension UUID {
    /// `UUID.uuidString` always renders uppercase, but the backend stores
    /// and compares chat/message ids as lowercase (confirmed live: the
    /// exact same id, same account, same token 404s as `CHAT_NOT_FOUND`
    /// when sent uppercase and succeeds when sent lowercase) — a
    /// case-sensitive string match server-side, not a canonicalized UUID
    /// comparison. Every outgoing id in this file must go through this,
    /// not `.uuidString`, whether it lands in a URL path or a JSON body.
    var lowercaseUUIDString: String { uuidString.lowercased() }
}
