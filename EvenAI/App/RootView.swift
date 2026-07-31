import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(AuthState.self) private var authState
    @Environment(\.chatService) private var chatService

    var body: some View {
        NavigationSplitView {
            ChatListView(chatService: chatService)
        } detail: {
            if let chatID = appState.selectedChatID {
                ChatView(chatID: chatID, chatService: chatService)
                    .id(chatID)
            } else {
                EmptyStateView(
                    systemImage: "bubble.left.and.bubble.right",
                    title: "No Chat Selected",
                    subtitle: "Choose a chat from the list, or start a new one."
                )
            }
        }
        // Fire-and-forget: the rest of the UI never blocks on this. Chat
        // already works whether or not a session has been restored yet
        // (anonymous-by-default), and each screen has its own
        // network-failure handling if a chat call ends up unauthorized —
        // there's nothing auth-specific to show here (no login gate, no
        // loading screen), just the bootstrapping call itself.
        .task {
            await authState.restoreSession()
        }
    }
}

#Preview {
    RootView()
        .environment(AppState())
        .environment(AuthState())
}
