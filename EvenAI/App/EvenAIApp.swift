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
    /// "Glasses Chat" — the one persistent conversation every G2/Live
    /// Translation interaction appends to. Same app-level pattern as
    /// `agentContextStore`: constructed once here, shared by identity with
    /// `liveTranslation` (below) and the environment, so `ChatListView`'s
    /// "Glasses Chat" entry resolves/opens the exact same chat Live
    /// Translation is writing into — never two independent instances that
    /// could each create their own chat.
    @State private var glassesChatProvider: GlassesChatProvider

    init() {
        let translator = AppleLanguageTranslator()
        let agentContextStore = AgentContextStore()
        let glassesChatProvider = GlassesChatProvider(chatService: AppContainer.live.chatService)
        _languageTranslator = State(initialValue: translator)
        _agentContextStore = State(initialValue: agentContextStore)
        _glassesChatProvider = State(initialValue: glassesChatProvider)
        _liveTranslation = State(
            initialValue: LiveTranslationService(
                glassesTransport: AppContainer.live.glassesTransport,
                // Milestone 8b: switched from GlassesSpeechTranscriber
                // (Apple Speech, single hardcoded en-US locale) to the
                // Milestone 8a-audited OpenAIRealtimeTranscriber —
                // multilingual (English/German/Polish/Ukrainian)
                // recognition is configured entirely server-side (see
                // even-ai-assistant-asr's src/realtimeTranscription/
                // openaiClient.js SUPPORTED_LANGUAGES); nothing here or
                // in LiveTranslationService needed to change beyond this
                // one line, since both conform to the same
                // ContinuousTranscribing protocol. GlassesSpeechTranscriber
                // itself is untouched and still fully available as an
                // immediate rollback — see its own file.
                transcriber: {
                    // TEMPORARY diagnostic for the Milestone 8b physical-
                    // device failure — confirms the running binary really
                    // did construct OpenAIRealtimeTranscriber (not a stale
                    // build still using GlassesSpeechTranscriber). Remove
                    // once root-caused.
                    DiagnosticTrace.log("8B_TRACE", "EvenAIApp constructing OpenAIRealtimeTranscriber as production transcriber")
                    return OpenAIRealtimeTranscriber(apiClient: AppContainer.live.apiClient)
                }(),
                translator: translator,
                agentContextStore: agentContextStore,
                // Milestone 7: real, backend-calling generator — shares
                // `AppContainer.live.apiClient` with Chat/Auth, same
                // "one client, one session" rule those already follow.
                replyGenerator: NetworkSuggestedReplyGenerator(apiClient: AppContainer.live.apiClient),
                // "Glasses Chat": persists each finalized turn as a real
                // message in the one persistent glasses conversation.
                // Shares `AppContainer.live.chatService` — the same
                // instance Chat itself reads/writes through (below), so a
                // Live Translation turn and a normal Chat send go through
                // the exact same caching/auth/network path, never two
                // independent ones.
                chatService: AppContainer.live.chatService,
                glassesChatProvider: glassesChatProvider
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
                .environment(glassesChatProvider)
                .environment(\.languageTranslator, languageTranslator)
                .environment(\.chatService, AppContainer.live.chatService)
                .environment(\.glassesTransport, AppContainer.live.glassesTransport)
        }
        .modelContainer(PersistenceController.shared)
    }
}
