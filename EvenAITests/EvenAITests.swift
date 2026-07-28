import Testing
@testable import EvenAI

@Suite("Chat domain model")
struct EvenAITests {
    @Test("New chats default to a placeholder title")
    func defaultChatTitle() {
        let chat = Chat()
        #expect(chat.title == Chat.defaultTitle)
    }

    @Test("MockChatService seeds at least one welcome chat on first fetch")
    func mockServiceSeedsWelcomeChat() async throws {
        let service = MockChatService(modelContainer: PersistenceController.preview)
        let chats = try await service.fetchChats()
        #expect(!chats.isEmpty)
    }
}
