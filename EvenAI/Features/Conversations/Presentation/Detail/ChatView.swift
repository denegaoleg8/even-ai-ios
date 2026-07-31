import SwiftUI

struct ChatView: View {
    let chatID: Chat.ID
    @Environment(AuthState.self) private var authState
    @Environment(AppState.self) private var appState
    @State private var viewModel: ChatViewModel

    init(chatID: Chat.ID, chatService: ChatServicing) {
        self.chatID = chatID
        _viewModel = State(initialValue: ChatViewModel(chatID: chatID, chatService: chatService))
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        VStack(spacing: 0) {
            if viewModel.isLoading && viewModel.messages.isEmpty {
                LoadingView(label: "Loading messages...")
            } else if viewModel.messages.isEmpty && viewModel.loadFailed {
                EmptyStateView(
                    systemImage: "wifi.slash",
                    title: "Can't Load Messages",
                    subtitle: "Check your connection and try again.",
                    actionTitle: "Retry",
                    action: { Task { await viewModel.load() } }
                )
            } else if viewModel.messages.isEmpty && !viewModel.isAwaitingFirstToken {
                EmptyStateView(
                    systemImage: "sparkles",
                    title: "Say Hello",
                    subtitle: "Send a message to start this conversation with Even AI."
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: AppMetrics.Spacing.sm) {
                            ForEach(viewModel.messages) { message in
                                MessageBubbleView(message: message)
                                    .id(message.id)
                            }
                            if viewModel.isAwaitingFirstToken {
                                TypingIndicatorView()
                                    .id("typing-indicator")
                            }
                            Color.clear
                                .frame(height: 1)
                                .id("bottom")
                        }
                        .padding(AppMetrics.Spacing.md)
                        .animation(.easeOut(duration: 0.2), value: viewModel.messages)
                    }
                    .onChange(of: viewModel.messages) {
                        scrollToBottom(proxy)
                    }
                    .onChange(of: viewModel.isAwaitingFirstToken) {
                        scrollToBottom(proxy)
                    }
                    .onAppear {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }

            Divider()

            MessageInputBar(
                text: $viewModel.draftText,
                isSending: viewModel.isSending,
                onSend: { Task { await viewModel.sendDraft() } }
            )
        }
        .navigationTitle(viewModel.chatTitle)
        .navigationBarTitleDisplayMode(.inline)
        // See ChatListView.refreshTrigger for why this is one combined
        // key rather than separate `.task(id:)` modifiers per input —
        // same reasoning applies here: the signed-in identity changing
        // (login/logout/restore, including a silent fallback) or a merge
        // completing must both re-fetch this chat too, not just the list.
        //
        // Gated on `!authState.isRestoringSession` for the same reason as
        // ChatListView's identical guard: opening a chat immediately after
        // launch races `RootView`'s `restoreSession()` resolving
        // `currentUser` from nil to a real id, which would otherwise
        // change `refreshTrigger` mid-fetch and have `.task(id:)` cancel
        // this chat's `load()` call before it ever gets a response.
        .task(id: refreshTrigger) {
            guard !authState.isRestoringSession else { return }
            await viewModel.load()
        }
    }

    private var refreshTrigger: String {
        "\(chatID.uuidString)|\(authState.currentUser?.id.uuidString ?? "none")|\(appState.chatListRefreshToken)"
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }
}

#Preview {
    NavigationStack {
        ChatView(chatID: UUID(), chatService: MockChatService())
            .environment(AuthState())
            .environment(AppState())
    }
}
