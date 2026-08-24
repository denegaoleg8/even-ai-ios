import SwiftUI

struct ChatListView: View {
    @Environment(AppState.self) private var appState
    @Environment(AuthState.self) private var authState
    @Environment(GlassesChatProvider.self) private var glassesChatProvider
    @State private var viewModel: ChatListViewModel
    @State private var chatPendingRename: Chat?
    @State private var renameText: String = ""
    @State private var isOpeningGlassesChat = false

    init(chatService: ChatServicing) {
        _viewModel = State(initialValue: ChatListViewModel(chatService: chatService))
    }

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {
            glassesChatRow
            Divider()
            chatListContent
        }
        .navigationTitle("Even AI")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    appState.isSettingsPresented = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await createChat() }
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
            }
        }
        .sheet(isPresented: $appState.isSettingsPresented) {
            SettingsView()
        }
        .alert("Rename Chat", isPresented: renameAlertBinding, presenting: chatPendingRename) { chat in
            TextField("Chat name", text: $renameText)
            Button("Save") {
                Task { await viewModel.renameChat(chat, to: renameText) }
            }
            Button("Cancel", role: .cancel) {}
        }
        // One combined key, not three separate `.task(id:)` modifiers —
        // `.task(id:)` fires once immediately on top of firing on every
        // id change, so three independent ones would fire three
        // concurrent loadChats() calls on first appearance alone. This
        // fires once per *meaningful* change: the selected chat, the
        // signed-in identity (login/logout/restore, including Phase
        // 3.7's silent-fallback sync), or a merge completing (same
        // identity, different chats underneath — see
        // AppState.chatListRefreshToken).
        //
        // Gated on `!authState.isRestoringSession`: `currentUser` starts
        // `nil` and resolves to a real id the moment `RootView`'s launch-
        // time `restoreSession()` finishes — often within milliseconds of
        // this view's first appearance. Without this guard, that nil→
        // resolved transition changes `refreshTrigger` and `.task(id:)`
        // cancels whatever `loadChats()` call was already in flight from
        // the initial (pre-restore) firing, surfacing as a spurious
        // `URLError.cancelled` with no cached chats yet to fall back to.
        // Skipping the call entirely while restoration is still in
        // progress means the *next* firing (once the identity is settled)
        // is the only one that ever calls `loadChats()`.
        .task(id: refreshTrigger) {
            guard !authState.isRestoringSession else { return }
            await viewModel.loadChats()
        }
    }

    /// "Glasses Chat" — a small, minimal UI addition (per the product
    /// requirement to not redesign Chat's UI/layout here): a permanently
    /// pinned entry above the normal chat list, visually distinct (a
    /// dedicated eyeglasses icon, no swipe/rename/delete actions — this
    /// conversation isn't user-managed the way an ad hoc chat is), that
    /// resolves (find-or-create — see `GlassesChatProvider`) and opens the
    /// one persistent conversation every G2/Live Translation interaction
    /// appends to. Once resolved it also appears in the list below like
    /// any other chat (same `chatService.fetchChats()`, no special-casing
    /// there) — this row is just the guaranteed, always-visible way to
    /// reach it even before it's ever been created.
    private var glassesChatRow: some View {
        Button {
            Task { await openGlassesChat() }
        } label: {
            HStack {
                Label(GlassesChatProvider.displayTitle, systemImage: "eyeglasses")
                Spacer()
                if isOpeningGlassesChat {
                    ProgressView()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding()
        .disabled(isOpeningGlassesChat)
        .accessibilityIdentifier("chatList.glassesChatButton")
    }

    private func openGlassesChat() async {
        isOpeningGlassesChat = true
        defer { isOpeningGlassesChat = false }
        guard let chat = try? await glassesChatProvider.findOrCreateGlassesChat() else { return }
        appState.selectedChatID = chat.id
        await viewModel.loadChats()
    }

    @ViewBuilder
    private var chatListContent: some View {
        @Bindable var appState = appState

        Group {
            if viewModel.isLoading && viewModel.chats.isEmpty {
                LoadingView(label: "Loading chats...")
            } else if viewModel.chats.isEmpty && viewModel.loadFailed {
                EmptyStateView(
                    systemImage: "wifi.slash",
                    title: "Can't Connect",
                    subtitle: "Check your connection and try again.",
                    actionTitle: "Retry",
                    action: { Task { await viewModel.loadChats() } }
                )
            } else if viewModel.chats.isEmpty {
                EmptyStateView(
                    systemImage: "bubble.left.and.bubble.right",
                    title: "No Chats Yet",
                    subtitle: "Start a conversation with Even AI.",
                    actionTitle: "New Chat",
                    action: { Task { await createChat() } }
                )
            } else {
                List(selection: $appState.selectedChatID) {
                    ForEach(viewModel.chats) { chat in
                        ChatRowView(chat: chat)
                            .contextMenu {
                                Button {
                                    beginRename(chat)
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    Task { await viewModel.deleteChat(chat) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await viewModel.deleteChat(chat) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    beginRename(chat)
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                    }
                }
                .listStyle(.sidebar)
                .animation(.easeOut(duration: 0.2), value: viewModel.chats)
            }
        }
    }

    private var refreshTrigger: String {
        "\(appState.selectedChatID?.uuidString ?? "none")|\(authState.currentUser?.id.uuidString ?? "none")|\(appState.chatListRefreshToken)"
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { chatPendingRename != nil },
            set: { isPresented in
                if !isPresented { chatPendingRename = nil }
            }
        )
    }

    private func beginRename(_ chat: Chat) {
        renameText = chat.title
        chatPendingRename = chat
    }

    private func createChat() async {
        if let newChat = await viewModel.createChat() {
            appState.selectedChatID = newChat.id
        }
    }
}

#Preview {
    let mockChatService = MockChatService()
    NavigationSplitView {
        ChatListView(chatService: mockChatService)
            .environment(AppState())
            .environment(AuthState())
            .environment(GlassesChatProvider(chatService: mockChatService))
    } detail: {
        Text("Detail")
    }
}
