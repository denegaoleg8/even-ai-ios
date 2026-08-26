import SwiftUI
// `TranslationSession` predates Swift 6 strict-concurrency annotations —
// see `AppleLanguageTranslator.swift`'s import comment.
@preconcurrency import Translation

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(AuthState.self) private var authState
    @Environment(LiveTranslationService.self) private var liveTranslation
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
        //
        // `translationConfiguration` is now kept in sync with
        // `liveTranslation.resolvedSourceLanguageCode` (see
        // `syncTranslationConfiguration()`) rather than being created
        // once, statically, with `source: nil` (auto-detect) forever —
        // that static configuration was the actual root cause of "select
        // EN/DE/PL but the app keeps asking to select a language again":
        // Apple's `Translation` framework has no per-call source-language
        // override (confirmed against the framework's own interface —
        // see `resolvedSourceLanguageCode`'s doc comment); the ONLY way
        // to make it stop running its own internal auto-detection is to
        // give the session itself a concrete `Configuration.source`.
        // Changing this value's identity is what causes SwiftUI to tear
        // down the old session and stand up a new one via this exact
        // modifier — `Configuration` is `Equatable`, so a change that
        // doesn't actually alter the resolved language never triggers a
        // pointless session rebuild.
        .translationTask(translationConfiguration) { session in
            await languageTranslator.runSession(session)
        }
        .onAppear {
            syncTranslationConfiguration()
        }
        .onChange(of: liveTranslation.resolvedSourceLanguageCode) {
            syncTranslationConfiguration()
        }
    }

    /// The one place `translationConfiguration` is ever written — keeps
    /// the real `TranslationSession`'s `source` equal to whatever
    /// `LiveTranslationService` currently considers authoritative
    /// (explicit selection, or the current Auto lock; `nil` only while
    /// Auto hasn't locked onto anything yet this session). See
    /// `LiveTranslationService.resolvedSourceLanguageCode`'s doc comment
    /// for the full root-cause explanation this fixes.
    private func syncTranslationConfiguration() {
        let sourceCode = liveTranslation.resolvedSourceLanguageCode
        let source = sourceCode.map { Locale.Language(identifier: $0) }
        // "Explicit mode must never run detection" is enforced at the
        // actual Translation-API level by construction here: whenever
        // `sourceLanguageMode` is explicit, `resolvedSourceLanguageCode`
        // always returns that fixed code (never `nil`), so `source` can
        // never be `nil` in that case — this assertion exists purely as
        // insurance against a future regression re-introducing the
        // "impossible state" the product explicitly called out, not
        // because normal control flow can reach it today.
        assert(
            liveTranslation.sourceLanguageMode.explicitLanguageCode == nil || source != nil,
            "explicit source-language mode must never configure the TranslationSession with a nil (auto-detect) source"
        )
        let newConfiguration = TranslationSession.Configuration(source: source, target: Locale.Language(identifier: "uk"))
        guard translationConfiguration != newConfiguration else { return }
        DiagnosticTrace.log(
            "TRANSLATION_SESSION_RECONFIGURED",
            "source=\(sourceCode ?? "nil(auto)") mode=\(liveTranslation.sourceLanguageMode.rawValue)"
        )
        translationConfiguration = newConfiguration
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
        .environment(GlassesChatProvider(localStore: LocalGlassesChatStore(modelContainer: PersistenceController.preview)))
}
