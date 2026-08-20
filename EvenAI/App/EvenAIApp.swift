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

    init() {
        let translator = AppleLanguageTranslator()
        _languageTranslator = State(initialValue: translator)
        _liveTranslation = State(
            initialValue: LiveTranslationService(
                glassesTransport: AppContainer.live.glassesTransport,
                transcriber: GlassesSpeechTranscriber(),
                translator: translator
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(authState)
                .environment(liveTranslation)
                .environment(\.languageTranslator, languageTranslator)
                .environment(\.chatService, AppContainer.live.chatService)
                .environment(\.glassesTransport, AppContainer.live.glassesTransport)
        }
        .modelContainer(PersistenceController.shared)
    }
}
