import Foundation
import Observation

@MainActor
@Observable
final class ChatListViewModel {
    private(set) var chats: [Chat] = []
    private(set) var isLoading = false
    /// True when the most recent `loadChats()` failed — lets the view tell
    /// "no chats yet" apart from "couldn't reach the backend," which look
    /// identical if you only check `chats.isEmpty`.
    private(set) var loadFailed = false

    private let chatService: ChatServicing

    init(chatService: ChatServicing = AppContainer.live.chatService) {
        self.chatService = chatService
    }

    func loadChats() async {
        isLoading = true
        defer { isLoading = false }
        do {
            chats = try await chatService.fetchChats()
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    @discardableResult
    func createChat() async -> Chat? {
        guard let newChat = try? await chatService.createChat(title: Chat.defaultTitle) else { return nil }
        chats.insert(newChat, at: 0)
        return newChat
    }

    func deleteChat(_ chat: Chat) async {
        try? await chatService.deleteChat(id: chat.id)
        chats.removeAll { $0.id == chat.id }
    }

    func renameChat(_ chat: Chat, to newTitle: String) async {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let updated = try? await chatService.renameChat(id: chat.id, title: trimmed) else { return }
        if let index = chats.firstIndex(where: { $0.id == chat.id }) {
            chats[index] = updated
        }
    }
}
