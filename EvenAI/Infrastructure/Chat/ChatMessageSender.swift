import Foundation

/// Concrete `ChatMessageSending` — wraps the same `ChatServicing` and
/// `GlassesTransport` `ChatViewModel` already depends on. This is where
/// `ChatViewModel`'s old private `mirrorToGlasses(_:)` now lives, moved
/// here rather than left inline.
actor ChatMessageSender: ChatMessageSending {
    private let chatService: ChatServicing
    private let glassesTransport: GlassesTransport

    init(chatService: ChatServicing, glassesTransport: GlassesTransport) {
        self.chatService = chatService
        self.glassesTransport = glassesTransport
    }

    nonisolated func send(chatID: Chat.ID, content: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let upstream = chatService.streamReply(chatID: chatID, content: content)
        let glassesTransport = self.glassesTransport
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in upstream {
                        if case .assistantMessageSaved(let message) = event {
                            Self.mirrorToGlasses(message, via: glassesTransport)
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Best-effort, one-way mirror of a just-completed reply. Never awaited
    /// by the caller's own event loop, so a slow or hung BLE write can never
    /// delay that loop or affect the send's own success/failure. Silently
    /// no-ops if glasses aren't connected (`GlassesTransportError.notConnected`)
    /// — Chat has no dependency on, or ever observes, glasses connection
    /// state. (Moved verbatim from `ChatViewModel`'s old private
    /// `mirrorToGlasses(_:)` — same behavior, shared location.)
    private static func mirrorToGlasses(_ message: Message, via glassesTransport: GlassesTransport) {
        guard !message.content.isEmpty else { return }
        Task {
            try? await glassesTransport.sendText(message.content)
        }
    }
}
