import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView {
            ChatListView()
        } detail: {
            if let chatID = appState.selectedChatID {
                ChatView(chatID: chatID)
                    .id(chatID)
            } else {
                EmptyStateView(
                    systemImage: "bubble.left.and.bubble.right",
                    title: "No Chat Selected",
                    subtitle: "Choose a chat from the list, or start a new one."
                )
            }
        }
    }
}

#Preview {
    RootView()
        .environment(AppState())
}
