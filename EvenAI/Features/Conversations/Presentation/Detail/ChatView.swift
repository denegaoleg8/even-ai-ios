import SwiftUI

struct ChatView: View {
    let chatID: Chat.ID
    @Environment(AuthState.self) private var authState
    @Environment(AppState.self) private var appState
    /// The ONE shared conversation/session record `AIConversationEngine`
    /// appends live-conversation turns into (see `AgentContextStore`'s
    /// doc comment) — `ChatView` reads it directly rather than reaching
    /// through `AIConversationEngine` for this, so there is exactly one
    /// source of truth for "what was the last live turn," not two.
    @Environment(AgentContextStore.self) private var agentContextStore
    @State private var viewModel: ChatViewModel
    /// The actual auto-scroll RULE lives in `ChatAutoScrollState` (pure,
    /// unit-tested in isolation) — this is just the one instance driving
    /// this screen, fed by `.onScrollGeometryChange` (real scroll
    /// position) and `.onChange(of: viewModel.messages)` (new content).
    @State private var autoScroll = ChatAutoScrollState()
    /// How close to the true bottom (in points) still counts as "near
    /// the bottom" for auto-follow purposes — generous enough that a
    /// message bubble or two of slop doesn't feel like "I scrolled away"
    /// (a user reading the very last message, with its bubble partly
    /// below the fold, should still auto-follow), tight enough that
    /// genuinely scrolling up to reread history reliably disables it.
    private static let nearBottomThreshold: CGFloat = 120

    init(chatID: Chat.ID, chatService: ChatServicing, glassesTransport: GlassesTransport) {
        DiagnosticTrace.log("CHAT_VIEW_INIT", "chatID=\(chatID)")
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
            } else if viewModel.messages.isEmpty, let seconds = viewModel.rateLimitedRetryAfterSeconds {
                // See ChatListView's identical branch for the full
                // reasoning — the backend is reachable and working, just
                // temporarily declining new anonymous sessions for a
                // known, bounded time. Never "check your connection".
                EmptyStateView(
                    systemImage: "clock",
                    title: "Session Temporarily Unavailable",
                    subtitle: "Too many session attempts. Retry in \(seconds)s.",
                    actionTitle: "Retry",
                    action: { Task { await viewModel.load() } }
                )
                .accessibilityIdentifier("chat.rateLimitedState")
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
                    // The auto-scroll rule: follow new content only while
                    // already near the bottom; otherwise just flag that
                    // something new arrived, never yank the view out from
                    // under someone deliberately reading older turns.
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        let distanceFromBottom = geometry.contentSize.height
                            - (geometry.contentOffset.y + geometry.containerSize.height)
                        return distanceFromBottom <= Self.nearBottomThreshold
                    } action: { _, isNear in
                        autoScroll.scrollPositionChanged(isNearBottom: isNear)
                    }
                    .onChange(of: viewModel.messages) {
                        if autoScroll.newContentArrived() {
                            scrollToBottom(proxy)
                        }
                    }
                    .onChange(of: viewModel.isAwaitingFirstToken) {
                        if autoScroll.newContentArrived() {
                            scrollToBottom(proxy)
                        }
                    }
                    .onAppear {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    .overlay(alignment: .bottom) {
                        if autoScroll.hasNewMessagesBelow {
                            newMessagesButton(proxy)
                                .padding(.bottom, AppMetrics.Spacing.sm)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: autoScroll.hasNewMessagesBelow)
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
        autoScroll.acknowledgedNewMessages()
    }

    /// The "↓ New messages" affordance — appears only once the user has
    /// scrolled away from the bottom AND something new has arrived since.
    /// Tapping it is the only way this indicator scrolls the view; it
    /// never scrolls on its own.
    private func newMessagesButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            scrollToBottom(proxy)
        } label: {
            Label("New messages", systemImage: "arrow.down")
                .font(AppTypography.chatPreview.weight(.semibold))
                .padding(.horizontal, AppMetrics.Spacing.md)
                .padding(.vertical, AppMetrics.Spacing.xs)
                .background(AppColor.accent)
                .foregroundStyle(Color.white)
                .clipShape(Capsule())
                .shadow(radius: 3)
        }
        .accessibilityIdentifier("chat.newMessagesIndicator")
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
