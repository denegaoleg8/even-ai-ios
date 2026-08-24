import Testing
import Foundation
@testable import EvenAI

@MainActor
@Suite("ChatViewModel error handling")
struct ChatViewModelTests {
    @Test("A failed history load is distinguishable from a genuinely empty conversation")
    func failedLoadIsFlagged() async {
        let viewModel = ChatViewModel(chatID: UUID(), chatService: FailingChatService(), glassesTransport: MockGlassesTransport())
        await viewModel.load()
        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.loadFailed)
    }

    @Test("Sending fails before any connection: the typed message is preserved, not silently dropped")
    func neverConnectedPreservesDraftAsFailedMessage() async {
        let viewModel = ChatViewModel(chatID: UUID(), chatService: FailingChatService(), glassesTransport: MockGlassesTransport())
        viewModel.draftText = "Hello there"
        await viewModel.sendDraft()

        #expect(viewModel.draftText.isEmpty) // input bar cleared, as normal
        #expect(viewModel.messages.count == 1)
        #expect(viewModel.messages.first?.role == .user)
        #expect(viewModel.messages.first?.content == "Hello there")
        #expect(viewModel.messages.first?.status == .failed)
    }

    @Test("A mid-stream drop marks the partial reply failed instead of looking complete")
    func midStreamDropMarksPartialReplyFailed() async {
        let viewModel = ChatViewModel(
            chatID: UUID(),
            chatService: PartialStreamThenFailChatService(),
            glassesTransport: MockGlassesTransport()
        )
        viewModel.draftText = "Tell me something"
        await viewModel.sendDraft()

        #expect(viewModel.messages.count == 2)
        #expect(viewModel.messages[0].role == .user)
        #expect(viewModel.messages[1].role == .assistant)
        #expect(viewModel.messages[1].content == "Partial")
        #expect(viewModel.messages[1].status == .failed)
    }

    @Test("Sending state flags are always cleared after a failure, never left stuck")
    func sendingFlagsClearAfterFailure() async {
        let viewModel = ChatViewModel(chatID: UUID(), chatService: FailingChatService(), glassesTransport: MockGlassesTransport())
        viewModel.draftText = "Hello"
        await viewModel.sendDraft()

        #expect(!viewModel.isSending)
        #expect(!viewModel.isAwaitingFirstToken)
    }

    /// Glasses Chat / general Chat history requirement (Section I/J,
    /// major performance pass): loading a conversation with multiple
    /// persisted turns must return them in stable, unreordered order,
    /// each with its own stable `Message.id` — what `ForEach(viewModel
    /// .messages) { }.id(message.id)` in `ChatView` relies on for
    /// correct, non-flickering identity across updates.
    @Test("loading a conversation with multiple turns preserves their order and each message's stable id")
    func loadPreservesOrderAndStableIDs() async {
        let chatID = UUID()
        let chat = Chat(id: chatID, title: "Glasses Chat")
        let messages = [
            Message(chatID: chatID, role: .user, content: "Guten Tag\n→ Добрий день"),
            Message(chatID: chatID, role: .user, content: "Wie geht es dir?\n→ Як справи?"),
            Message(chatID: chatID, role: .user, content: "Auf Wiedersehen\n→ До побачення"),
        ]
        let chatService = StubChatService(chats: [chat], messages: messages)
        let viewModel = ChatViewModel(chatID: chatID, chatService: chatService, glassesTransport: MockGlassesTransport())

        await viewModel.load()

        #expect(viewModel.messages.map(\.id) == messages.map(\.id))
        #expect(viewModel.messages.map(\.content) == messages.map(\.content))
    }
}
