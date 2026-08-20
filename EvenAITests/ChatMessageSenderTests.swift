import Testing
import Foundation
@testable import EvenAI

/// `ChatMessageSender` is the one place a chat message is actually
/// submitted — `ChatViewModel.sendDraft()` goes through it. These tests
/// are the direct proof that relocating the mirror-to-glasses logic here
/// (out of `ChatViewModel`) didn't change its behavior.
@Suite("ChatMessageSender")
struct ChatMessageSenderTests {
    /// Mirroring is a fire-and-forget `Task` inside `sendText` — same
    /// propagation-delay pattern used throughout this test suite (e.g.
    /// `AuthStateSessionSyncTests`) for anything that completes on a later
    /// run-loop turn rather than being directly awaited.
    private static let propagationDelay: Duration = .milliseconds(30)

    @Test("every event is re-yielded unchanged, in order — a caller rendering live deltas still gets them")
    func eventsAreReYieldedUnchanged() async throws {
        let chatID = UUID()
        let userMessage = Message(chatID: chatID, role: .user, content: "Hi")
        let assistantMessage = Message(chatID: chatID, role: .assistant, content: "Hello there")
        let scripted: [ChatStreamEvent] = [
            .userMessageSaved(userMessage),
            .assistantDelta("Hello"),
            .assistantDelta(" there"),
            .assistantMessageSaved(assistantMessage),
        ]
        let sender = ChatMessageSender(
            chatService: ScriptedStreamChatService(events: scripted),
            glassesTransport: MockGlassesTransport()
        )

        var received: [ChatStreamEvent] = []
        for try await event in sender.send(chatID: chatID, content: "Hi") {
            received.append(event)
        }

        // ChatStreamEvent isn't Equatable — compare a derived description
        // instead, checking both content and order survive unchanged.
        #expect(received.map(Self.describe) == scripted.map(Self.describe))
    }

    private static func describe(_ event: ChatStreamEvent) -> String {
        switch event {
        case .userMessageSaved(let message): "user:\(message.id):\(message.content)"
        case .assistantDelta(let delta): "delta:\(delta)"
        case .assistantMessageSaved(let message): "assistant:\(message.id):\(message.content)"
        }
    }

    @Test("a completed reply with non-empty content is mirrored to the glasses")
    func completedReplyIsMirrored() async throws {
        let chatID = UUID()
        let assistantMessage = Message(chatID: chatID, role: .assistant, content: "The final reply")
        let spy = SpyGlassesTransport()
        let sender = ChatMessageSender(
            chatService: ScriptedStreamChatService(events: [.assistantMessageSaved(assistantMessage)]),
            glassesTransport: spy
        )

        for try await _ in sender.send(chatID: chatID, content: "question") {}
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(await spy.sentTexts == ["The final reply"])
    }

    @Test("an empty completed reply is never mirrored")
    func emptyReplyIsNotMirrored() async throws {
        let chatID = UUID()
        let emptyMessage = Message(chatID: chatID, role: .assistant, content: "")
        let spy = SpyGlassesTransport()
        let sender = ChatMessageSender(
            chatService: ScriptedStreamChatService(events: [.assistantMessageSaved(emptyMessage)]),
            glassesTransport: spy
        )

        for try await _ in sender.send(chatID: chatID, content: "question") {}
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(await spy.sentTexts.isEmpty)
    }

    @Test("a stream failure propagates to the caller instead of being swallowed")
    func streamFailurePropagates() async {
        let chatID = UUID()
        let sender = ChatMessageSender(
            chatService: FailingChatService(),
            glassesTransport: MockGlassesTransport()
        )

        await #expect(throws: (any Error).self) {
            for try await _ in sender.send(chatID: chatID, content: "question") {}
        }
    }
}
