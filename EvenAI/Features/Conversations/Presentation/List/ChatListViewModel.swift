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
    /// Guards against a rapid double-tap on "New Chat" dispatching two
    /// overlapping `createChat()` calls, which would otherwise both
    /// succeed and create two chats from one tap.
    private var isCreatingChat = false

    private let chatService: ChatServicing

    /// No default — `chatService` always comes from whoever constructs
    /// this (`ChatListView`, itself given it via `RootView`'s
    /// `@Environment(\.chatService)`, or a test's own fake directly).
    /// Never resolved from `AppContainer.live` here: `Features` may only
    /// reach `Infrastructure` through injection, never a concrete type in
    /// `App/DI` (see `ARCHITECTURE.md`'s Dependency Rule).
    init(chatService: ChatServicing) {
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
        guard !isCreatingChat else { return nil }
        isCreatingChat = true
        defer { isCreatingChat = false }

        guard let newChat = try? await chatService.createChat(title: Chat.defaultTitle) else { return nil }
        chats.insert(newChat, at: 0)
        return newChat
    }

    func deleteChat(_ chat: Chat) async {
        do {
            try await chatService.deleteChat(id: chat.id)
            chats.removeAll { $0.id == chat.id }
        } catch {
            // Leave local state untouched on failure — the chat still
            // exists on the backend, so removing it here would make the
            // list lie until the next reload silently brought it back.
        }
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
