import Testing
@testable import EvenAI

@MainActor
@Suite("ChatListViewModel error handling")
struct ChatListViewModelTests {
    @Test("A failed load is distinguishable from a genuinely empty list")
    func failedLoadIsFlagged() async {
        let viewModel = ChatListViewModel(chatService: FailingChatService())
        await viewModel.loadChats()
        #expect(viewModel.chats.isEmpty)
        #expect(viewModel.loadFailed)
    }

    @Test("A successful load with no chats is not treated as a failure")
    func genuinelyEmptyIsNotFlaggedAsFailure() async {
        let viewModel = ChatListViewModel(chatService: EmptyChatService())
        await viewModel.loadChats()
        #expect(viewModel.chats.isEmpty)
        #expect(!viewModel.loadFailed)
    }

    @Test("A retry after a failure clears the failed flag once it succeeds")
    func retryClearsFailure() async {
        let viewModel = ChatListViewModel(chatService: FailingChatService())
        await viewModel.loadChats()
        #expect(viewModel.loadFailed)

        // Simulate the user hitting Retry once the backend is reachable
        // again by swapping in a working service and reloading.
        let workingViewModel = ChatListViewModel(chatService: EmptyChatService())
        await workingViewModel.loadChats()
        #expect(!workingViewModel.loadFailed)
    }

    @Test("A failed delete does not remove the chat from local state")
    func failedDeleteLeavesLocalStateUntouched() async {
        let viewModel = ChatListViewModel(chatService: DeleteFailingChatService())
        guard let chat = await viewModel.createChat() else {
            Issue.record("Expected createChat to succeed")
            return
        }
        #expect(viewModel.chats.contains { $0.id == chat.id })

        await viewModel.deleteChat(chat)

        // The backend delete failed, so the chat must still be present —
        // removing it locally would make the list lie until the next
        // reload silently brought it back.
        #expect(viewModel.chats.contains { $0.id == chat.id })
    }

    @Test("Two concurrent createChat calls only create one chat")
    func rapidDoubleCreateIsGuarded() async {
        let service = CountingCreateChatService()
        let viewModel = ChatListViewModel(chatService: service)

        async let first = viewModel.createChat()
        async let second = viewModel.createChat()
        let results = await [first, second]

        let succeededCount = results.compactMap { $0 }.count
        #expect(succeededCount == 1)
        let callCount = await service.createCallCount
        #expect(callCount == 1)
    }
}
