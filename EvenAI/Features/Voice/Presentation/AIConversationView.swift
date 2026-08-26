import SwiftUI

/// AI Conversation's main screen — thin control surface over the
/// app-level `AIConversationEngine`. This view owns no state of its own
/// and does not stop the engine on disappear/navigation; the whole point
/// of the app-level engine is that AI Conversation keeps running when the
/// user leaves this screen. See `AIConversationEngine`'s doc comment for
/// where it actually starts, stops, and hosts the `Translation` framework
/// session.
///
/// Deliberately hides STT-provider/Railway/FoundationModels/local-vs-cloud
/// internals from the main controls (§5/§21 of the AI Conversation
/// consolidation pass): a normal user only ever sees Profile/Language/
/// Audio/Start-Stop. Provider diagnostics remain available, but pushed
/// into the collapsed `advancedSection` — present for troubleshooting,
/// never required to use the product.
struct AIConversationView: View {
    @Environment(AIConversationEngine.self) private var liveTranslation
    @Environment(AppState.self) private var appState
    @State private var isAdvancedExpanded = false

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

            labeledPicker(title: "Profile") { conversationProfilePicker }
            labeledPicker(title: "Language") { sourceLanguagePicker }
            labeledPicker(title: "Audio") { audioSourcePicker }

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

            // Truthful, plain-language status notices — never mentions
            // Railway/session/auth internals, only what actually changed
            // for the user (see each property's own doc comment).
            if let notice = liveTranslation.cloudFallbackNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppMetrics.Spacing.lg)
                    .accessibilityIdentifier("liveTranslation.cloudFallbackNotice")
            }
            if let reason = liveTranslation.repliesUnavailableReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppMetrics.Spacing.lg)
                    .accessibilityIdentifier("liveTranslation.repliesUnavailableNotice")
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
                        // Settings' own `.sheet`. `AIConversationEngine`'s
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
                        // nothing — AI Conversation is explicitly designed
                        // to keep running once you leave this screen.
                        appState.isSettingsPresented = false
                        await liveTranslation.start()
                    }
                }
            }
            .frame(maxWidth: 260)
            .accessibilityIdentifier("aiConversation.startStopButton")

            if liveTranslation.state == .listening {
                Text("AI Conversation keeps running if you leave this screen.")
                    .font(.footnote)
                    .foregroundStyle(AppColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppMetrics.Spacing.lg)
            }

            advancedSection

            Spacer()
        }
        .padding(AppMetrics.Spacing.lg)
        .navigationTitle("AI Conversation")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A consistent small caption above each of the three main pickers —
    /// "Profile"/"Language"/"Audio" — so the compact button rows read
    /// clearly without needing a modal picker or a full settings screen.
    private func labeledPicker(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: AppMetrics.Spacing.xs) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AppColor.textSecondary)
            content()
        }
    }

    /// Source-language selector — "Auto | EN | DE | PL", per the product
    /// requirement: quick to use, no modal sheet (a plain inline row of
    /// toggle buttons, always visible on this screen — nothing here
    /// presents anything, so there's no risk of the sheet-presentation
    /// conflict `AIConversationView`'s own Settings-dismiss fix already
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

    /// Audio source selector — "Glasses Mic | Phone Mic", same non-modal
    /// inline pattern as `sourceLanguagePicker`. See `AudioSource`'s own
    /// doc comment for the SDK capability this exposes — deliberately NOT
    /// to be confused with local/cloud STT processing (§7): this only
    /// picks which microphone captures audio, never how it's processed.
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

    /// Behavior-profile selector — "Auto | Conversation | Meeting". See
    /// `ConversationProfile`'s own doc comment: these are PRESENTATION
    /// profiles over the exact same engine, never separate pipelines.
    private var conversationProfilePicker: some View {
        HStack(spacing: AppMetrics.Spacing.sm) {
            ForEach(ConversationProfile.allCases, id: \.self) { mode in
                let isSelected = liveTranslation.conversationProfile == mode
                Button {
                    liveTranslation.setConversationProfile(mode)
                } label: {
                    Text(mode.displayLabel)
                        .font(AppTypography.chatPreview.weight(isSelected ? .semibold : .regular))
                        .padding(.horizontal, AppMetrics.Spacing.sm)
                        .padding(.vertical, AppMetrics.Spacing.xs)
                        .background(isSelected ? AppColor.accent : AppColor.secondaryBackground)
                        .foregroundStyle(isSelected ? Color.white : AppColor.textPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.Radius.medium))
                }
                .accessibilityIdentifier("liveTranslation.conversationProfile.\(mode.rawValue)")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }

    /// Everything a normal user never needs to see or think about —
    /// transcription-provider choice (local/cloud) and which provider
    /// actually ran the current/most recent session. Collapsed by
    /// default; exists for troubleshooting/diagnostics only (§21: "Do NOT
    /// put Local/Cloud/Railway/provider jargon on the main screen.
    /// Advanced settings may expose provider controls for diagnostics").
    private var advancedSection: some View {
        DisclosureGroup("Advanced", isExpanded: $isAdvancedExpanded) {
            VStack(spacing: AppMetrics.Spacing.sm) {
                transcriptionProviderPicker
                activeProviderLabel
            }
            .padding(.top, AppMetrics.Spacing.sm)
        }
        .font(.caption)
        .foregroundStyle(AppColor.textSecondary)
        .padding(.horizontal, AppMetrics.Spacing.lg)
        .accessibilityIdentifier("aiConversation.advancedSection")
    }

    /// Transcription provider selector — "Auto | On-device | Cloud".
    /// `.onDevice` NEVER silently falls back to cloud (see
    /// `TranscriptionProviderRouter`'s own doc comment) — selecting it is
    /// a hard privacy commitment, not just a preference. Lives inside
    /// `advancedSection` — see that property's own doc comment for why
    /// this doesn't belong on the main screen.
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

    /// "Clear provider labeling" — which STT provider actually
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
        case .idle: "Start AI Conversation to see foreign phrases translated on your glasses"
        case .listening: "Listening..."
        case .error: "Something went wrong"
        }
    }

    private var buttonTitle: String {
        liveTranslation.state == .listening ? "Stop" : "Start AI Conversation"
    }
}

#Preview {
    NavigationStack {
        AIConversationView()
            .environment(
                AIConversationEngine(
                    glassesTransport: MockGlassesTransport(),
                    transcriber: GlassesSpeechTranscriber(),
                    translator: AppleLanguageTranslator()
                )
            )
            .environment(AppState())
    }
}
