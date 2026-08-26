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
    /// swappable dependency. See `AIConversationEngine`'s doc comment.
    @State private var liveTranslation: AIConversationEngine
    /// Milestone 2: the ONE shared conversation/session record — see
    /// `AgentContextStore`'s doc comment. Constructed here (same
    /// app-level pattern as `appState`/`authState`/`liveTranslation`) and
    /// handed to `liveTranslation` below *and* injected into the
    /// environment, so every future consumer (Chat, etc.) shares the
    /// exact same instance `AIConversationEngine` is already writing
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
        // Local-first architecture pass: Glasses Chat no longer depends on
        // `ChatServicing`/Railway at all — see `GlassesChatProvider`'s and
        // `LocalGlassesChatStore`'s own doc comments.
        let glassesChatProvider = GlassesChatProvider(localStore: LocalGlassesChatStore())
        _languageTranslator = State(initialValue: translator)
        _agentContextStore = State(initialValue: agentContextStore)
        _glassesChatProvider = State(initialValue: glassesChatProvider)
        // Local-first architecture pass: Milestone 8b hardcoded
        // OpenAIRealtimeTranscriber as THE production transcriber
        // (abandoning GlassesSpeechTranscriber specifically because it
        // only supported en-US) — meaning Live Translation could not even
        // START without Railway/auth succeeding first.
        // `TranscriptionProviderRouter` restores on-device as the
        // DEFAULT, preferred path (`GlassesSpeechTranscriber` now
        // supports EN/DE/PL — see `SourceLanguageMode.onDeviceLocaleIdentifier`
        // — so the reason it was abandoned no longer applies), with
        // `OpenAIRealtimeTranscriber` retained unchanged as the opt-in
        // `.cloud` choice / `.auto` mode's fallback. See
        // `TranscriptionProviderRouter`'s own doc comment for the exact
        // selection contract — including the Cloud-mode production-safety
        // fix (confirmed physical-device cause: `POST auth/device` failing
        // against the now-unavailable Railway deployment used to throw
        // straight through and terminate the whole session; Cloud now
        // transparently falls back to on-device instead).
        //
        // Held as a named local (not inline in the `AIConversationEngine`
        // initializer below) specifically so `onCloudFallback` can be wired
        // up right after `liveTranslation` is constructed — the router has
        // to exist before `AIConversationEngine` does (it's one of that
        // type's own init parameters), so it can't reference
        // `liveTranslation` at construction time.
        let transcriberRouter = TranscriptionProviderRouter(
            local: GlassesSpeechTranscriber(),
            cloud: OpenAIRealtimeTranscriber(apiClient: AppContainer.live.apiClient),
            mode: { Self.resolveTranscriptionProviderMode(defaults: .standard) },
            resolveLocale: { Self.resolveOnDeviceLocale(sourceLanguageModeDefaults: .standard) }
        )
        let liveTranslation = AIConversationEngine(
            glassesTransport: AppContainer.live.glassesTransport,
            transcriber: transcriberRouter,
            translator: translator,
            agentContextStore: agentContextStore,
            // Suggested-replies restoration pass: local-first, exactly
            // like the transcriber above — `LocalSuggestedReplyGenerator`
            // prefers Apple's on-device `FoundationModels` framework
            // (iOS 26+, Apple Intelligence) and NEVER falls back to
            // Railway/`NetworkSuggestedReplyGenerator` automatically when
            // it's unavailable (device ineligible, Apple Intelligence
            // off, model not ready, or a pre-iOS-26 device) — that would
            // silently reintroduce the exact backend dependency this
            // whole architecture pass removes. `NetworkSuggestedReplyGenerator`
            // itself is untouched and still fully available for an
            // explicit, opt-in cloud-replies wiring in the future; it's
            // simply no longer the default. Failures of either kind never
            // reach here either way — `AIConversationEngine
            // .generateSuggestedReplies` catches everything and simply
            // skips display; translation is a completely independent,
            // higher-priority pipeline (§4/§8 of this pass's own
            // requirements).
            replyGenerator: LocalSuggestedReplyGenerator(),
            glassesChatProvider: glassesChatProvider
        )
        transcriberRouter.onCloudFallback = { [weak liveTranslation] error in
            liveTranslation?.noteCloudFallback(error)
        }
        _liveTranslation = State(initialValue: liveTranslation)
    }

    /// Reads the SAME persisted `sourceLanguageMode` UserDefaults key
    /// `AIConversationEngine` itself owns (`com.evenai.liveTranslation.sourceLanguageMode`)
    /// directly, rather than threading a `AIConversationEngine`
    /// reference into `TranscriptionProviderRouter` — avoids a circular
    /// construction dependency (the router has to exist before
    /// `AIConversationEngine` does, since it's one of that type's own
    /// init parameters). `.auto`'s on-device locale defaults to the
    /// device's own current region if it's one of the three primary
    /// source languages, else `en-US` — see `SourceLanguageMode
    /// .onDeviceLocaleIdentifier`'s own doc comment for why true
    /// mid-conversation on-device language auto-switching isn't attempted.
    private static func resolveOnDeviceLocale(sourceLanguageModeDefaults defaults: UserDefaults) -> Locale {
        let key = "com.evenai.liveTranslation.sourceLanguageMode"
        if let saved = defaults.string(forKey: key),
           let mode = SourceLanguageMode(rawValue: saved),
           let identifier = mode.onDeviceLocaleIdentifier {
            return Locale(identifier: identifier)
        }
        let deviceLanguage = Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
        switch deviceLanguage {
        case "de": return Locale(identifier: "de-DE")
        case "pl": return Locale(identifier: "pl-PL")
        default: return Locale(identifier: "en-US")
        }
    }

    /// Reads the SAME persisted `transcriptionProviderMode` key
    /// `AIConversationEngine` owns, for the same circular-dependency
    /// reason as `resolveOnDeviceLocale(sourceLanguageModeDefaults:)`
    /// above. `static` (not an instance method) deliberately — this
    /// closure is captured inside `init()`, before `self` is fully
    /// initialized, so it must not reference `self` at all.
    private static func resolveTranscriptionProviderMode(defaults: UserDefaults) -> TranscriptionProviderMode {
        let key = "com.evenai.liveTranslation.transcriptionProviderMode"
        guard let saved = defaults.string(forKey: key),
              let mode = TranscriptionProviderMode(rawValue: saved)
        else { return .auto }
        return mode
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
