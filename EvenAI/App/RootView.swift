import SwiftUI
// `TranslationSession` predates Swift 6 strict-concurrency annotations —
// see `AppleLanguageTranslator.swift`'s import comment.
@preconcurrency import Translation

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(AuthState.self) private var authState
    @Environment(\.languageTranslator) private var languageTranslator
    @Environment(\.chatService) private var chatService
    @Environment(\.glassesTransport) private var glassesTransport
    @State private var translationConfiguration: TranslationSession.Configuration?

    var body: some View {
        NavigationSplitView {
            ChatListView(chatService: chatService)
        } detail: {
            if let chatID = appState.selectedChatID {
                ChatView(chatID: chatID, chatService: chatService, glassesTransport: glassesTransport)
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
        // `LiveTranslationService` is app-level and must outlive any one
        // screen, but the `Translation` framework only vends a usable
        // `TranslationSession` through this exact SwiftUI modifier — this
        // is the highest, always-present place in the hierarchy to host
        // it. `languageTranslator.runSession(_:)` just drains translation
        // requests as they arrive; it doesn't care which view attached it.
        .translationTask(translationConfiguration) { session in
            await languageTranslator.runSession(session)
        }
        .onAppear {
            if translationConfiguration == nil {
                translationConfiguration = TranslationSession.Configuration(target: Locale.Language(identifier: "uk"))
            }
        }
    }
}

#Preview {
    RootView()
        .environment(AppState())
        .environment(AuthState())
        .environment(
            LiveTranslationService(
                glassesTransport: MockGlassesTransport(),
                transcriber: GlassesSpeechTranscriber(),
                translator: AppleLanguageTranslator()
            )
        )
        .environment(AgentContextStore())
        .environment(GlassesChatProvider(chatService: MockChatService()))
}
