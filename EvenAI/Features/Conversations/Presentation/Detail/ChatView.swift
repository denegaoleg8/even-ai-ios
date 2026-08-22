import SwiftUI

struct ChatView: View {
    let chatID: Chat.ID
    @Environment(AuthState.self) private var authState
    @Environment(AppState.self) private var appState
    /// The ONE shared conversation/session record `LiveTranslationService`
    /// appends live-conversation turns into (see `AgentContextStore`'s
    /// doc comment) — `ChatView` reads it directly rather than reaching
    /// through `LiveTranslationService` for this, so there is exactly one
    /// source of truth for "what was the last live turn," not two.
    @Environment(AgentContextStore.self) private var agentContextStore
    @State private var viewModel: ChatViewModel

    init(chatID: Chat.ID, chatService: ChatServicing, glassesTransport: GlassesTransport) {
        self.chatID = chatID
        _viewModel = State(
            initialValue: ChatViewModel(chatID: chatID, chatService: chatService, glassesTransport: glassesTransport)
        )
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        let liveConversation = ChatLiveConversationPresenter.present(agentContextStore.session)

        VStack(spacing: 0) {
            if let latestTurn = liveConversation.latest {
                liveConversationSection(latestTurn: latestTurn, olderTurns: liveConversation.older)
            }

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

    /// Read-only: shows the shared session's live-conversation turns —
    /// see `AgentContextStore`/`ChatLiveConversationPresenter`. Never
    /// becomes a `Message`, is never sent through `ChatMessageSender`/the
    /// normal Chat backend pipeline, and is not part of `viewModel`'s own
    /// state, so it can't interfere with normal Chat. The newest turn is
    /// shown prominently; any earlier turns from this session stay
    /// visible below it, dimmed, newest-first — "remain available in the
    /// conversation context" without competing with the current one.
    private func liveConversationSection(latestTurn: ConversationTurn, olderTurns: [ConversationTurn]) -> some View {
        VStack(alignment: .leading, spacing: AppMetrics.Spacing.xs) {
            liveConversationTurnRow(latestTurn, isProminent: true)
                .accessibilityIdentifier("chat.liveTranslationBanner")

            if !olderTurns.isEmpty {
                VStack(alignment: .leading, spacing: AppMetrics.Spacing.xs) {
                    ForEach(olderTurns) { turn in
                        liveConversationTurnRow(turn, isProminent: false)
                    }
                }
                .accessibilityIdentifier("chat.liveConversation.olderTurns")
            }
        }
        .padding(AppMetrics.Spacing.sm)
        .background(AppColor.secondaryBackground)
        .accessibilityIdentifier("chat.liveConversationSection")
    }

    private func liveConversationTurnRow(_ turn: ConversationTurn, isProminent: Bool) -> some View {
        HStack(alignment: .top, spacing: AppMetrics.Spacing.sm) {
            Image(systemName: "globe")
                .foregroundStyle(isProminent ? AppColor.accent : AppColor.textSecondary)
            VStack(alignment: .leading, spacing: AppMetrics.Spacing.xs) {
                Text(turn.originalText)
                    .font(AppTypography.chatPreview)
                if let translation = turn.ukrainianTranslation {
                    Text("Translation:")
                        .font(.caption2)
                        .foregroundStyle(AppColor.textSecondary)
                    Text(translation)
                        .font(AppTypography.chatPreview)
                        .foregroundStyle(AppColor.textSecondary)
                }
                if let detectedLanguage = turn.detectedLanguage {
                    Text(detectedLanguage)
                        .font(.caption2)
                        .foregroundStyle(AppColor.textSecondary)
                }
                if !turn.suggestedReplies.isEmpty {
                    VStack(alignment: .leading, spacing: AppMetrics.Spacing.xs) {
                        Text("Suggested replies:")
                            .font(.caption2)
                            .foregroundStyle(AppColor.textSecondary)
                        ForEach(
                            Array(turn.suggestedReplies.sorted { $0.ordering < $1.ordering }.enumerated()),
                            id: \.element.id
                        ) { index, reply in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(index + 1). \(reply.originalLanguageText)")
                                    .font(AppTypography.chatPreview)
                                Text(reply.ukrainianText)
                                    .font(AppTypography.chatPreview)
                                    .foregroundStyle(AppColor.textSecondary)
                            }
                        }
                    }
                    .padding(.top, AppMetrics.Spacing.xs)
                    .accessibilityIdentifier("chat.liveConversation.suggestedReplies")
                }
            }
            Spacer()
        }
        .opacity(isProminent ? 1 : 0.6)
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
        ChatView(chatID: UUID(), chatService: MockChatService(), glassesTransport: MockGlassesTransport())
            .environment(AuthState())
            .environment(AppState())
            .environment(AgentContextStore())
    }
}
