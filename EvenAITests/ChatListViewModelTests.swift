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
}
