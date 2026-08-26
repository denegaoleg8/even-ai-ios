import SwiftUI

/// Thin control surface over the app-level `LiveTranslationService` — this
/// view owns no state of its own and does not stop the service on
/// disappear/navigation; the whole point of the app-level service is that
/// Live Translation keeps running when the user leaves this screen. See
/// `LiveTranslationService`'s doc comment for where it actually starts,
/// stops, and hosts the `Translation` framework session.
struct LiveTranslationView: View {
    @Environment(LiveTranslationService.self) private var liveTranslation
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: AppMetrics.Spacing.lg) {
            Spacer()

            Image(systemName: "globe")
                .font(.system(size: 44))
                .foregroundStyle(AppColor.textSecondary)

            Text(statusText)
                .font(AppTypography.chatPreview)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppMetrics.Spacing.lg)

            sourceLanguagePicker
            audioSourcePicker
            conversationModePicker
            transcriptionProviderPicker
            activeProviderLabel

            if !liveTranslation.followLive {
                returnToLiveIndicator
            }

            if let lastTranslation = liveTranslation.lastTranslation {
                Text(lastTranslation)
                    .font(AppTypography.chatTitle)
                    .padding(AppMetrics.Spacing.sm)
                    .background(AppColor.secondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: AppMetrics.Radius.medium))
                    .padding(.horizontal, AppMetrics.Spacing.lg)
            }

            if case let .error(message) = liveTranslation.state {
                InlineErrorText(message: message)
                    .padding(.horizontal, AppMetrics.Spacing.lg)
            }

            PrimaryButton(
                buttonTitle,
                systemImage: liveTranslation.state == .listening ? "stop.circle" : "play.circle"
            ) {
                Task {
                    if liveTranslation.state == .listening {
                        await liveTranslation.stop()
                    } else {
                        // This screen is only reachable by pushing through
                        // Settings' own `.sheet`. `LiveTranslationService`'s
                        // one app-level `TranslationSession` is hosted on
                        // `RootView` (see its doc comment); the FIRST time
                        // the on-device Translation framework needs to show
                        // its own system UI (e.g. a language-resource
                        // download prompt) for a given phrase, it has to
                        // present on top of RootView — which it cannot do
                        // while Settings' sheet is still covering it
                        // ("Currently, only presenting a single sheet is
                        // supported"), so that translation call hangs
                        // forever waiting for an interaction the user can
                        // never make. Dismissing Settings here costs
                        // nothing — Live Translation is explicitly designed
                        // to keep running once you leave this screen.
                        appState.isSettingsPresented = false
                        await liveTranslation.start()
                    }
                }
            }
            .frame(maxWidth: 260)

            if liveTranslation.state == .listening {
                Text("Live Translation keeps running if you leave this screen.")
                    .font(.footnote)
                    .foregroundStyle(AppColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppMetrics.Spacing.lg)
            }

            Spacer()
        }
        .padding(AppMetrics.Spacing.lg)
        .navigationTitle("Live Translation")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Source-language selector — "Auto | EN | DE | PL", per the product
    /// requirement: quick to use, no modal sheet (a plain inline row of
    /// toggle buttons, always visible on this screen — nothing here
    /// presents anything, so there's no risk of the sheet-presentation
    /// conflict `LiveTranslationView`'s own Settings-dismiss fix already
    /// deals with elsewhere), clearly visible selected state, works while
    /// a session is already listening (switching mid-session is exactly
    /// when glasses-use makes a modal picker impractical).
    private var sourceLanguagePicker: some View {
        HStack(spacing: AppMetrics.Spacing.sm) {
            ForEach(SourceLanguageMode.allCases, id: \.self) { mode in
                let isSelected = liveTranslation.sourceLanguageMode == mode
                Button {
                    DiagnosticTrace.log("LANGUAGE_MODE_UI_CHANGED", "mode=\(mode.rawValue)")
                    liveTranslation.setSourceLanguageMode(mode)
                } label: {
                    Text(mode.displayLabel)
                        .font(AppTypography.chatPreview.weight(isSelected ? .semibold : .regular))
                        .padding(.horizontal, AppMetrics.Spacing.sm)
                        .padding(.vertical, AppMetrics.Spacing.xs)
                        .frame(minWidth: 44)
                        .background(isSelected ? AppColor.accent : AppColor.secondaryBackground)
                        .foregroundStyle(isSelected ? Color.white : AppColor.textPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.Radius.medium))
                }
                .accessibilityIdentifier("liveTranslation.sourceLanguage.\(mode.rawValue)")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }

    /// Audio source selector — "G2 Mic | Phone Mic", same non-modal
    /// inline pattern as `sourceLanguagePicker`. See `AudioSource`'s own
    /// doc comment for the SDK capability this exposes.
    private var audioSourcePicker: some View {
        HStack(spacing: AppMetrics.Spacing.sm) {
            ForEach(AudioSource.allCases, id: \.self) { source in
                let isSelected = liveTranslation.audioSource == source
                Button {
                    liveTranslation.setAudioSource(source)
                } label: {
                    Text(source.displayLabel)
                        .font(AppTypography.chatPreview.weight(isSelected ? .semibold : .regular))
                        .padding(.horizontal, AppMetrics.Spacing.sm)
                        .padding(.vertical, AppMetrics.Spacing.xs)
                        .background(isSelected ? AppColor.accent : AppColor.secondaryBackground)
                        .foregroundStyle(isSelected ? Color.white : AppColor.textPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.Radius.medium))
                }
                .accessibilityIdentifier("liveTranslation.audioSource.\(source.rawValue)")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }

    /// Conversation Mode selector — "Standard | Meeting". See
    /// `ConversationMode`'s own doc comment.
    private var conversationModePicker: some View {
        HStack(spacing: AppMetrics.Spacing.sm) {
            ForEach(ConversationMode.allCases, id: \.self) { mode in
                let isSelected = liveTranslation.conversationMode == mode
                Button {
                    liveTranslation.setConversationMode(mode)
                } label: {
                    Text(mode.displayLabel)
                        .font(AppTypography.chatPreview.weight(isSelected ? .semibold : .regular))
                        .padding(.horizontal, AppMetrics.Spacing.sm)
                        .padding(.vertical, AppMetrics.Spacing.xs)
                        .background(isSelected ? AppColor.accent : AppColor.secondaryBackground)
                        .foregroundStyle(isSelected ? Color.white : AppColor.textPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.Radius.medium))
                }
                .accessibilityIdentifier("liveTranslation.conversationMode.\(mode.rawValue)")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }

    /// Transcription provider selector — "Auto | On-device | Cloud", per
    /// the local-first architecture pass's §7/§16 requirements: a simple,
    /// always-visible setting (no modal sheet, matching the other three
    /// pickers on this screen) and clear provider labeling. `.onDevice`
    /// NEVER silently falls back to cloud (see `TranscriptionProviderRouter`'s
    /// own doc comment) — selecting it is a hard privacy commitment, not
    /// just a preference.
    private var transcriptionProviderPicker: some View {
        HStack(spacing: AppMetrics.Spacing.sm) {
            ForEach(TranscriptionProviderMode.allCases, id: \.self) { mode in
                let isSelected = liveTranslation.transcriptionProviderMode == mode
                Button {
                    liveTranslation.setTranscriptionProviderMode(mode)
                } label: {
                    Text(mode.displayLabel)
                        .font(AppTypography.chatPreview.weight(isSelected ? .semibold : .regular))
                        .padding(.horizontal, AppMetrics.Spacing.sm)
                        .padding(.vertical, AppMetrics.Spacing.xs)
                        .background(isSelected ? AppColor.accent : AppColor.secondaryBackground)
                        .foregroundStyle(isSelected ? Color.white : AppColor.textPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.Radius.medium))
                }
                .accessibilityIdentifier("liveTranslation.transcriptionProvider.\(mode.rawValue)")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }

    /// "Clear provider labeling" (§16): which STT provider actually
    /// transcribed the current/most recent session — on-device audio never
    /// leaves the phone; cloud audio is sent to this app's backend/OpenAI.
    /// Shown only once known (after a session has actually started at
    /// least once) — before that, there's nothing truthful to label yet.
    @ViewBuilder
    private var activeProviderLabel: some View {
        if let provider = liveTranslation.lastActiveTranscriptionProvider {
            let text = provider == .onDevice
                ? "On-device — audio never leaves this phone"
                : "Cloud — audio is sent to the backend"
            Text(text)
                .font(.caption)
                .foregroundStyle(AppColor.textSecondary)
                .accessibilityIdentifier("liveTranslation.activeProviderLabel")
        }
        // Cloud-mode production-safety fix: shown whenever the user
        // selected Cloud but the session is actually running on-device
        // because cloud failed (Railway unreachable, most commonly) —
        // truthful and non-alarming; never implies a G2/auth/session
        // problem, since there isn't one. Live Translation keeps
        // listening/translating/displaying on G2 throughout — this is
        // purely informational.
        if let notice = liveTranslation.cloudFallbackNotice {
            Text(notice)
                .font(.caption)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppMetrics.Spacing.lg)
                .accessibilityIdentifier("liveTranslation.cloudFallbackNotice")
        }
    }

    /// "↓ LIVE" — shown only once the user has manually navigated G2 away
    /// from the live page (via swipe). Tapping it is the iPhone-side
    /// equivalent of G2's own double-tap "return to live" gesture.
    private var returnToLiveIndicator: some View {
        Button {
            Task { await liveTranslation.returnToLive() }
        } label: {
            Label("LIVE", systemImage: "arrow.down")
                .font(AppTypography.chatPreview.weight(.semibold))
                .padding(.horizontal, AppMetrics.Spacing.sm)
                .padding(.vertical, AppMetrics.Spacing.xs)
                .background(AppColor.accent)
                .foregroundStyle(Color.white)
                .clipShape(Capsule())
        }
        .accessibilityIdentifier("liveTranslation.returnToLive")
    }

    private var statusText: String {
        switch liveTranslation.state {
        case .idle: "Start Live Translation to see foreign phrases translated on your glasses"
        case .listening: "Listening..."
        case .error: "Something went wrong"
        }
    }

    private var buttonTitle: String {
        liveTranslation.state == .listening ? "Stop" : "Start Live Translation"
    }
}

#Preview {
    NavigationStack {
        LiveTranslationView()
            .environment(
                LiveTranslationService(
                    glassesTransport: MockGlassesTransport(),
                    transcriber: GlassesSpeechTranscriber(),
                    translator: AppleLanguageTranslator()
                )
            )
            .environment(AppState())
    }
}
