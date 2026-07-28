import SwiftUI

struct ChatListView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = ChatListViewModel()
    @State private var chatPendingRename: Chat?
    @State private var renameText: String = ""

    var body: some View {
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
        .task(id: appState.selectedChatID) {
            await viewModel.loadChats()
        }
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
    NavigationSplitView {
        ChatListView()
            .environment(AppState())
    } detail: {
        Text("Detail")
    }
}
