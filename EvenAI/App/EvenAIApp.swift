import SwiftUI
import SwiftData

@main
struct EvenAIApp: App {
    @State private var appState = AppState()
    @State private var authState = AuthState()
    /// Held concretely (not just via `LanguageTranslating`) so `RootView`
    /// can attach the one `.translationTask` this instance needs — see
    /// `AppleLanguageTranslator`'s doc comment on why that can't be done
    /// through the protocol. Same instance is also handed to
    /// `liveTranslation` below, typed as `LanguageTranslating` there.
    @State private var languageTranslator = AppleLanguageTranslator()
    /// App-level, constructed here rather than through `AppContainer` —
    /// mirrors `appState`/`authState`, not `chatService`/`glassesTransport`
    /// — because it's stateful, observable, app-lifetime state, not a
    /// swappable dependency. See `LiveTranslationService`'s doc comment.
    @State private var liveTranslation: LiveTranslationService
    /// Milestone 2: the ONE shared conversation/session record — see
    /// `AgentContextStore`'s doc comment. Constructed here (same
    /// app-level pattern as `appState`/`authState`/`liveTranslation`) and
    /// handed to `liveTranslation` below *and* injected into the
    /// environment, so every future consumer (Chat, etc.) shares the
    /// exact same instance `LiveTranslationService` is already writing
    /// into — never a second, independent session.
    @State private var agentContextStore = AgentContextStore()

    init() {
        let translator = AppleLanguageTranslator()
        let agentContextStore = AgentContextStore()
        _languageTranslator = State(initialValue: translator)
        _agentContextStore = State(initialValue: agentContextStore)
        _liveTranslation = State(
            initialValue: LiveTranslationService(
                glassesTransport: AppContainer.live.glassesTransport,
                transcriber: GlassesSpeechTranscriber(),
                translator: translator,
                agentContextStore: agentContextStore,
                // No real AI provider chosen yet — replacing this is the
                // entire scope of that future milestone; nothing else
                // here needs to change to do it.
                replyGenerator: NoOpSuggestedReplyGenerator()
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(authState)
                .environment(liveTranslation)
                .environment(agentContextStore)
                .environment(\.languageTranslator, languageTranslator)
                .environment(\.chatService, AppContainer.live.chatService)
                .environment(\.glassesTransport, AppContainer.live.glassesTransport)
        }
        .modelContainer(PersistenceController.shared)
    }
}
